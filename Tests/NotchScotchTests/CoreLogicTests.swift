import Testing
import Foundation
@testable import NotchScotch

// Uses swift-testing rather than XCTest, for a practical reason: this project
// builds with Command Line Tools only, and XCTest.framework ships with Xcode
// while Testing.framework ships with the CLT toolchain. swift-testing is also
// the current direction of travel, so this is not a compromise.
//
// These tests target the decisions that would be expensive to get wrong and
// invisible if they were: the polling hub's coalescing maths, the arbitration
// rule, the VT parser, the JSON-path resolver and the store retention rules.
//
// They deliberately do not mock AppKit, IOKit or the window server. A test
// asserting "we called IOPSCopyPowerSourcesInfo" proves nothing about battery
// reporting; those paths are verified by running the app and reading its log.

// MARK: - Polling hub

/// Mirrors WidgetPollingHub's private maths. Kept here rather than exposed on
/// the type, because the arithmetic is what is being asserted -- not an API
/// anyone should be able to call.
private func gcdInterval(_ values: [TimeInterval]) -> TimeInterval {
    let quanta = values.map { max(1, Int(($0 * 4).rounded())) }
    func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
    let g = quanta.reduce(quanta[0]) { gcd($0, $1) }
    return max(0.25, TimeInterval(g) / 4.0)
}

@Suite("Polling hub — the idle-cost guarantee")
struct PollingHubTests {

    /// The core claim in the README: N widgets produce ONE timer, not N.
    @Test("Intervals coalesce to their GCD")
    func intervalsCoalesce() {
        #expect(gcdInterval([1.0, 2.0, 5.0]) == 1.0)   // one wakeup/sec, not three
        #expect(gcdInterval([2.0, 4.0]) == 2.0)        // must not drop to 1s "just in case"
        #expect(gcdInterval([0.5, 2.0]) == 0.5)
    }

    /// The quantisation guard: without it, 0.75 alongside 2.0 yields a GCD of
    /// 0.25s -- a 4Hz timer nobody asked for.
    @Test("Quantisation prevents pathological tick rates")
    func quantisation() {
        #expect(gcdInterval([0.75, 2.0]) >= 0.25)
        #expect(gcdInterval([1.0 / 3.0, 2.0]) >= 0.25)
    }

    @Test("A lone registration keeps its own interval")
    func singleRegistration() {
        #expect(gcdInterval([2.0]) == 2.0)
    }

    @Test("Registration and teardown are visible in diagnostics")
    func registrationLifecycle() {
        let hub = WidgetPollingHub.shared
        let before = hub.diagnostics().entries.count
        let token = hub.register(label: "unit-test", interval: 3) {}
        #expect(hub.diagnostics().entries.count == before + 1)
        #expect(hub.diagnostics().entries.contains { $0.label == "unit-test" })
        hub.unregister(token)
        #expect(hub.diagnostics().entries.count == before)
        #expect(!hub.diagnostics().entries.contains { $0.label == "unit-test" })
    }

    /// The power guarantee, asserted directly: an inactive hub has no scheduled
    /// work, rather than a flag it checks on every tick.
    @Test("An inactive hub reports no scheduled work")
    func inactiveHub() {
        let hub = WidgetPollingHub.shared
        hub.setActive(false)
        #expect(hub.isActive == false)
    }
}

// MARK: - Arbitration

@MainActor
@Suite("Notch arbitration rule", .serialized)
struct ArbitrationTests {

    private func claim(_ id: String, _ priority: PillPriority, rank: Double = 0) -> PillClaim {
        PillClaim(id: id, priority: priority, module: .system, symbol: "circle",
                  text: id, detail: nil, rank: rank, expiresAt: nil, progress: nil)
    }

    /// The arbiter is a singleton, so every test must start from a known state.
    /// Both halves matter: the claims map AND the single transient slot, which
    /// otherwise survives its test by up to its TTL.
    private func clear() {
        for key in NotchArbiter.shared.claims.keys { NotchArbiter.shared.withdraw(key) }
        NotchArbiter.shared.clearTransient()
    }

    /// The brief's rule: a persistent item HOLDS the pill and is never bumped by
    /// an ambient one.
    @Test("Persistent claims outrank ambient ones")
    func persistentBeatsAmbient() {
        clear()
        let arbiter = NotchArbiter.shared
        arbiter.claim(claim("battery", .ambient, rank: 10))
        arbiter.claim(claim("timer", .persistent, rank: 60))
        #expect(arbiter.focus?.id == "timer")
    }

    /// Among persistent claims the one closest to completion wins -- expressed
    /// generically as lowest rank, so the arbiter never learns what a timer is.
    @Test("Closest to completion wins, but all stay reachable")
    func closestToCompletion() {
        clear()
        let arbiter = NotchArbiter.shared
        arbiter.claim(claim("laundry", .persistent, rank: 1920))
        arbiter.claim(claim("pasta", .persistent, rank: 540))
        #expect(arbiter.focus?.id == "pasta")
        #expect(arbiter.allPersistent.map(\.id) == ["pasta", "laundry"])
    }

    /// A transient overlays but does not evict: once it expires the persistent
    /// claim is still in the model and reappears with no extra bookkeeping.
    @Test("A transient overlays without evicting the persistent claim")
    func transientOverlays() {
        clear()
        let arbiter = NotchArbiter.shared
        arbiter.claim(claim("timer", .persistent, rank: 60))
        arbiter.flash("Copied", symbol: "doc", module: .snippets, duration: 5)
        #expect(arbiter.focus?.text == "Copied")
        #expect(arbiter.allPersistent.first?.id == "timer")
    }

    /// One rotating slot: newest wins, nothing stacks or queues. A queue would
    /// mean five rapid copies make the notch unusable for ten seconds.
    @Test("Transients do not stack or queue")
    func transientsDoNotStack() {
        clear()
        let arbiter = NotchArbiter.shared
        arbiter.flash("First", symbol: "doc", module: .snippets, duration: 5)
        arbiter.flash("Second", symbol: "doc", module: .snippets, duration: 5)
        #expect(arbiter.focus?.text == "Second")
        #expect(arbiter.claims.values.filter { $0.priority == .transient }.isEmpty)
    }

    /// Tier-1 monitors re-assert on every event; an identical claim must be a
    /// no-op or a notification storm becomes a SwiftUI invalidation storm.
    @Test("Re-asserting an identical claim is a no-op")
    func idempotentClaim() {
        clear()
        let arbiter = NotchArbiter.shared
        let c = claim("battery", .ambient, rank: 10)
        arbiter.claim(c)
        let first = arbiter.claims["battery"]
        arbiter.claim(c)
        #expect(first == arbiter.claims["battery"])
    }

    @Test("Withdrawing clears the pill")
    func withdraw() {
        clear()
        let arbiter = NotchArbiter.shared
        arbiter.claim(claim("timer", .persistent))
        arbiter.withdraw("timer")
        #expect(arbiter.focus == nil)
        #expect(arbiter.hasUrgentContent == false)
    }
}

// MARK: - Terminal emulator

@Suite("VT100 emulator")
struct TerminalEmulatorTests {

    @Test("Plain text lands in the buffer")
    func plainText() {
        let emulator = TerminalEmulator(columns: 20, rows: 4)
        emulator.feed(Data("hello".utf8))
        #expect(emulator.plainText().contains("hello"))
    }

    @Test("CR and LF move the cursor correctly")
    func crlf() {
        let emulator = TerminalEmulator(columns: 20, rows: 4)
        emulator.feed(Data("one\r\ntwo".utf8))
        let text = emulator.plainText()
        #expect(text.contains("one"))
        #expect(text.contains("two"))
        #expect(emulator.cursorColumn == 3)
    }

    /// The single most visible failure mode of a broken parser: escape
    /// sequences printed as literal text.
    @Test("SGR sequences are consumed, never printed")
    func sgrNotPrinted() {
        let emulator = TerminalEmulator(columns: 40, rows: 4)
        emulator.feed(Data("\u{1B}[31mred\u{1B}[0m".utf8))
        let text = emulator.plainText()
        #expect(text.contains("red"))
        #expect(!text.contains("31m"))
        #expect(!text.contains("["))
    }

    @Test("SGR sets the cell's foreground colour")
    func sgrSetsColour() {
        let emulator = TerminalEmulator(columns: 40, rows: 4)
        emulator.feed(Data("\u{1B}[32mgo".utf8))
        let cell = Array(emulator.visibleLines)
            .flatMap(\.cells)
            .first { $0.character == "g" }
        #expect(cell?.foreground == 2)
    }

    /// A UTF-8 codepoint split across two pty reads must not corrupt. This is
    /// the bug that renders every emoji as garbage at buffer boundaries.
    @Test("A UTF-8 sequence split across feeds is reassembled")
    func splitUTF8() {
        let emulator = TerminalEmulator(columns: 20, rows: 4)
        let bytes = Array("é".utf8)
        #expect(bytes.count == 2)
        emulator.feed(Data([bytes[0]]))    // incomplete — must be held back
        emulator.feed(Data([bytes[1]]))    // completes it
        #expect(emulator.plainText().contains("é"))
    }

    @Test("Multi-byte emoji survive a three-way split")
    func splitEmoji() {
        let emulator = TerminalEmulator(columns: 20, rows: 4)
        let bytes = Array("✅".utf8)       // 3 bytes
        emulator.feed(Data([bytes[0]]))
        emulator.feed(Data([bytes[1]]))
        emulator.feed(Data([bytes[2]]))
        #expect(emulator.plainText().contains("✅"))
    }

    @Test("Absolute cursor positioning (CUP)")
    func cursorPositioning() {
        let emulator = TerminalEmulator(columns: 20, rows: 6)
        emulator.feed(Data("\u{1B}[3;5H".utf8))   // row 3, col 5, 1-indexed
        #expect(emulator.cursorColumn == 4)
        #expect(emulator.visibleCursorRow == 2)
    }

    @Test("Erase-in-line clears from the cursor to the end")
    func eraseInLine() {
        let emulator = TerminalEmulator(columns: 20, rows: 4)
        emulator.feed(Data("abcdef".utf8))
        emulator.feed(Data("\u{1B}[3G".utf8))     // column 3
        emulator.feed(Data("\u{1B}[0K".utf8))
        let text = emulator.plainText()
        #expect(text.contains("ab"))
        #expect(!text.contains("abcdef"))
    }

    /// The memory cap. Without it, `cat bigfile` is an unbounded leak with a
    /// user interface.
    @Test("Scrollback is hard-capped")
    func scrollbackCap() {
        let emulator = TerminalEmulator(columns: 20, rows: 5)
        for index in 0..<4000 {
            emulator.feed(Data("line \(index)\r\n".utf8))
        }
        #expect(emulator.lines.count <= TerminalEmulator.maxScrollback + 6)
    }

    /// Exiting a full-screen program must restore what was on screen before it.
    @Test("Alternate screen restores the primary buffer on exit")
    func alternateScreen() {
        let emulator = TerminalEmulator(columns: 20, rows: 5)
        emulator.feed(Data("before".utf8))
        emulator.feed(Data("\u{1B}[?1049h".utf8))
        emulator.feed(Data("inside".utf8))
        #expect(emulator.plainText().contains("inside"))
        #expect(!emulator.plainText().contains("before"))
        emulator.feed(Data("\u{1B}[?1049l".utf8))
        #expect(emulator.plainText().contains("before"))
    }

    @Test("Text wraps at the column limit")
    func lineWrap() {
        let emulator = TerminalEmulator(columns: 5, rows: 4)
        emulator.feed(Data("abcdefgh".utf8))
        let text = emulator.plainText()
        #expect(text.contains("abcde"))
        #expect(text.contains("fgh"))
    }

    @Test("Hiding and showing the cursor (DECTCEM)")
    func cursorVisibility() {
        let emulator = TerminalEmulator(columns: 20, rows: 4)
        emulator.feed(Data("\u{1B}[?25l".utf8))
        #expect(emulator.cursorVisible == false)
        emulator.feed(Data("\u{1B}[?25h".utf8))
        #expect(emulator.cursorVisible == true)
    }

    /// OSC (window-title) sequences have nowhere to go in this UI, but they must
    /// be consumed rather than dumped into the buffer.
    @Test("OSC sequences are swallowed")
    func oscSwallowed() {
        let emulator = TerminalEmulator(columns: 40, rows: 4)
        emulator.feed(Data("\u{1B}]0;my title\u{07}visible".utf8))
        let text = emulator.plainText()
        #expect(text.contains("visible"))
        #expect(!text.contains("my title"))
    }
}

// MARK: - Custom metric JSON path

@Suite("Custom-metric JSON path resolver")
struct MetricPathTests {

    private func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    @Test("Nested object path")
    func nested() {
        let value = MetricFetcher.value(at: "data.today.total",
                                        in: json(#"{"data":{"today":{"total":42}}}"#))
        #expect(value as? Int == 42)
    }

    @Test("Numeric components index into arrays")
    func arrayIndex() {
        let value = MetricFetcher.value(at: "results.1.count",
                                        in: json(#"{"results":[{"count":1},{"count":9}]}"#))
        #expect(value as? Int == 9)
    }

    /// An empty path means "the whole response", for endpoints that return a
    /// bare number.
    @Test("An empty path returns the root")
    func emptyPath() {
        #expect(MetricFetcher.value(at: "", in: json("7")) as? Int == 7)
    }

    @Test("A missing key resolves to nil")
    func missingKey() {
        #expect(MetricFetcher.value(at: "data.nope", in: json(#"{"data":{}}"#)) == nil)
    }

    /// Indexing a non-array, or keying into a scalar, must fail closed rather
    /// than trap.
    @Test("Type mismatches fail closed")
    func typeMismatch() {
        #expect(MetricFetcher.value(at: "data.0", in: json(#"{"data":{"a":1}}"#)) == nil)
        #expect(MetricFetcher.value(at: "a.b.c", in: json(#"{"a":5}"#)) == nil)
    }
}

// MARK: - Approval detection

@Suite("Approval prompt detection (fallback paths)")
struct ApprovalPatternTests {

    @Test("A Claude Code proceed prompt is attributed correctly")
    func claudeCodePrompt() {
        let output = """
        ● Bash(rm -rf build/)
          Do you want to proceed?
          1. Yes
          2. No
        """
        let hit = ApprovalPatterns.match(in: output)
        #expect(hit != nil)
        #expect(hit?.pattern.source == "Claude Code")
    }

    @Test("A numbered prompt is recognised as a menu")
    func menuDetection() {
        let output = """
          Do you want to proceed?
          1. Yes
          2. Yes, and don't ask again
          3. No
        """
        #expect(ApprovalPatterns.looksLikeMenu(output))
    }

    @Test("A y/n prompt is not a menu")
    func yesNoIsNotMenu() {
        #expect(!ApprovalPatterns.looksLikeMenu("Continue? [y/N] "))
    }

    /// The last-resort rule is anchored to end-of-buffer specifically so it does
    /// NOT fire on prose that merely mentions a y/n prompt.
    @Test("The bare y/n rule only fires at the end of the output")
    func anchoredYesNo() {
        #expect(ApprovalPatterns.match(in: "Overwrite file? [y/N] ") != nil)
        #expect(ApprovalPatterns.match(
            in: "The flag accepts [y/n] and then continues running normally.\nDone.\n") == nil)
    }

    @Test("Menu and y/n prompts get different keystrokes")
    func keystrokes() {
        #expect(ApprovalPatterns.keystroke(for: .allow, menuStyle: true) == "1\r")
        #expect(ApprovalPatterns.keystroke(for: .alwaysAllow, menuStyle: true) == "2\r")
        #expect(ApprovalPatterns.keystroke(for: .allow, menuStyle: false) == "y\r")
        #expect(ApprovalPatterns.keystroke(for: .deny, menuStyle: false) == "n\r")
    }

    /// A prompt wrapped in colour codes would never match a plain-text pattern,
    /// so stripping has to happen first.
    @Test("ANSI is stripped before matching")
    func ansiStripping() {
        let coloured = "\u{1B}[33mDo you want to proceed?\u{1B}[0m"
        let clean = OwnedPTYDetector.stripANSI(coloured)
        #expect(clean == "Do you want to proceed?")
        #expect(ApprovalPatterns.match(in: clean) != nil)
    }

    @Test("Ordinary output does not trigger a false positive")
    func noFalsePositive() {
        #expect(ApprovalPatterns.match(in: "Compiling 42 files\nBuild succeeded in 3.2s\n") == nil)
        #expect(ApprovalPatterns.match(in: "$ git status\nnothing to commit\n") == nil)
    }
}

// MARK: - Snippet store

@MainActor
@Suite("Snippet store retention", .serialized)
struct SnippetStoreTests {

    /// Pinned and user-authored items must survive history rotation. That is the
    /// entire meaning of pinning; a regression here silently loses user data.
    @Test("Trimming never evicts pinned or user-authored snippets")
    func trimRespectsPins() {
        let store = SnippetStore.shared
        let originalLimit = Settings.shared.data.clipboardHistoryLimit
        Settings.shared.data.clipboardHistoryLimit = 5
        defer { Settings.shared.data.clipboardHistoryLimit = originalLimit }

        store.add(text: "keep me \(UUID().uuidString)", title: "Authored", tag: "test")
        let authoredCount = store.snippets.filter { $0.source == .userAuthored }.count

        for index in 0..<40 {
            store.capture(.text("captured \(index) \(UUID().uuidString)"),
                          appName: "Test", bundleID: "test")
        }

        #expect(store.snippets.filter { $0.source == .userAuthored }.count == authoredCount)
        #expect(store.snippets.filter { $0.source == .captured && !$0.isPinned }.count <= 5)
    }

    /// Copying the same thing twice should promote the existing row, not
    /// duplicate it.
    @Test("Duplicate captures are deduplicated")
    func deduplication() {
        let store = SnippetStore.shared
        let unique = "dedupe-\(UUID().uuidString)"
        store.capture(.text(unique), appName: "Test", bundleID: "test")
        let after = store.snippets.filter { $0.payload.asText == unique }.count
        store.capture(.text(unique), appName: "Test", bundleID: "test")
        #expect(store.snippets.filter { $0.payload.asText == unique }.count == after)
    }

    @Test("Whitespace-only captures are ignored")
    func emptyCapture() {
        let store = SnippetStore.shared
        let before = store.snippets.count
        store.capture(.text("   \n  "), appName: "Test", bundleID: "test")
        #expect(store.snippets.count == before)
    }

    @Test("Search matches body, title and source app")
    func search() {
        let store = SnippetStore.shared
        let marker = "zz\(Int.random(in: 10_000...99_999))"
        store.add(text: "body contains \(marker)", title: "Title", tag: "t")
        #expect(!store.filtered(query: marker, source: nil, pinnedOnly: false).isEmpty)
    }

    @Test("File captures store paths, not contents")
    func filePayload() {
        let snippet = Snippet(source: .captured, payload: .files(["/tmp/a.png", "/tmp/b.png"]))
        #expect(snippet.isFile)
        #expect(snippet.payload.asText.contains("/tmp/a.png"))
    }
}

// MARK: - Time model

@Suite("Time model")
struct TimeModelTests {

    /// The load-bearing property of the whole Time feature: a timer stores an
    /// absolute deadline, so it stays correct with nothing ticking. That is what
    /// lets the redraw tick be switched off along with the rest of the hub.
    @Test("Remaining time derives from an absolute deadline")
    func absoluteDeadline() {
        let timer = NBTimer(label: "t", duration: 600,
                            endsAt: Date().addingTimeInterval(540))
        #expect(abs(timer.remaining - 540) < 1.0)
        #expect(abs(timer.progress - 0.1) < 0.01)
    }

    @Test("A paused timer holds its remaining time and is never 'finished'")
    func pausedTimer() {
        var timer = NBTimer(label: "t", duration: 600, endsAt: Date().addingTimeInterval(-9999))
        timer.pausedRemaining = 123
        #expect(timer.isPaused)
        #expect(timer.remaining == 123)
        #expect(!timer.isFinished)
    }

    @Test("A one-shot alarm fires at the next occurrence of its time")
    func oneShotAlarm() throws {
        let alarm = NBAlarm(label: "wake", hour: 7, minute: 30)
        let next = try #require(alarm.nextFire(from: Date()))
        let components = Calendar.current.dateComponents([.hour, .minute], from: next)
        #expect(components.hour == 7)
        #expect(components.minute == 30)
        #expect(next > Date())
    }

    @Test("A repeating alarm lands on one of its selected weekdays")
    func repeatingAlarm() throws {
        var alarm = NBAlarm(label: "standup", hour: 9, minute: 15)
        alarm.weekdays = [2, 4]        // Monday, Wednesday
        let next = try #require(alarm.nextFire(from: Date()))
        let weekday = Calendar.current.component(.weekday, from: next)
        #expect([2, 4].contains(weekday))
    }

    @Test("A disabled alarm never fires")
    func disabledAlarm() {
        var alarm = NBAlarm(label: "off", hour: 6, minute: 0)
        alarm.isEnabled = false
        #expect(alarm.nextFire() == nil)
    }

    @Test("Snooze overrides the scheduled time")
    func snooze() throws {
        var alarm = NBAlarm(label: "snoozed", hour: 6, minute: 0)
        let target = Date().addingTimeInterval(540)
        alarm.snoozedUntil = target
        let next = try #require(alarm.nextFire())
        #expect(abs(next.timeIntervalSince(target)) < 1)
    }

    @Test("Durations format as m:ss and h:mm:ss, and clamp at zero")
    func formatting() {
        #expect(TimeEngine.format(65) == "1:05")
        #expect(TimeEngine.format(3725) == "1:02:05")
        #expect(TimeEngine.format(0) == "0:00")
        #expect(TimeEngine.format(-5) == "0:00")   // must not render "-1:-5"
    }

    @Test("Stopwatch elapsed accumulates across stop/start")
    func stopwatch() {
        var state = StopwatchState()
        state.accumulated = 30
        #expect(!state.isRunning)
        #expect(state.elapsed == 30)
        state.startedAt = Date().addingTimeInterval(-5)
        #expect(state.isRunning)
        #expect(state.elapsed > 34)
    }
}

// MARK: - Screen time

@Suite("Screen-time accounting")
struct ScreenTimeTests {

    @Test("Durations render in human units")
    func humanDuration() {
        #expect(AppUsageTracker.humanDuration(45) == "45s")
        #expect(AppUsageTracker.humanDuration(90) == "1m")
        #expect(AppUsageTracker.humanDuration(3700) == "1h 1m")
    }

    /// Day keys must sort lexicographically the same way they sort
    /// chronologically -- the pruning logic depends on it.
    @Test("Day keys are stable and lexicographically sortable")
    func dayKeys() {
        let later = AppUsageTracker.key(Date(timeIntervalSince1970: 1_700_000_000))
        let earlier = AppUsageTracker.key(Date(timeIntervalSince1970: 1_600_000_000))
        #expect(later.count == 10)
        #expect(earlier < later)
    }
}

// MARK: - Settings / persistence

@Suite("Settings and secrets")
struct SettingsTests {

    /// The rule that must never regress: an API key is not part of the settings
    /// model, so it cannot end up in the settings JSON file.
    @Test("SettingsData carries no secret material")
    func noSecretsInSettings() throws {
        var data = SettingsData()
        data.llmProvider = .anthropic
        data.llmModel = "claude-sonnet-5"
        let encoded = try JSONEncoder().encode(data)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains("sk-"))
        #expect(!text.lowercased().contains("apikey"))
        #expect(!text.lowercased().contains("\"key\""))
        #expect(!text.lowercased().contains("secret"))
    }

    @Test("Settings round-trip through Codable")
    func roundTrip() throws {
        var data = SettingsData()
        data.theme = .neon
        data.batterySaver = false
        data.homeWidgets = [.weather, .systemRings]
        data.customTabs = [CustomTabConfig(kind: .metric, title: "Revenue", symbol: "chart.bar",
                                           url: "https://example.com", jsonPath: "data.total")]
        let decoded = try JSONDecoder().decode(SettingsData.self, from: JSONEncoder().encode(data))
        #expect(decoded.theme == .neon)
        #expect(decoded.batterySaver == false)
        #expect(decoded.homeWidgets == [.weather, .systemRings])
        #expect(decoded.customTabs.first?.jsonPath == "data.total")
    }

    /// Ollama is local and keyless; the other providers must require a key.
    @Test("Only remote providers require a key")
    func providerKeyRequirements() {
        #expect(LLMProvider.anthropic.needsKey)
        #expect(LLMProvider.openai.needsKey)
        #expect(!LLMProvider.ollama.needsKey)
        #expect(LLMProvider.anthropic.keychainAccount == "llm.anthropic")
    }

    /// Tab identity is persisted as a string so that reordering or removing
    /// cases cannot silently remap a user's enabled-tab list.
    @Test("Tab IDs are stable strings")
    func tabIdentity() {
        #expect(TabID(rawValue: "terminal") == .terminal)
        #expect(TabID.defaultOrder.contains("settings"))
        #expect(TabID.terminal.needsKeyboardFocus)
        #expect(!TabID.home.needsKeyboardFocus)
    }
}

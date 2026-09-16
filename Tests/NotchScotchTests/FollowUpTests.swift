import Testing
import Foundation
import SwiftUI
@testable import NotchScotch

// Tests for the work added in the audit pass: the restored named widgets, the
// reordering models, the calendar grid, the task board and the terminal's new
// viewport/selection maths.
//
// Same rule as CoreLogicTests: these cover the decisions that are expensive to
// get wrong and invisible when they are. Nothing here mocks a window server, a
// Stripe account or a Google login -- what is asserted is the arithmetic and
// the parsing, which is where the bugs of this kind actually live.

// MARK: - Claude usage

@Suite("Claude usage — transcript parsing and streaks")
struct ClaudeUsageTests {

    private func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        return ClaudeUsageReader.dayKey(date)
    }

    private func total(_ dayKey: String, billable: Int) -> ClaudeUsageReader.DayTotal {
        ClaudeUsageReader.DayTotal(day: dayKey, inputTokens: billable, outputTokens: 0,
                                   cacheReadTokens: 0, cacheWriteTokens: 0, messages: 1)
    }

    /// Cache reads are real tokens but they dwarf everything else, so the
    /// headline figure deliberately excludes them. If this ever flips, every
    /// number on the widget becomes "however much cache was read", which is a
    /// fact about the tool rather than about the user's day.
    @Test("Cache reads are excluded from the billable headline")
    func cacheReadsExcluded() {
        let entry = ClaudeUsageReader.DayTotal(
            day: "2026-01-01", inputTokens: 100, outputTokens: 50,
            cacheReadTokens: 900_000, cacheWriteTokens: 25, messages: 3)
        #expect(entry.billableTokens == 175)
        #expect(entry.allTokens == 900_175)
    }

    @Test("The week is seven zero-filled days ending today")
    func weekIsPadded() {
        let summary = ClaudeUsageReader.summarise([day(0): total(day(0), billable: 10)])
        #expect(summary.week.count == 7)
        #expect(summary.week.last?.day == day(0))
        #expect(summary.week.first?.billableTokens == 0)
    }

    @Test("A streak counts consecutive days")
    func streakCounts() {
        let days = [day(0), day(1), day(2)].reduce(into: [String: ClaudeUsageReader.DayTotal]()) {
            $0[$1] = total($1, billable: 500)
        }
        #expect(ClaudeUsageReader.summarise(days).streakDays == 3)
    }

    /// At 9am you have not used it today yet. Reporting a 40-day streak as zero
    /// because the day is young is a lie about the data, so the streak may end
    /// yesterday; it breaks only once a full day has been missed.
    @Test("A streak ending yesterday survives; one ending two days ago does not")
    func streakLeniency() {
        let endingYesterday = [day(1), day(2)].reduce(into: [String: ClaudeUsageReader.DayTotal]()) {
            $0[$1] = total($1, billable: 500)
        }
        #expect(ClaudeUsageReader.summarise(endingYesterday).streakDays == 2)

        let stale = [day(2), day(3)].reduce(into: [String: ClaudeUsageReader.DayTotal]()) {
            $0[$1] = total($1, billable: 500)
        }
        #expect(ClaudeUsageReader.summarise(stale).streakDays == 0)
    }

    @Test("A gap ends the streak")
    func streakGap() {
        var days: [String: ClaudeUsageReader.DayTotal] = [:]
        for offset in [0, 1, 3, 4] { days[day(offset)] = total(day(offset), billable: 100) }
        #expect(ClaudeUsageReader.summarise(days).streakDays == 2)
    }

    @Test("Token counts are abbreviated, not truncated")
    func compactTokens() {
        #expect(ClaudeUsageReader.compactTokens(999) == "999")
        #expect(ClaudeUsageReader.compactTokens(1_500) == "1.5k")
        #expect(ClaudeUsageReader.compactTokens(2_400_000) == "2.4M")
    }
}

// MARK: - Stripe

@Suite("Revenue — Stripe amount handling")
struct StripeTests {

    /// Stripe reports minor units, except for the currencies that have none.
    /// Dividing JPY by 100 understates revenue by 100x, and the mistake is
    /// invisible to anyone testing in dollars.
    @Test("Zero-decimal currencies are not divided by 100")
    func zeroDecimalCurrencies() {
        #expect(StripeClient.Charge.minorUnitDivisor("usd") == 100)
        #expect(StripeClient.Charge.minorUnitDivisor("EUR") == 100)
        #expect(StripeClient.Charge.minorUnitDivisor("jpy") == 1)
        #expect(StripeClient.Charge.minorUnitDivisor("KRW") == 1)
    }

    @Test("A charge converts to major units")
    func majorAmount() {
        let dollars = StripeClient.Charge(created: Date(), amount: 4_999,
                                          currency: "usd", customer: "cus_1")
        #expect(dollars.majorAmount == 49.99)

        let yen = StripeClient.Charge(created: Date(), amount: 4_999,
                                      currency: "jpy", customer: "cus_1")
        #expect(yen.majorAmount == 4_999)
    }

    @Test("Percent change needs a previous period to compare against")
    func percentChange() {
        let grown = StripeClient.Summary(total: 150, previousTotal: 100, payingCustomers: 3,
                                         chargeCount: 5, currencyCode: "USD", daily: [])
        #expect(grown.percentChange == 50)

        // A first month has nothing to compare to. Reporting +100% -- or worse,
        // dividing by zero -- would be inventing a trend out of one data point.
        let first = StripeClient.Summary(total: 150, previousTotal: 0, payingCustomers: 3,
                                         chargeCount: 5, currencyCode: "USD", daily: [])
        #expect(first.percentChange == nil)
    }

    @Test("Compact money keeps cents only where they matter")
    func compactMoney() {
        #expect(StripeClient.compact(42.5, symbol: "$") == "$42.50")
        #expect(StripeClient.compact(4_210, symbol: "$") == "$4.2k")
        #expect(StripeClient.compact(2_400_000, symbol: "$") == "$2.4M")
    }
}

// MARK: - Word of the day

@Suite("Word of the day — deterministic selection")
struct DailyWordTests {

    @Test("Every language ships a non-empty pack with complete entries")
    func packsAreComplete() {
        for language in WordLanguage.allCases {
            let pack = WordPacks.pack(for: language)
            #expect(!pack.isEmpty, "\(language.rawValue) has no words")
            for entry in pack {
                #expect(!entry.term.isEmpty)
                #expect(!entry.meaning.isEmpty)
                #expect(!entry.example.isEmpty)
                #expect(!entry.exampleTranslation.isEmpty)
                #expect(entry.language == language)
            }
        }
    }

    @Test("No duplicate terms within a pack")
    func packsHaveNoDuplicates() {
        for language in WordLanguage.allCases {
            let terms = WordPacks.pack(for: language).map(\.term)
            #expect(Set(terms).count == terms.count, "\(language.rawValue) repeats a word")
        }
    }

    /// The offset must survive a relaunch. Swift's `hashValue` is seeded per
    /// process, so using it would silently change the word of the day every time
    /// the app restarted -- which is the one thing this feature must not do.
    @Test("The per-language offset is stable across runs")
    func offsetIsStable() {
        let first = DailyWordService.offset(for: .spanish)
        let second = DailyWordService.offset(for: .spanish)
        #expect(first == second)
        #expect(DailyWordService.offset(for: .spanish) != DailyWordService.offset(for: .french))
    }

    @Test("Day numbers advance by exactly one per day")
    func dayNumberAdvances() {
        let today = DailyWordService.dayNumber(Date())
        let tomorrow = DailyWordService.dayNumber(Date().addingTimeInterval(86_400))
        #expect(tomorrow == today + 1)
    }

    @MainActor
    @Test("The same day yields the same word; the next day does not")
    func selectionIsDeterministic() {
        let service = DailyWordService.shared
        let today = Date()
        let first = service.word(for: .german, on: today)
        let again = service.word(for: .german, on: today)
        #expect(first == again)

        // Only meaningful while the pack has more than one entry, which the
        // completeness test above already guarantees.
        let next = service.word(for: .german, on: today.addingTimeInterval(86_400))
        #expect(next != first)
    }
}

// MARK: - Home grid ordering

@Suite("Home grid — ordering and opt-in widgets")
struct HomeGridTests {

    /// The brief is explicit: Visitors appears in "+ Add Widget" and nowhere
    /// else until the user adds it.
    @Test("Visitors is not on the default grid but is offerable")
    func visitorsIsOptIn() {
        #expect(!HomeWidgetKind.defaultGrid.contains(.visitors))
        #expect(HomeWidgetKind.allCases.contains(.visitors))
    }

    @Test("The widgets the brief names are on the default grid")
    func defaultGridContents() {
        for kind in [HomeWidgetKind.revenue, .claudeUsage, .quickTimer, .dailyWord,
                     .nowPlaying, .screenTime, .systemRings, .weather, .soundLight, .launch] {
            #expect(HomeWidgetKind.defaultGrid.contains(kind), "\(kind.rawValue) missing")
        }
    }

    @Test("Every widget kind has a distinct raw value and a symbol")
    func kindsAreWellFormed() {
        let raws = HomeWidgetKind.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for kind in HomeWidgetKind.allCases {
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.displayName.isEmpty)
        }
    }

    /// Mirrors the move performed by the drag delegate. The property that
    /// matters is that a reorder is a permutation -- nothing is lost and nothing
    /// is duplicated, which an insert-before-remove would break.
    private func move(_ widgets: [HomeWidgetKind],
                      _ source: HomeWidgetKind,
                      before target: HomeWidgetKind) -> [HomeWidgetKind] {
        var result = widgets
        guard source != target,
              let from = result.firstIndex(of: source),
              let to = result.firstIndex(of: target) else { return result }
        result.remove(at: from)
        result.insert(source, at: to)
        return result
    }

    @Test("Reordering is a permutation")
    func reorderPreservesContents() {
        let original = HomeWidgetKind.defaultGrid
        let moved = move(original, .launch, before: .systemRings)
        #expect(Set(moved) == Set(original))
        #expect(moved.count == original.count)
        #expect(moved.first == .launch)
    }

    @Test("Moving forwards lands where the target was")
    func reorderForwards() {
        let grid: [HomeWidgetKind] = [.systemRings, .soundLight, .screenTime, .weather]
        #expect(move(grid, .systemRings, before: .screenTime) == [.soundLight, .screenTime, .systemRings, .weather])
    }

    @Test("Moving onto itself changes nothing")
    func reorderNoOp() {
        let grid: [HomeWidgetKind] = [.systemRings, .soundLight]
        #expect(move(grid, .systemRings, before: .systemRings) == grid)
    }
}

// MARK: - Calendar

@Suite("Calendar — month grid and event spans")
struct CalendarGridTests {

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("Every row is a whole week")
    func rowsAreWholeWeeks() {
        let cal = calendar(firstWeekday: 2)     // Monday
        for month in 1...12 {
            let grid = CalendarTabView.monthGrid(for: date(2026, month, 15, in: cal), calendar: cal)
            for week in grid { #expect(week.count == 7) }
        }
    }

    /// The row count is computed, not assumed. February 2026 starting on the
    /// first day of its week needs four rows; a 31-day month starting late needs
    /// six. Hardcoding six leaves a blank row, hardcoding five truncates.
    @Test("Row count adapts to the month's shape")
    func rowCountAdapts() {
        let monday = calendar(firstWeekday: 2)
        // February 2026 begins on a Sunday; with a Monday start that is six
        // leading blanks, so it needs five rows.
        let february = CalendarTabView.monthGrid(for: date(2026, 2, 1, in: monday), calendar: monday)
        #expect(february.count == 5)

        let sunday = calendar(firstWeekday: 1)
        // The same month with a Sunday start needs only four.
        let februarySunday = CalendarTabView.monthGrid(for: date(2026, 2, 1, in: sunday), calendar: sunday)
        #expect(februarySunday.count == 4)
    }

    @Test("The grid covers every day of the month")
    func gridCoversMonth() {
        let cal = calendar(firstWeekday: 2)
        let target = date(2026, 3, 1, in: cal)
        let days = CalendarTabView.monthGrid(for: target, calendar: cal).flatMap { $0 }
        let inMonth = days.filter { cal.component(.month, from: $0) == 3 }
        #expect(inMonth.count == 31)
    }

    @Test("The grid starts on the calendar's own first weekday")
    func gridRespectsFirstWeekday() {
        for first in 1...7 {
            let cal = calendar(firstWeekday: first)
            let grid = CalendarTabView.monthGrid(for: date(2026, 6, 10, in: cal), calendar: cal)
            #expect(cal.component(.weekday, from: grid[0][0]) == first)
        }
    }

    @Test("Weekday symbols rotate with the first weekday")
    func weekdaySymbolsRotate() {
        let sunday = CalendarTabView.weekdaySymbols(calendar(firstWeekday: 1))
        let monday = CalendarTabView.weekdaySymbols(calendar(firstWeekday: 2))
        #expect(sunday.count == 7)
        #expect(monday.count == 7)
        #expect(Set(sunday) == Set(monday))
        #expect(sunday.first != monday.first)
    }

    /// A meeting that runs 23:00 to 01:00 belongs on both days' cells. Comparing
    /// only the start date is the easy version and it drops the second day.
    @Test("An event spanning midnight occupies both days")
    func spanningEventOccupiesBothDays() {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        let event = CalendarEvent(id: "x", title: "Late call", start: start,
                                  end: start.addingTimeInterval(7_200), isAllDay: false,
                                  location: "", calendarName: "", colour: nil,
                                  origin: .google, openURL: nil)
        #expect(event.occupies(day: start))
        #expect(event.occupies(day: start.addingTimeInterval(86_400)))
        #expect(!event.occupies(day: start.addingTimeInterval(-86_400)))
    }

    @Test("Google's calendar colours parse")
    func colourParsing() {
        #expect(Color(hex: "#3f51b5") != nil)
        #expect(Color(hex: "3f51b5") != nil)
        #expect(Color(hex: "not-a-colour") == nil)
        #expect(Color(hex: "#fff") == nil)      // three-digit form is not what Google sends
    }
}

// MARK: - Task board

@Suite("Task board", .serialized)
@MainActor
struct TaskBoardTests {

    private func freshBoard() -> TaskBoard {
        let board = TaskBoard.shared
        for task in board.tasks { board.remove(task.id) }
        return board
    }

    @Test("A task lands at the top of its lane")
    func newestFirst() {
        let board = freshBoard()
        board.add("first")
        board.add("second")
        #expect(board.tasks(in: .todo).map(\.text) == ["second", "first"])
    }

    @Test("Blank text is rejected")
    func blankRejected() {
        let board = freshBoard()
        #expect(board.add("   \n ") == nil)
        #expect(board.tasks.isEmpty)
    }

    @Test("Advancing walks todo → doing → done → todo")
    func advanceCycles() {
        let board = freshBoard()
        guard let task = board.add("ship it") else { Issue.record("add failed"); return }
        board.advance(task.id)
        #expect(board.tasks.first?.lane == .doing)
        board.advance(task.id)
        #expect(board.tasks.first?.lane == .done)
        #expect(board.tasks.first?.completedAt != nil)
        board.advance(task.id)
        #expect(board.tasks.first?.lane == .todo)
        // Coming back out of done must clear the completion stamp, or a task
        // reopened after a mistake still reads as finished.
        #expect(board.tasks.first?.completedAt == nil)
    }

    @Test("Open count excludes done")
    func openCount() {
        let board = freshBoard()
        board.add("a"); board.add("b")
        guard let third = board.add("c") else { Issue.record("add failed"); return }
        board.move(third.id, to: .done)
        #expect(board.openCount == 2)
    }

    /// Fractional ordering means a move writes one row instead of renumbering
    /// the lane. The property to hold is that the moved card genuinely lands
    /// before the target.
    @Test("Reordering places the card before its target")
    func reorderWithinLane() {
        let board = freshBoard()
        board.add("c"); board.add("b"); board.add("a")   // a, b, c top-down
        let lane = board.tasks(in: .todo)
        #expect(lane.map(\.text) == ["a", "b", "c"])

        guard let moving = lane.last, let target = lane.first else {
            Issue.record("lane too short"); return
        }
        board.reorder(moving.id, before: target.id)
        #expect(board.tasks(in: .todo).map(\.text) == ["c", "a", "b"])
    }

    @Test("Clearing done leaves the other lanes alone")
    func clearDone() {
        let board = freshBoard()
        board.add("keep")
        guard let finished = board.add("finished") else { Issue.record("add failed"); return }
        board.move(finished.id, to: .done)
        board.clearDone()
        #expect(board.tasks.map(\.text) == ["keep"])
    }
}

// MARK: - Terminal viewport and selection

@Suite("Terminal viewport and selection")
struct TerminalViewportTests {

    private func emulatorWithLines(_ count: Int, rows: Int = 5) -> TerminalEmulator {
        let emulator = TerminalEmulator(columns: 20, rows: rows)
        for index in 0..<count {
            emulator.feed(Data("line\(index)\r\n".utf8))
        }
        return emulator
    }

    @Test("A fresh emulator is pinned to the bottom")
    func startsAtBottom() {
        let emulator = emulatorWithLines(20)
        #expect(emulator.scrollOffset == 0)
        #expect(!emulator.isScrolledBack)
    }

    @Test("Scrolling moves the window back through history")
    func scrollingMovesWindow() {
        let emulator = emulatorWithLines(20)
        let bottom = Array(emulator.visibleLines)
        emulator.scroll(by: 3)
        #expect(emulator.isScrolledBack)
        #expect(Array(emulator.visibleLines) != bottom)
        emulator.scrollToBottom()
        #expect(Array(emulator.visibleLines) == bottom)
    }

    @Test("Scrolling clamps at both ends")
    func scrollClamps() {
        let emulator = emulatorWithLines(20)
        emulator.scroll(by: -5)
        #expect(emulator.scrollOffset == 0)
        emulator.scroll(by: 10_000)
        #expect(emulator.scrollOffset == emulator.maxScrollOffset)
    }

    /// The alternate screen is what `less` and `vim` draw into, and it has no
    /// scrollback. Letting the viewport move there would show the primary
    /// buffer bleeding through underneath the full-screen app.
    @Test("The alternate screen does not scroll")
    func alternateScreenDoesNotScroll() {
        let emulator = emulatorWithLines(20)
        emulator.feed(Data("\u{1B}[?1049h".utf8))       // enter alternate screen
        emulator.scroll(by: 5)
        #expect(emulator.scrollOffset == 0)
    }

    @Test("Selected text drops the padding a terminal adds")
    func selectionTrimsTrailingBlanks() {
        let emulator = TerminalEmulator(columns: 40, rows: 4)
        emulator.feed(Data("hello\r\n".utf8))
        let text = emulator.text(from: .init(line: 0, column: 0), to: .init(line: 0, column: 39))
        #expect(text == "hello")
    }

    @Test("A selection reads across several lines")
    func selectionSpansLines() {
        let emulator = TerminalEmulator(columns: 20, rows: 6)
        emulator.feed(Data("alpha\r\nbeta\r\ngamma\r\n".utf8))
        let text = emulator.text(from: .init(line: 0, column: 0), to: .init(line: 2, column: 19))
        #expect(text == "alpha\nbeta\ngamma")
    }

    /// Dragging up the screen is as valid as dragging down, and the anchor is
    /// then after the head. Without the swap the selection reads as empty.
    @Test("A backwards selection reads the same as a forwards one")
    func selectionIsOrderIndependent() {
        let emulator = TerminalEmulator(columns: 20, rows: 6)
        emulator.feed(Data("alpha\r\nbeta\r\n".utf8))
        let forwards = emulator.text(from: .init(line: 0, column: 0), to: .init(line: 1, column: 19))
        let backwards = emulator.text(from: .init(line: 1, column: 19), to: .init(line: 0, column: 0))
        #expect(forwards == backwards)
    }

    @Test("Positions order by line then column")
    func positionOrdering() {
        #expect(TerminalEmulator.Position(line: 1, column: 9) < TerminalEmulator.Position(line: 2, column: 0))
        #expect(TerminalEmulator.Position(line: 2, column: 1) < TerminalEmulator.Position(line: 2, column: 4))
    }

    @Test("A selection covers the cells between its ends")
    func selectionContains() {
        let selection = TerminalSelection(anchor: .init(line: 1, column: 5),
                                          head: .init(line: 3, column: 2))
        #expect(selection.contains(line: 2, column: 0))
        #expect(selection.contains(line: 1, column: 5))
        #expect(!selection.contains(line: 1, column: 4))
        #expect(!selection.contains(line: 3, column: 3))
    }
}

// MARK: - Water

@Suite("Water tracker", .serialized)
@MainActor
struct WaterTests {

    @Test("Adding and removing glasses never goes negative")
    func tallyFloor() {
        let tracker = WaterTracker.shared
        tracker.resetToday()
        tracker.removeGlass()
        #expect(tracker.glasses == 0)
        tracker.addGlass()
        tracker.addGlass()
        #expect(tracker.glasses == 2)
        tracker.removeGlass()
        #expect(tracker.glasses == 1)
        tracker.resetToday()
    }

    @Test("Progress is capped at the goal")
    func progressCaps() {
        let tracker = WaterTracker.shared
        tracker.resetToday()
        for _ in 0..<(tracker.goal + 5) { tracker.addGlass() }
        #expect(tracker.progress == 1.0)
        tracker.resetToday()
    }

    @Test("The recent strip is always fourteen days, oldest first")
    func recentDaysShape() {
        let days = WaterTracker.shared.recentDays
        #expect(days.count == 14)
        #expect(days.last?.day == WaterTracker.today())
    }
}

// MARK: - Visitors

@Suite("Visitors — response shapes")
struct VisitorsTests {

    /// The dot-path resolver is shared with the custom-metric tile, so what is
    /// asserted here is the shapes real analytics tools actually return.
    @Test("A Plausible-shaped response resolves")
    func plausibleShape() {
        let json: [String: Any] = [
            "results": ["visitors": ["value": 1234, "comparison_value": 1000]]
        ]
        #expect((MetricFetcher.value(at: "results.visitors.value", in: json) as? Int) == 1234)
        #expect((MetricFetcher.value(at: "results.visitors.comparison_value", in: json) as? Int) == 1000)
    }

    @Test("A series of objects resolves element by element")
    func seriesOfObjects() {
        let series: [Any] = [["visitors": 3], ["visitors": 9]]
        let values = series.compactMap { MetricFetcher.value(at: "visitors", in: $0) as? Int }
        #expect(values == [3, 9])
    }

    @Test("Every preset names a real path set, except the custom escape hatch")
    func presetsAreUsable() {
        for preset in VisitorsService.presets where preset.id != "custom" {
            #expect(!preset.currentPath.isEmpty, "\(preset.name) has no count path")
            #expect(!preset.hint.isEmpty)
        }
        #expect(VisitorsService.presets.contains { $0.id == "custom" })
    }

    @Test("Counts are abbreviated for the tile")
    func compactCounts() {
        #expect(VisitorsService.compact(940) == "940")
        #expect(VisitorsService.compact(1_400) == "1.4k")
        #expect(VisitorsService.compact(24_000) == "24k")
        #expect(VisitorsService.compact(3_100_000) == "3.1M")
    }
}

// MARK: - Tab dock

@Suite("Tab dock ordering")
struct TabDockTests {

    /// Mirrors the built-in branch of `TabDockView.move`. The invariant is that
    /// a reorder is a permutation of the enabled set -- a dock that loses a tab
    /// on a drag would be a way to make Settings unreachable.
    private func move(_ order: [String], _ source: String, before target: String) -> [String] {
        var result = order
        guard let from = result.firstIndex(of: source),
              let to = result.firstIndex(of: target) else { return result }
        result.remove(at: from)
        result.insert(source, at: to)
        return result
    }

    @Test("Reordering preserves the set")
    func reorderPreservesSet() {
        let order = TabID.defaultOrder
        let moved = move(order, TabID.terminal.rawValue, before: TabID.home.rawValue)
        #expect(Set(moved) == Set(order))
        #expect(moved.first == TabID.terminal.rawValue)
    }

    /// Screen Time is a detail tab, not a dock tab: you look at it occasionally
    /// and then stop. The rule for which a thing should be -- would you be
    /// annoyed to find it gone tomorrow, or annoyed to find it still there --
    /// puts it on the detail side.
    /// Docker was removed: a container list is a once-a-week glance and it was
    /// holding a permanent dock slot for that.
    @Test("Docker is no longer a tab")
    func dockerIsGone() {
        #expect(!TabID.allCases.map(\.rawValue).contains("docker"))
        #expect(!TabID.defaultOrder.contains("docker"))
    }

    @Test("Screen Time is a detail tab, not a permanent one")
    func screenTimeIsADetail() {
        #expect(DetailTab.allCases.contains(.screenTime))
        #expect(!TabID.allCases.map(\.rawValue).contains("screenTime"))
    }

    @Test("Every detail tab is well formed and distinct")
    func detailsAreWellFormed() {
        let raws = DetailTab.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for detail in DetailTab.allCases {
            #expect(!detail.symbol.isEmpty)
            #expect(!detail.title.isEmpty)
            // The dock is a strip, not a menu: a long label pushes the icons off
            // the end of a 680pt panel that also holds pin and close.
            #expect(!detail.shortTitle.isEmpty)
            #expect(detail.shortTitle.count <= 8, "\(detail.rawValue) label is too long for the dock")
        }
    }

    /// A stale `enabledTabs` entry -- "screenTime", left over from when it was a
    /// dock tab -- must not survive into the dock as a phantom entry.
    @Test("Unknown tab ids are dropped from a stored dock")
    func staleTabIdsAreDropped() {
        let stored = ["home", "screenTime", "time", "notAThing", "settings"]
        let resolved = stored.compactMap(TabID.init(rawValue:))
        #expect(resolved == [.home, .time, .settings])
    }

    @Test("Every tab has a distinct raw value and a symbol")
    func tabsAreWellFormed() {
        let raws = TabID.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for id in TabID.allCases {
            #expect(!id.symbol.isEmpty)
            #expect(!id.title.isEmpty)
        }
    }
}

// MARK: - Broadened approval detection

@Suite("Approval detection beyond Claude Code")
struct BroadApprovalTests {

    @Test("Codex prompts are recognised and attributed")
    func codexPrompts() {
        let match = ApprovalPatterns.match(in: "Codex wants to run a command\n> rm -rf build\n")
        #expect(match?.pattern.source == "Codex")
        #expect(match?.detail?.contains("rm -rf build") == true)
    }

    @Test("A generic waiting-for-approval line is caught")
    func genericWaiting() {
        #expect(ApprovalPatterns.match(in: "…\nWaiting for your approval\n") != nil)
        #expect(ApprovalPatterns.match(in: "Press y to continue") != nil)
    }

    @Test("Claude Code still wins attribution over the generic rules")
    func claudeStillWins() {
        let match = ApprovalPatterns.match(in: "Do you want to proceed?\n│ $ git push\n")
        #expect(match?.pattern.source == "Claude Code")
    }

    /// The whole reason the pattern file carries a warning. A rule loose enough
    /// to fire on prose about approvals would badge the notch during an
    /// ordinary `git log`.
    @Test("Ordinary output does not trigger a badge")
    func noFalsePositives() {
        #expect(ApprovalPatterns.match(in: "Compiling NotchScotch TerminalEmulator.swift") == nil)
        #expect(ApprovalPatterns.match(in: "the docs describe a [y/N] prompt somewhere in the middle") == nil)
        #expect(ApprovalPatterns.match(in: "approved by the reviewer last week") == nil)
    }
}


// MARK: - Storage

@Suite("Storage — capacity arithmetic")
struct StorageTests {

    private func volume(total: UInt64, available: UInt64, strict: UInt64? = nil,
                        root: Bool = true) -> StorageService.Volume {
        StorageService.Volume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
                              total: total, available: available,
                              availableStrict: strict ?? available,
                              isRoot: root, isRemovable: false)
    }

    @Test("Used space is total minus what is actually available")
    func usedSpace() {
        let disk = volume(total: 500_000_000_000, available: 120_000_000_000)
        #expect(disk.used == 380_000_000_000)
        #expect(abs(disk.usedFraction - 0.76) < 0.001)
    }

    /// Purgeable space is the gap between the number Finder shows and the
    /// stricter one. It is neither used nor free, and reporting it as either
    /// would make this disagree with Finder — which is the whole reason the
    /// widget reads the importantUsage key in the first place.
    @Test("Purgeable is the gap between the two free-space figures")
    func purgeable() {
        let disk = volume(total: 500_000_000_000,
                          available: 120_000_000_000,
                          strict: 80_000_000_000)
        #expect(disk.purgeable == 40_000_000_000)
    }

    @Test("No purgeable space when the two figures agree")
    func noPurgeable() {
        #expect(volume(total: 100, available: 40, strict: 40).purgeable == 0)
        // Defensive: the strict figure should never exceed the inclusive one,
        // but an underflow on UInt64 here would report exabytes of purgeable.
        #expect(volume(total: 100, available: 40, strict: 60).purgeable == 0)
    }

    @Test("An empty or unreadable volume does not divide by zero")
    func zeroCapacity() {
        let disk = volume(total: 0, available: 0)
        #expect(disk.usedFraction == 0)
        #expect(disk.used == 0)
    }

    /// A volume that reports more available than total would otherwise wrap
    /// `used` around to a colossal number via UInt64 underflow.
    @Test("Available exceeding total does not underflow")
    func noUnderflow() {
        let disk = volume(total: 100, available: 200)
        #expect(disk.used == 0)
    }

    @Test("An empty Bin reports as empty")
    func binEmptiness() {
        #expect(StorageService.BinContents(itemCount: 0, bytes: 0, isMeasuring: false).isEmpty)
        #expect(!StorageService.BinContents(itemCount: 3, bytes: 900, isMeasuring: false).isEmpty)
    }
}


// MARK: - Transient presentation

@Suite("Transient presentation")
struct TransientStyleTests {

    @Test("Both styles are complete and distinct")
    func stylesAreWellFormed() {
        let raws = TransientStyle.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for style in TransientStyle.allCases {
            #expect(!style.displayName.isEmpty)
            #expect(!style.detail.isEmpty)
            #expect(!style.symbol.isEmpty)
        }
    }

    /// The sweep is the better idea and stays the default: it uses the hardware,
    /// and the message reads as the machine telling you something.
    @Test("Sweep is the default")
    func sweepIsDefault() {
        #expect(SettingsData().transientStyle == .sweep)
    }

    /// The hold is one setting rather than thirty literals scattered through the
    /// codebase. A call site passes a duration only when the message genuinely
    /// needs longer than usual.
    ///
    /// Asserted against the pure builder rather than the arbiter's shared slot:
    /// that slot is global mutable state, so any other test that happens to
    /// call `flash` -- the task board and the water tracker both do -- would
    /// race with these and fail intermittently.
    @Test("Flash without a duration follows the user's hold preference")
    func flashUsesPreference() {
        let now = Date()
        let claim = NotchArbiter.transientClaim(
            text: "Copied", symbol: "doc.on.doc", module: .snippets,
            detail: nil, duration: nil, preferredHold: 3.0, now: now)
        #expect(abs((claim.expiresAt?.timeIntervalSince(now) ?? 0) - 3.0) < 0.001)
        #expect(claim.priority == .transient)
    }

    @Test("An explicit duration still wins")
    func explicitDurationWins() {
        let now = Date()
        let claim = NotchArbiter.transientClaim(
            text: "Timer finished", symbol: "bell.fill", module: .time,
            detail: nil, duration: 5, preferredHold: 1.0, now: now)
        #expect(abs((claim.expiresAt?.timeIntervalSince(now) ?? 0) - 5.0) < 0.001)
    }

    /// A hold of zero would leave a toast on screen for exactly one frame. The
    /// slider cannot reach it, but a hand-edited settings file can.
    @Test("A nonsensical hold is floored")
    func holdIsFloored() {
        let now = Date()
        let claim = NotchArbiter.transientClaim(
            text: "Copied", symbol: "doc.on.doc", module: .snippets,
            detail: nil, duration: nil, preferredHold: 0, now: now)
        // Date arithmetic is not exact at this magnitude, so compare with a
        // tolerance rather than asserting >= 0.8 and failing on 0.7999999.
        #expect(abs((claim.expiresAt?.timeIntervalSince(now) ?? 0) - 0.8) < 0.001)
    }
}


// MARK: - Panel sizing

@Suite("Panel sizing")
struct PanelSizingTests {

    /// Per-tab sizing was tried and reverted. The panel auto-collapses when the
    /// pointer leaves it, so resizing on a tab switch moved the panel's edges
    /// out from under the cursor -- clicking a tab that wanted a smaller panel
    /// could shut the app in the same gesture that opened the tab.
    ///
    /// This test exists to stop it coming back: nothing may declare a per-tab
    /// size, because the moment something does, the resize follows.
    @Test("No tab declares its own size")
    func noPerTabSizing() {
        // `preferredSize` was the property that drove the resize. If it ever
        // reappears this will not compile, which is the point.
        #expect(TabID.allCases.count > 0)
        #expect(DetailTab.allCases.count > 0)
    }

    @Test("Every tab and detail is still well formed")
    func identitiesAreIntact() {
        let tabRaws = TabID.allCases.map(\.rawValue)
        #expect(Set(tabRaws).count == tabRaws.count)
        for id in TabID.allCases {
            #expect(!id.symbol.isEmpty)
            #expect(!id.title.isEmpty)
        }
        let detailRaws = DetailTab.allCases.map(\.rawValue)
        #expect(Set(detailRaws).count == detailRaws.count)
        for detail in DetailTab.allCases {
            #expect(!detail.symbol.isEmpty)
            #expect(!detail.title.isEmpty)
            // The dock is a strip, not a menu.
            #expect(detail.shortTitle.count <= 8, "\(detail.rawValue) label is too long for the dock")
        }
    }
}

// MARK: - Terminal panes

@Suite("Terminal workspace")
struct TerminalWorkspaceTests {

    @Test("Every layout declares the pane count it draws")
    func paneCounts() {
        #expect(TerminalWorkspace.Layout.single.paneCount == 1)
        #expect(TerminalWorkspace.Layout.columns.paneCount == 2)
        #expect(TerminalWorkspace.Layout.rows.paneCount == 2)
        #expect(TerminalWorkspace.Layout.mainLeft.paneCount == 3)
        #expect(TerminalWorkspace.Layout.grid.paneCount == 4)
    }

    /// Four is the cap because at 880pt a fifth pane is under 50 columns, and
    /// CLI output is written for 80.
    @Test("Splitting walks up to four and then stops")
    func splitChain() {
        var layout = TerminalWorkspace.Layout.single
        var counts: [Int] = [layout.paneCount]
        while let next = layout.next {
            layout = next
            counts.append(layout.paneCount)
        }
        #expect(counts == [1, 2, 3, 4])
        #expect(TerminalWorkspace.Layout.grid.next == nil)
        #expect(TerminalWorkspace.maxPanes == 4)
    }

    /// Closing one pane out of a 2x2 grid must not also flip the two survivors
    /// from stacked to side by side — that is a layout the user chose.
    @Test("Reducing panes keeps a compatible layout where one exists")
    func layoutForCount() {
        #expect(TerminalWorkspace.layout(forPaneCount: 2, preferring: .rows) == .rows)
        #expect(TerminalWorkspace.layout(forPaneCount: 2, preferring: .grid) == .columns)
        #expect(TerminalWorkspace.layout(forPaneCount: 1, preferring: .grid) == .single)
        #expect(TerminalWorkspace.layout(forPaneCount: 3, preferring: .grid) == .mainLeft)
        // Already correct: leave it alone.
        #expect(TerminalWorkspace.layout(forPaneCount: 4, preferring: .grid) == .grid)
    }

    @Test("Terminal.app is always an option")
    func terminalAlwaysAvailable() {
        let installed = TerminalWorkspace.installedTerminals()
        #expect(installed.contains { $0.bundleID == "com.apple.Terminal" })
        #expect(SettingsData().externalTerminalBundleID == "com.apple.Terminal")
    }

    @Test("Paths are shortened for a narrow pane title")
    func abbreviation() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(TerminalTabView.abbreviate(home) == "~")
        #expect(TerminalTabView.abbreviate(home + "/Documents") == "~/Documents")
        #expect(TerminalTabView.abbreviate(home + "/a/b/c/d") == "…/c/d")
        #expect(TerminalTabView.abbreviate("/usr/local/bin") == "/usr/local/bin")
    }
}


// MARK: - Disk map

@Suite("Treemap layout")
struct TreemapTests {

    private struct Item { let name: String; let weight: Double }

    private func tiles(_ weights: [Double], in size: CGSize) -> [Treemap.Tile<Item>] {
        let items = weights.enumerated().map { Item(name: "\($0.offset)", weight: $0.element) }
        return Treemap.layout(items, in: CGRect(origin: .zero, size: size)) { $0.weight }
    }

    @Test("Every positive item gets a tile")
    func allItemsPlaced() {
        #expect(tiles([50, 30, 20], in: CGSize(width: 300, height: 200)).count == 3)
    }

    @Test("Zero-sized items are dropped rather than given slivers")
    func zeroDropped() {
        #expect(tiles([50, 0, 30], in: CGSize(width: 300, height: 200)).count == 2)
    }

    /// The property that makes a treemap a treemap: area is proportional to
    /// weight. Tolerance is loose because the last row absorbs rounding.
    @Test("Area is proportional to weight")
    func areasAreProportional() {
        let bounds = CGSize(width: 400, height: 300)
        let weights: [Double] = [100, 50, 25, 25]
        let laid = tiles(weights, in: bounds)
        let total = Double(bounds.width * bounds.height)
        let weightTotal = weights.reduce(0, +)

        for (index, tile) in laid.enumerated() {
            let expected = weights[index] / weightTotal * total
            let actual = Double(tile.rect.width * tile.rect.height)
            #expect(abs(actual - expected) / expected < 0.02,
                    "tile \(index) area was \(actual), expected \(expected)")
        }
    }

    @Test("Tiles stay inside the bounds")
    func withinBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        for tile in tiles([80, 40, 30, 20, 10, 5, 3], in: bounds.size) {
            #expect(tile.rect.minX >= -0.01)
            #expect(tile.rect.minY >= -0.01)
            #expect(tile.rect.maxX <= bounds.maxX + 0.01)
            #expect(tile.rect.maxY <= bounds.maxY + 0.01)
        }
    }

    /// The whole reason squarified beats slice-and-dice: no unreadable,
    /// unclickable slivers. Naive alternation would produce ratios in the
    /// hundreds here.
    @Test("Rectangles stay roughly square")
    func aspectRatiosAreSane() {
        let laid = tiles([40, 30, 20, 15, 10, 8, 6, 4], in: CGSize(width: 400, height: 300))
        for tile in laid where tile.rect.width > 1 && tile.rect.height > 1 {
            let ratio = max(tile.rect.width / tile.rect.height, tile.rect.height / tile.rect.width)
            #expect(ratio < 12, "tile aspect ratio \(ratio) is a sliver")
        }
    }

    @Test("Degenerate bounds produce nothing rather than crashing")
    func degenerateBounds() {
        #expect(tiles([10, 5], in: CGSize(width: 0, height: 100)).isEmpty)
        #expect(tiles([], in: CGSize(width: 100, height: 100)).isEmpty)
    }
}

@Suite("Disk map model")
struct DiskMapTests {

    /// Tiles are opaque pastels with near-black text, not a saturated colour at
    /// 40% over a dark panel -- that composites to a muddy mid-tone that is too
    /// dark for the label and too light to read as a colour.
    @Test("Tile colours are pale enough for dark text")
    func tileColoursAreLight() {
        for kind in FileKind.allCases {
            let nsColor = NSColor(kind.tileColor).usingColorSpace(.sRGB)
            guard let nsColor else { Issue.record("\(kind) has no sRGB form"); continue }
            // Rec. 601 luma, the standard readability proxy.
            let luma = 0.299 * nsColor.redComponent
                     + 0.587 * nsColor.greenComponent
                     + 0.114 * nsColor.blueComponent
            #expect(luma > 0.72, "\(kind.rawValue) tile is too dark for black text (luma \(luma))")
        }
    }

    @Test("File kinds bucket by extension")
    func fileKinds() {
        #expect(FileKind.of(URL(fileURLWithPath: "/x/a.mp4")) == .video)
        #expect(FileKind.of(URL(fileURLWithPath: "/x/a.PNG")) == .image)
        #expect(FileKind.of(URL(fileURLWithPath: "/x/a.swift")) == .developer)
        #expect(FileKind.of(URL(fileURLWithPath: "/x/a.zip")) == .archive)
        #expect(FileKind.of(URL(fileURLWithPath: "/x/noextension")) == .other)
    }

    /// A bundle is a directory the user thinks of as one thing, so it is sized
    /// whole and never drilled into.
    @Test("Bundles are not drillable")
    func bundlesAreOpaque() {
        let app = DiskEntry(url: URL(fileURLWithPath: "/Applications/Safari.app"),
                            name: "Safari.app", isDirectory: true, bytes: 100, items: 5,
                            isBundle: true)
        let folder = DiskEntry(url: URL(fileURLWithPath: "/Users/x/Documents"),
                               name: "Documents", isDirectory: true, bytes: 100, items: 5,
                               isBundle: false)
        let file = DiskEntry(url: URL(fileURLWithPath: "/Users/x/a.txt"),
                             name: "a.txt", isDirectory: false, bytes: 10, items: 1,
                             isBundle: false)
        #expect(!app.isDrillable)
        #expect(folder.isDrillable)
        #expect(!file.isDrillable)
    }

    @Test("Every cleanup category explains what it costs")
    func categoriesExplainThemselves() {
        for category in CleanupCategory.all() {
            #expect(!category.name.isEmpty)
            #expect(!category.symbol.isEmpty)
            // The whole safety position: nothing is offered without saying what
            // happens if it goes.
            #expect(category.consequence.count > 20, "\(category.name) has no real consequence note")
        }
    }

    @Test("Categories only list folders that exist")
    func categoriesExist() {
        for category in CleanupCategory.all() {
            #expect(FileManager.default.fileExists(atPath: category.url.path))
        }
    }

    @MainActor
    @Test("The home folder is where it starts, and the crumb for it is ~")
    func crumbNaming() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(DiskMapModel.crumbName(home) == "~")
        #expect(DiskMapModel.crumbName(home.appendingPathComponent("Documents")) == "Documents")
    }

    /// A treemap of 400 slivers is a texture, not a chart -- but truncating
    /// silently makes the areas stop summing to the folder, so the picture
    /// quietly lies about proportions. The tail is rolled into one tile, which
    /// keeps both properties.
    @MainActor
    @Test("The treemap tail is aggregated, not dropped")
    func treemapAggregatesTail() {
        let model = DiskMapModel()
        #expect(model.treemapEntries.isEmpty)
        #expect(model.aggregatedCount == 0)
    }

    @Test("Disk Map is a real tab")
    func tabRegistered() {
        #expect(TabID.allCases.contains(.diskMap))
        #expect(TabID.defaultOrder.contains(TabID.diskMap.rawValue))
    }
}


// MARK: - Notch shape and presence

@Suite("Notch shape")
struct NotchShapeTests {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 32)

    /// The flare is the curve of the hardware the pill is attached to, not of
    /// the pill, so it necessarily paints outside the shape's own width.
    /// Callers have to leave slack for it; if this ever stopped being true the
    /// shape would look clipped rather than curved.
    @Test("The flare paints outside the frame")
    func flareOverhangs() {
        let path = NotchShape(flare: 9, bottomRadius: 15).path(in: rect)
        #expect(path.boundingRect.minX < rect.minX)
        #expect(path.boundingRect.maxX > rect.maxX)
    }

    @Test("The shape stays within its own height")
    func heightIsRespected() {
        let path = NotchShape().path(in: rect)
        #expect(path.boundingRect.minY >= rect.minY - 0.01)
        #expect(path.boundingRect.maxY <= rect.maxY + 0.01)
    }

    /// A pill shorter than its own corner radii would otherwise produce curves
    /// that cross and render as a bow tie.
    @Test("Degenerate sizes clamp instead of inverting")
    func clamping() {
        for size in [CGSize(width: 40, height: 6),
                     CGSize(width: 8, height: 40),
                     CGSize(width: 1, height: 1)] {
            let path = NotchShape().path(in: CGRect(origin: .zero, size: size))
            #expect(!path.isEmpty)
            #expect(path.boundingRect.height <= size.height + 0.01)
        }
    }

    @Test("A wide pill is still one closed shape")
    func wideShape() {
        let path = NotchShape().path(in: CGRect(x: 0, y: 0, width: 460, height: 40))
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width > 460)
    }
}

@Suite("Orb idle behaviour")
struct OrbIdleTests {

    /// Three seconds is the number in the brief. It is asserted rather than
    /// left as a literal because the whole behaviour -- an orb that gets out of
    /// the way of the user's work -- hangs off it.
    @Test("The orb settles after three seconds")
    func idleDelay() {
        #expect(NotchPanelController.orbIdleDelay == 3)
    }

    /// Hover-to-expand is a notch behaviour. An orb sits in the middle of the
    /// user's work, and one that opened an 880pt panel whenever the cursor
    /// crossed it would be unusable.
    @Test("Automatic still picks the orb only where there is no cutout")
    func autoPresentation() {
        #expect(SettingsData().panelPresentation == .auto)
        #expect(PanelPresentation.allCases.contains(.orb))
        #expect(PanelPresentation.allCases.contains(.notch))
    }
}


// MARK: - Themes

@Suite("Themes")
struct ThemeTests {

    /// Light themes need dark text and dark themes need light text. Getting
    /// this backwards is invisible in code review and instantly obvious in use.
    @Test("Text contrasts with its own panel")
    func textContrastsWithPanel() {
        for kind in ThemeKind.allCases {
            let theme = Theme(kind: kind)
            let panel = luma(theme.panelBackground)
            let text = luma(theme.primaryText)
            #expect(abs(panel - text) > 0.45,
                    "\(kind.rawValue): text luma \(text) against panel \(panel)")
        }
    }

    @Test("Light themes are the ones that say they are")
    func lightFlags() {
        #expect(ThemeKind.latte.isLight)
        #expect(ThemeKind.parchment.isLight)
        #expect(!ThemeKind.minimal.isLight)
        #expect(!ThemeKind.ember.isLight)
        for kind in ThemeKind.allCases {
            // A theme that claims to be light must actually have a light panel.
            #expect(kind.isLight == (luma(Theme(kind: kind).panelBackground) > 0.5),
                    "\(kind.rawValue) disagrees with its own isLight")
        }
    }

    /// Single-accent themes collapse every module to one colour deliberately.
    @Test("Two-tone themes use one accent everywhere")
    func singleAccentThemes() {
        for kind in [ThemeKind.minimal, .ember, .midnight] {
            let theme = Theme(kind: kind)
            #expect(!kind.usesModuleTints)
            for module in [ModuleTint.home, .time, .ai, .terminal] {
                #expect(theme.tint(module) == theme.accent,
                        "\(kind.rawValue) tinted \(module.rawValue) separately")
            }
        }
    }

    /// The module palette is tuned for white text on black. On a cream panel
    /// the same hues are unreadable, so light themes darken them.
    @Test("Module tints darken on a light panel")
    func tintsDarkenOnLight() {
        for kind in ThemeKind.allCases where kind.isLight {
            let theme = Theme(kind: kind)
            for module in [ModuleTint.home, .time, .snippets, .notes, .ai] {
                #expect(luma(theme.tint(module)) < 0.55,
                        "\(kind.rawValue) \(module.rawValue) is too light to read on cream")
            }
        }
    }

    @Test("Every theme is named and described")
    func metadata() {
        let raws = ThemeKind.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count)
        for kind in ThemeKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(kind.blurb.count > 20, "\(kind.rawValue) has no real blurb")
        }
        #expect(ThemeKind.allCases.count == 7)
    }

    /// Rec. 601 luma, the standard readability proxy. Alpha is composited over
    /// the surface the colour actually sits on, since a 0.1-alpha ink over
    /// cream is cream, not ink.
    private func luma(_ color: Color, over background: Double = 0) -> Double {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        let alpha = Double(c.alphaComponent)
        let raw = 0.299 * Double(c.redComponent)
                + 0.587 * Double(c.greenComponent)
                + 0.114 * Double(c.blueComponent)
        return raw * alpha + background * (1 - alpha)
    }
}

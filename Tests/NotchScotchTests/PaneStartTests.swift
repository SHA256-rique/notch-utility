import Testing
import Foundation
@testable import NotchScotch

/// The bug these cover: in a four-way split, only the first pane drew anything.
///
/// The shells were all running the whole time — four ptys, four prompts, four
/// live pids. What was broken was view *identity*: the Canvas forces a redraw by
/// changing its `.id()`, and the key did not include the session. Three
/// unfocused panes therefore produced byte-identical keys (same generation, same
/// cursor phase, `isFocused: false`, no selection), and three siblings sharing
/// one explicit identity is not three views to SwiftUI.
@Suite("Terminal pane rendering identity")
struct PaneRenderIdentityTests {

    private let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    private func key(_ id: UUID, focused: Bool = false, generation: Int = 2) -> String {
        TerminalGridView.renderKey(sessionID: id, generation: generation,
                                   cursorOn: true, isFocused: focused, selection: nil)
    }

    /// The regression itself. Two unfocused panes in identical states must still
    /// be two different views.
    @Test("Two unfocused panes in the same state get different keys")
    func unfocusedPanesAreDistinct() {
        #expect(key(a) != key(b))
    }

    @Test("Every pane in a four-way split is distinct")
    func fourPanesAreDistinct() {
        let ids = (0..<4).map { _ in UUID() }
        // Pane 0 focused, the rest not — the exact shape of the bug.
        let keys = ids.enumerated().map { key($1, focused: $0 == 0) }
        #expect(Set(keys).count == 4)
    }

    /// The key still has to *change* when the content does, or the Canvas never
    /// redraws and the terminal appears frozen.
    @Test("A new generation is a new key")
    func generationChangesKey() {
        #expect(key(a, generation: 2) != key(a, generation: 3))
    }

    @Test("Focus, cursor phase and selection all change the key")
    func stateChangesKey() {
        #expect(key(a, focused: false) != key(a, focused: true))

        let blinkOff = TerminalGridView.renderKey(sessionID: a, generation: 1,
                                                  cursorOn: false, isFocused: true, selection: nil)
        let blinkOn = TerminalGridView.renderKey(sessionID: a, generation: 1,
                                                 cursorOn: true, isFocused: true, selection: nil)
        #expect(blinkOff != blinkOn)

        let selected = TerminalGridView.renderKey(
            sessionID: a, generation: 1, cursorOn: true, isFocused: true,
            selection: TerminalSelection(anchor: .init(line: 1, column: 0),
                                         head: .init(line: 3, column: 5)))
        #expect(selected != blinkOn)
    }

    /// Same inputs, same key — otherwise the Canvas would be rebuilt on every
    /// body evaluation, which is the cost `Canvas` exists to avoid.
    @Test("The key is stable for unchanged state")
    func keyIsStable() {
        #expect(key(a) == key(a))
    }
}

/// The other half of "only the first terminal has a CLI", and the one that was
/// actually making every pane blank.
///
/// `visibleLines` is the *last* `rows` lines of the buffer. `resize` grew the
/// line array when the screen got taller but never shrank it when the screen
/// got shorter — so after splitting one terminal into four, `lines.count` stayed
/// at the old height while `rows` dropped, the viewport slid down the buffer,
/// and a shell that had printed exactly one prompt showed nothing at all.
///
/// It never bit in single-pane mode because that only ever resizes *upward* from
/// the emulator's 28-row default.
@Suite("Emulator resize keeps content in view")
struct EmulatorShrinkTests {

    private func emulatorWithPrompt(columns: Int = 80, rows: Int = 28) -> TerminalEmulator {
        let emulator = TerminalEmulator(columns: columns, rows: rows)
        emulator.feed(Data("user@host project % ".utf8))
        return emulator
    }

    @Test("Shrinking the screen keeps the prompt visible")
    func shrinkKeepsPromptVisible() {
        let emulator = emulatorWithPrompt()
        emulator.resize(columns: 54, rows: 23)

        let first = emulator.visibleLines.first.map { String($0.cells.map(\.character)) } ?? ""
        #expect(first.contains("user@host"), "the prompt scrolled out of view on shrink")
    }

    /// The exact numbers from the four-way split that exposed this.
    @Test("The buffer does not stay taller than the screen")
    func bufferMatchesRows() {
        let emulator = emulatorWithPrompt()
        emulator.resize(columns: 54, rows: 23)
        #expect(emulator.lines.count == 23,
                "buffer is \(emulator.lines.count) lines for a 23-row screen")
    }

    /// The fix must not throw away scrollback. Only *blank* trailing lines go.
    @Test("Real scrollback survives a shrink")
    func scrollbackSurvives() {
        let emulator = TerminalEmulator(columns: 80, rows: 10)
        for i in 0..<30 { emulator.feed(Data("line \(i)\r\n".utf8)) }
        let before = emulator.lines.filter { line in
            line.cells.contains { $0.character != " " }
        }.count

        emulator.resize(columns: 60, rows: 6)
        let after = emulator.lines.filter { line in
            line.cells.contains { $0.character != " " }
        }.count
        #expect(after == before, "shrinking discarded \(before - after) lines of real output")
    }

    @Test("Growing still pads to the new height")
    func growthStillPads() {
        let emulator = emulatorWithPrompt(rows: 10)
        emulator.resize(columns: 80, rows: 40)
        #expect(emulator.lines.count >= 40)
        let first = emulator.visibleLines.first.map { String($0.cells.map(\.character)) } ?? ""
        #expect(first.contains("user@host"))
    }

    @Test("A shrink to the same size changes nothing")
    func noOpResize() {
        let emulator = emulatorWithPrompt(columns: 80, rows: 28)
        let before = emulator.lines.count
        emulator.resize(columns: 80, rows: 28)
        #expect(emulator.lines.count == before)
    }
}

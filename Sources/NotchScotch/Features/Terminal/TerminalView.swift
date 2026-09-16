import SwiftUI
import AppKit

/// A live text selection, in absolute buffer coordinates.
///
/// Absolute rather than screen-relative so a selection survives the screen
/// scrolling underneath it -- select an error, let the build print another
/// twenty lines, and cmd-C still copies the error.
struct TerminalSelection: Equatable {
    var anchor: TerminalEmulator.Position
    var head: TerminalEmulator.Position

    var start: TerminalEmulator.Position { min(anchor, head) }
    var end: TerminalEmulator.Position { max(anchor, head) }
    var isEmpty: Bool { anchor == head }

    func contains(line: Int, column: Int) -> Bool {
        let position = TerminalEmulator.Position(line: line, column: column)
        return position >= start && position <= end
    }
}

/// Renders the emulator grid and captures keystrokes.
///
/// ## Why Canvas and not a Text per line
/// A 100x28 grid is 2,800 cells. Building a SwiftUI view per cell -- or even per
/// styled run -- creates thousands of view identities that must be diffed on
/// every frame of output. `Canvas` draws directly into a single drawing context
/// with no view tree at all, which turns a redraw from "diff 2,800 views" into
/// "run a loop". This is the single biggest performance decision in the tab.
///
/// Cells are grouped into runs of identical styling before drawing, so a line of
/// plain text is one `draw` call rather than 100.
struct TerminalGridView: View {
    @ObservedObject var session: TerminalSession
    let font: NSFont
    let cellSize: CGSize
    @Binding var selection: TerminalSelection?
    var cursorOn: Bool
    var isFocused: Bool

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let emulator = session.emulator
            let lines = Array(emulator.visibleLines)
            let firstLine = emulator.firstVisibleLineIndex
            let cursorRow = emulator.visibleCursorRow

            for (rowIndex, line) in lines.enumerated() {
                let y = CGFloat(rowIndex) * cellSize.height
                let absoluteLine = firstLine + rowIndex

                // Selection is painted first, as one rect per contiguous span,
                // so the text runs below can draw straight over it without
                // having to know anything about selection at all.
                if let selection, !selection.isEmpty {
                    drawSelection(selection, line: absoluteLine, width: line.cells.count,
                                  y: y, in: &context)
                }

                var column = 0
                while column < line.cells.count {
                    let cell = line.cells[column]
                    // Extend the run while styling is identical.
                    var end = column + 1
                    while end < line.cells.count && sameStyle(line.cells[end], cell) { end += 1 }

                    let text = String(line.cells[column..<end].map(\.character))
                    let x = CGFloat(column) * cellSize.width

                    let foreground = cell.inverse
                        ? ANSIPalette.color(cell.background, bold: false)
                        : ANSIPalette.color(cell.foreground, bold: cell.bold)
                    let background = cell.inverse
                        ? ANSIPalette.color(cell.foreground, bold: cell.bold)
                        : ANSIPalette.color(cell.background, bold: false)

                    // Only paint a background when there is one; painting black
                    // over black for every cell doubles the draw calls. A
                    // selected run keeps the selection colour instead.
                    let selected = selection?.contains(line: absoluteLine, column: column) ?? false
                    if (cell.background != 0 || cell.inverse) && !selected {
                        context.fill(
                            Path(CGRect(x: x, y: y,
                                        width: CGFloat(end - column) * cellSize.width,
                                        height: cellSize.height)),
                            with: .color(background))
                    }

                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        var attributed = AttributedString(text)
                        attributed.font = Font(font)
                        attributed.foregroundColor = cell.dim ? foreground.opacity(0.6) : foreground
                        if cell.underline { attributed.underlineStyle = .single }
                        context.draw(Text(attributed), at: CGPoint(x: x, y: y), anchor: .topLeading)
                    }
                    column = end
                }
            }

            // Cursor. Blinks only when focused and the viewport is live; a
            // blinking cursor over scrolled-back history would suggest you can
            // type there, and a cursor in an unfocused pane should say so by
            // going hollow rather than by vanishing.
            if emulator.cursorVisible, session.isRunning,
               !emulator.isScrolledBack,
               cursorRow >= 0, cursorRow < lines.count {
                let rect = CGRect(x: CGFloat(emulator.cursorColumn) * cellSize.width,
                                  y: CGFloat(cursorRow) * cellSize.height,
                                  width: cellSize.width, height: cellSize.height)
                if isFocused {
                    if cursorOn {
                        context.fill(Path(rect), with: .color(.white.opacity(0.85)))
                        // Punch the glyph back out in the background colour so a
                        // character under the block stays legible.
                        let under = lines[cursorRow].cells.indices.contains(emulator.cursorColumn)
                            ? lines[cursorRow].cells[emulator.cursorColumn].character : " "
                        if under != " " {
                            var attributed = AttributedString(String(under))
                            attributed.font = Font(font)
                            attributed.foregroundColor = .black
                            context.draw(Text(attributed),
                                         at: CGPoint(x: rect.minX, y: rect.minY), anchor: .topLeading)
                        }
                    }
                } else {
                    context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                                   with: .color(.white.opacity(0.5)), lineWidth: 1)
                }
            }
        }
        // `generation` is the only thing the Canvas observes. The emulator itself
        // is a plain class, deliberately not @Published per mutation.
        .id(Self.renderKey(sessionID: session.id,
                           generation: session.generation,
                           cursorOn: cursorOn,
                           isFocused: isFocused,
                           selection: selection))
    }

    /// Identity for the Canvas, which is how it is forced to redraw.
    ///
    /// The emulator is a plain class, deliberately not `@Published` per
    /// mutation, so SwiftUI has no way to know its contents changed. Changing
    /// the view's identity is what makes `Canvas` re-run its draw closure.
    ///
    /// **The session id has to be in here.** Without it, every unfocused pane in
    /// a split produced the *same* key -- same generation, same cursor phase,
    /// `isFocused: false`, no selection -- and three sibling views sharing one
    /// explicit identity is not three views to SwiftUI. It drew one and left the
    /// rest blank, which is exactly what "only the first terminal has a CLI"
    /// looked like. The shells were all running the whole time.
    nonisolated static func renderKey(sessionID: UUID,
                                      generation: Int,
                                      cursorOn: Bool,
                                      isFocused: Bool,
                                      selection: TerminalSelection?) -> String {
        "\(sessionID.uuidString)-\(generation)-\(cursorOn)-\(isFocused)"
            + "-\(selection?.head.line ?? -1)-\(selection?.head.column ?? -1)"
    }

    private func drawSelection(_ selection: TerminalSelection, line: Int, width: Int,
                               y: CGFloat, in context: inout GraphicsContext) {
        guard line >= selection.start.line, line <= selection.end.line else { return }
        let lower = line == selection.start.line ? selection.start.column : 0
        let upper = line == selection.end.line ? min(selection.end.column, width - 1) : width - 1
        guard upper >= lower else { return }
        let rect = CGRect(x: CGFloat(lower) * cellSize.width,
                          y: y,
                          width: CGFloat(upper - lower + 1) * cellSize.width,
                          height: cellSize.height)
        context.fill(Path(rect), with: .color(.white.opacity(0.22)))
    }

    private func sameStyle(_ a: TerminalEmulator.Cell, _ b: TerminalEmulator.Cell) -> Bool {
        a.foreground == b.foreground && a.background == b.background
            && a.bold == b.bold && a.dim == b.dim && a.italic == b.italic
            && a.underline == b.underline && a.inverse == b.inverse
    }
}

/// An NSView whose only job is to be first responder and forward key events.
/// SwiftUI has no way to receive raw `NSEvent`s for arrow keys and control
/// characters in a non-activating panel, so this bridges the gap.
///
/// It also carries the scroll wheel and the focus signal, because both come
/// from AppKit and both need to reach SwiftUI state.
struct TerminalKeyCatcher: NSViewRepresentable {
    let session: TerminalSession
    /// Selected text, or nil. Supplied by the view so cmd-C can copy it without
    /// this type needing to understand selection.
    var selectedText: () -> String?
    var onScroll: (Int) -> Void
    var onFocusChange: (Bool) -> Void
    var onFontStep: (Int) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.configure(session: session, selectedText: selectedText,
                       onScroll: onScroll, onFocusChange: onFocusChange, onFontStep: onFontStep)
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.configure(session: session, selectedText: selectedText,
                         onScroll: onScroll, onFocusChange: onFocusChange, onFontStep: onFontStep)
        // Re-take first responder after a tab switch brings us back.
        DispatchQueue.main.async {
            guard nsView.window?.firstResponder !== nsView else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        private var session: TerminalSession?
        private var selectedText: (() -> String?)?
        private var onScroll: ((Int) -> Void)?
        private var onFocusChange: ((Bool) -> Void)?
        private var onFontStep: ((Int) -> Void)?
        /// Accumulates sub-line trackpad deltas. Without this, a slow two-finger
        /// scroll produces a stream of zero-line scrolls and the view never moves.
        private var scrollRemainder: CGFloat = 0

        func configure(session: TerminalSession,
                       selectedText: @escaping () -> String?,
                       onScroll: @escaping (Int) -> Void,
                       onFocusChange: @escaping (Bool) -> Void,
                       onFontStep: @escaping (Int) -> Void) {
            self.session = session
            self.selectedText = selectedText
            self.onScroll = onScroll
            self.onFocusChange = onFocusChange
            self.onFontStep = onFontStep
        }

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            onFocusChange?(true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            onFocusChange?(false)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard let session, session.handle(event: event) else {
                super.keyDown(with: event)
                return
            }
        }

        override func scrollWheel(with event: NSEvent) {
            scrollRemainder += event.scrollingDeltaY
            let lines = Int(scrollRemainder / 12)
            guard lines != 0 else { return }
            scrollRemainder -= CGFloat(lines) * 12
            onScroll?(lines)
        }

        // Without this, cmd-V and friends are swallowed by the responder chain
        // before keyDown sees them.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  let characters = event.charactersIgnoringModifiers else { return false }
            switch characters {
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) {
                    session?.send(text)
                }
                return true
            case "c":
                // With a selection, cmd-C means copy, as it does everywhere else.
                // Without one it falls through to ctrl-C, which is what a user
                // hitting it in a terminal almost always wants.
                if let text = selectedText?(), !text.isEmpty {
                    ClipboardWatcher.shared.suppressNextChange()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    NotchArbiter.shared.flash("Copied", symbol: "doc.on.doc.fill", module: .terminal)
                } else {
                    session?.send(Data([0x03]))
                }
                return true
            case "k":
                session?.send("\u{0C}")     // form feed -> clear
                return true
            case "+", "=":
                onFontStep?(1)
                return true
            case "-":
                onFontStep?(-1)
                return true
            default: return false
            }
        }
    }
}

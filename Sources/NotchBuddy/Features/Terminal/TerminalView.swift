import SwiftUI
import AppKit

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

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let emulator = session.emulator
            let lines = Array(emulator.visibleLines)
            let cursorRow = emulator.visibleCursorRow

            for (rowIndex, line) in lines.enumerated() {
                let y = CGFloat(rowIndex) * cellSize.height

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
                    // over black for every cell doubles the draw calls.
                    if cell.background != 0 || cell.inverse {
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

            // Cursor
            if emulator.cursorVisible, session.isRunning,
               cursorRow >= 0, cursorRow < lines.count {
                let rect = CGRect(x: CGFloat(emulator.cursorColumn) * cellSize.width,
                                  y: CGFloat(cursorRow) * cellSize.height,
                                  width: cellSize.width, height: cellSize.height)
                context.fill(Path(rect), with: .color(.white.opacity(0.75)))
            }
        }
        // `generation` is the only thing the Canvas observes. The emulator itself
        // is a plain class, deliberately not @Published per mutation.
        .id(session.generation)
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
struct TerminalKeyCatcher: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.session = session
        // Re-take first responder after a tab switch brings us back.
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyView: NSView {
        var session: TerminalSession?
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { true }

        override func keyDown(with event: NSEvent) {
            guard let session, session.handle(event: event) else {
                super.keyDown(with: event)
                return
            }
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
                // Nothing is selected in this minimal renderer, so cmd-C falls
                // through to ctrl-C semantics, which is what a user hitting it
                // in a terminal almost always wants.
                session?.send(Data([0x03]))
                return true
            case "k":
                session?.send("\u{0C}")     // form feed -> clear
                return true
            default: return false
            }
        }
    }
}

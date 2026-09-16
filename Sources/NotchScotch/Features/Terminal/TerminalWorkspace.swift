import SwiftUI
import AppKit
import Combine

/// Up to four shells in one tab, arranged the way tmux arranges panes.
///
/// ## Why four
/// Not an arbitrary cap. The panel is about 820pt wide; four panes means each is
/// roughly 400pt, which at an 11pt monospace font is about 60 columns -- already
/// below the 80 that most CLI output is written for. A fifth pane would produce
/// windows too narrow to read a stack trace in, and a terminal you cannot read
/// is not a terminal.
///
/// ## Why the layouts are fixed
/// tmux lets you build arbitrary pane trees. That is right for a full-screen
/// multiplexer you live in and wrong for a notch panel: the value here is
/// "watch a build while you run something else", and every arrangement worth
/// having for that is covered by four presets. A tree would mean a splitter
/// widget, drag-to-resize, and a persistence format, for arrangements nobody
/// would make twice at this size.
@MainActor
final class TerminalWorkspace: ObservableObject {
    static let shared = TerminalWorkspace()

    enum Layout: String, Codable, CaseIterable, Identifiable {
        /// One pane.
        case single
        /// Two side by side.
        case columns
        /// Two stacked.
        case rows
        /// One tall on the left, two stacked on the right. tmux's main-vertical.
        case mainLeft
        /// Two by two.
        case grid

        var id: String { rawValue }

        var paneCount: Int {
            switch self {
            case .single: return 1
            case .columns, .rows: return 2
            case .mainLeft: return 3
            case .grid: return 4
            }
        }

        var symbol: String {
            switch self {
            case .single:   return "square"
            case .columns:  return "rectangle.split.2x1"
            case .rows:     return "rectangle.split.1x2"
            case .mainLeft: return "rectangle.split.3x1"
            case .grid:     return "rectangle.split.2x2"
            }
        }

        var title: String {
            switch self {
            case .single:   return "Single"
            case .columns:  return "Side by side"
            case .rows:     return "Stacked"
            case .mainLeft: return "Main + two"
            case .grid:     return "Grid of four"
            }
        }

        /// The layout one step up in pane count, for the split button.
        var next: Layout? {
            switch self {
            case .single:   return .columns
            case .columns:  return .mainLeft
            case .rows:     return .mainLeft
            case .mainLeft: return .grid
            case .grid:     return nil
            }
        }
    }

    @Published private(set) var panes: [TerminalSession] = [TerminalSession.shared]
    @Published private(set) var layout: Layout = .single
    /// Index into `panes`. Keystrokes and the approval detector follow it.
    @Published var focused: Int = 0

    /// Text selection per pane, keyed by session id.
    ///
    /// Lifted out of the pane view because the tab now mounts a **single** key
    /// catcher rather than one per pane -- see `TerminalTabView` -- and that
    /// catcher has to be able to read the focused pane's selection for cmd-C.
    /// Per-pane `@State` was unreachable from there.
    @Published var selections: [UUID: TerminalSelection] = [:]

    func selection(for pane: TerminalSession) -> TerminalSelection? {
        selections[pane.id]
    }

    func setSelection(_ selection: TerminalSelection?, for pane: TerminalSession) {
        if let selection { selections[pane.id] = selection } else { selections[pane.id] = nil }
    }

    /// Selected text in the focused pane, or nil.
    func focusedSelectionText() -> String? {
        let pane = focusedPane
        guard let selection = selections[pane.id], !selection.isEmpty else { return nil }
        let text = pane.emulator.text(from: selection.start, to: selection.end)
        return text.isEmpty ? nil : text
    }

    static let maxPanes = 4

    private init() {}

    var focusedPane: TerminalSession {
        panes.indices.contains(focused) ? panes[focused] : panes[0]
    }

    var canSplit: Bool { panes.count < Self.maxPanes }

    // MARK: - Splitting

    /// Adds a pane and moves to the layout that holds it.
    func split() {
        guard canSplit, let next = layout.next else { return }
        setLayout(next)
    }

    /// Changes layout, creating or retiring panes to match.
    ///
    /// Retired panes are stopped, not parked: an invisible shell still holds a
    /// pty, a process group and an emulator buffer, and "I closed it" has to
    /// mean it is gone or the memory story here is a lie.
    func setLayout(_ new: Layout) {
        let wanted = new.paneCount
        while panes.count < wanted {
            panes.append(TerminalSession())
        }
        while panes.count > wanted {
            let removed = panes.removeLast()
            selections[removed.id] = nil
            removed.forceStop()
        }
        layout = new
        focused = min(focused, panes.count - 1)
    }

    /// Closes one pane. With one left this is a no-op: an empty terminal tab
    /// showing nothing would be worse than the shell it replaced.
    func closePane(at index: Int) {
        guard panes.count > 1, panes.indices.contains(index) else { return }
        selections[panes[index].id] = nil
        panes[index].forceStop()
        panes.remove(at: index)
        layout = Self.layout(forPaneCount: panes.count, preferring: layout)
        focused = min(focused, panes.count - 1)
    }

    /// Picks the layout that fits a pane count, keeping the current one when it
    /// already does, so closing a pane out of a 2x2 grid does not also flip the
    /// two survivors from stacked to side by side.
    nonisolated static func layout(forPaneCount count: Int, preferring current: Layout) -> Layout {
        if current.paneCount == count { return current }
        switch count {
        case 1:  return .single
        case 2:  return current == .rows ? .rows : .columns
        case 3:  return .mainLeft
        default: return .grid
        }
    }

    func focusNext() {
        guard panes.count > 1 else { return }
        focused = (focused + 1) % panes.count
    }

    // MARK: - Lifecycle

    /// Starts every pane. Sizes are supplied by the view, which is the only
    /// thing that knows how big each slot ended up.
    func startAll(paneSize: (Int) -> (columns: Int, rows: Int)) {
        for (index, pane) in panes.enumerated() {
            let size = paneSize(index)
            pane.start(columns: size.columns, rows: size.rows)
        }
    }

    func resizeAll(paneSize: (Int) -> (columns: Int, rows: Int)) {
        for (index, pane) in panes.enumerated() {
            let size = paneSize(index)
            pane.resize(columns: size.columns, rows: size.rows)
        }
    }

    /// Called when the tab closes. Honours "keep alive in background" for the
    /// first pane only -- that setting exists so a long build survives a glance
    /// at another tab, and one surviving shell covers that. Keeping four would
    /// quietly hold four ptys for a tab nobody has open.
    func stopAll() {
        for (index, pane) in panes.enumerated() {
            if index == 0 {
                pane.stop()
            } else {
                pane.forceStop()
            }
        }
    }

    // MARK: - Handing off to a real terminal

    /// Terminal apps worth offering, in the order most people would want them.
    /// Detected by bundle path so the list only ever shows what is installed.
    struct ExternalTerminal: Identifiable, Hashable {
        var id: String { bundleID }
        let name: String
        let bundleID: String
    }

    nonisolated static let knownTerminals: [ExternalTerminal] = [
        ExternalTerminal(name: "Terminal", bundleID: "com.apple.Terminal"),
        ExternalTerminal(name: "iTerm2", bundleID: "com.googlecode.iterm2"),
        ExternalTerminal(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
        ExternalTerminal(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
        ExternalTerminal(name: "Kitty", bundleID: "net.kovidgoyal.kitty"),
        ExternalTerminal(name: "Alacritty", bundleID: "org.alacritty"),
        ExternalTerminal(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        ExternalTerminal(name: "Hyper", bundleID: "co.zeit.hyper")
    ]

    nonisolated static func installedTerminals() -> [ExternalTerminal] {
        knownTerminals.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    /// Opens the focused pane in a real terminal app, carrying its context.
    ///
    /// ## What actually transfers
    /// **The working directory**, exactly, from `proc_pidinfo` -- the kernel's
    /// answer for the shell's cwd, rather than parsing a user-configurable
    /// prompt or shipping a zshrc hook.
    ///
    /// **The scrollback**, printed into the new window. This is the part that
    /// took care to do safely.
    ///
    /// Terminal and iTerm2 both expose AppleScript `do script`, which *runs*
    /// what it is given. Handing it a build log is remote code execution
    /// triggered by whatever happened to be in the output -- a stray line
    /// beginning `rm` would simply run. So the transcript is written to a temp
    /// file and the command we build is `cd <dir> && cat <file>`: the only
    /// strings we execute are ones this function constructed, and the
    /// transcript is *displayed* rather than interpreted.
    ///
    /// **The running process does not transfer**, and nothing can make it. A
    /// process is attached to its controlling terminal; moving it would mean
    /// reparenting it onto a pty owned by another application.
    ///
    /// Apps without AppleScript support (Ghostty, Kitty, Alacritty, WezTerm)
    /// get the directory and the clipboard, which is as far as their public
    /// interface goes.
    @discardableResult
    func handOffToExternalTerminal() -> Bool {
        let pane = focusedPane
        let directory = pane.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        let bundleID = Settings.shared.data.externalTerminalBundleID
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            NotchArbiter.shared.flash("No terminal app found", symbol: "exclamationmark.triangle.fill",
                                      module: .terminal)
            return false
        }

        let transcript = pane.transcript(lastLines: 500)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The clipboard is populated regardless: it is the one route that works
        // in every terminal, and it costs nothing to have both.
        if !transcript.isEmpty {
            ClipboardWatcher.shared.suppressNextChange()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
        }

        if Self.supportsScripting(bundleID) {
            let name = TerminalWorkspace.knownTerminals.first { $0.bundleID == bundleID }?.name ?? "Terminal"
            if runScripted(bundleID: bundleID, directory: directory, transcript: transcript) {
                NotchArbiter.shared.flash("Opened in \(name)", symbol: "arrow.up.forward.app.fill",
                                          module: .terminal, detail: "with the last 500 lines")
                return true
            }
            // Scripting can be refused (the automation permission prompt was
            // declined), so fall through rather than failing outright.
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)],
                                withApplicationAt: appURL,
                                configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    NotchArbiter.shared.flash("Could not open terminal", symbol: "exclamationmark.triangle.fill",
                                              module: .terminal, detail: error.localizedDescription)
                } else {
                    NotchArbiter.shared.flash("Opened in \(appURL.deletingPathExtension().lastPathComponent)",
                                              symbol: "arrow.up.forward.app.fill",
                                              module: .terminal,
                                              detail: transcript.isEmpty ? directory : "scrollback copied")
                }
            }
        }
        return true
    }

    /// The two terminals with a documented `do script`.
    nonisolated static func supportsScripting(_ bundleID: String) -> Bool {
        bundleID == "com.apple.Terminal" || bundleID == "com.googlecode.iterm2"
    }

    /// Opens a window that `cd`s to the directory and prints the transcript.
    private func runScripted(bundleID: String, directory: String, transcript: String) -> Bool {
        var command = "cd \(Self.shellQuote(directory))"

        if !transcript.isEmpty {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("notchscotch-transcript-\(UUID().uuidString).txt")
            let header = "──── carried over from NotchScotch ────\n"
            let footer = "\n──── end of carried-over output ────\n"
            guard (try? (header + transcript + footer).write(to: file, atomically: true,
                                                             encoding: .utf8)) != nil else {
                return false
            }
            // `cat` then delete. The transcript is printed, never evaluated.
            command += " && cat \(Self.shellQuote(file.path)) && rm -f \(Self.shellQuote(file.path))"
        }

        let script: String
        switch bundleID {
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text \(Self.appleScriptQuote(command))
            end tell
            """
        default:
            script = """
            tell application "Terminal"
                activate
                do script \(Self.appleScriptQuote(command))
            end tell
            """
        }

        var error: NSDictionary?
        let ran = NSAppleScript(source: script)?.executeAndReturnError(&error)
        if ran == nil {
            Log.term.error("terminal handoff script failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    /// Single-quotes a path for `sh`. The only character that matters inside
    /// single quotes is a single quote, which is closed, escaped and reopened --
    /// the standard `'\''` idiom. A directory named `it's` would otherwise
    /// break the command, and worse, could end it.
    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quotes a string as an AppleScript literal. Backslashes first, or the
    /// escaping of the quotes would itself be escaped.
    nonisolated static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}

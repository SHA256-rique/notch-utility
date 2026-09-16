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
            removed.forceStop()
        }
        layout = new
        focused = min(focused, panes.count - 1)
    }

    /// Closes one pane. With one left this is a no-op: an empty terminal tab
    /// showing nothing would be worse than the shell it replaced.
    func closePane(at index: Int) {
        guard panes.count > 1, panes.indices.contains(index) else { return }
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

    /// Opens the focused pane's directory in a real terminal app.
    ///
    /// ## What "copy the context over" can and cannot mean
    /// The **working directory** transfers exactly: it comes from the kernel and
    /// the new terminal opens there, which is the part of the context people
    /// actually mean.
    ///
    /// The **scrollback** goes to the clipboard rather than being typed into the
    /// new window. Terminal.app and iTerm2 both expose an AppleScript `do
    /// script`, and it would be easy to shove the transcript through it -- but
    /// `do script` *executes* what it is given. Replaying a build log through a
    /// shell is a remote code execution bug with extra steps, triggered by
    /// whatever happened to be in the output. The clipboard is one keystroke
    /// away and cannot run anything.
    ///
    /// The **running process** does not transfer at all, and nothing can make it:
    /// a process is attached to its controlling terminal, and moving it would
    /// mean reparenting it onto a pty owned by another application.
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

        let transcript = pane.transcript(lastLines: 400)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            ClipboardWatcher.shared.suppressNextChange()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
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
}

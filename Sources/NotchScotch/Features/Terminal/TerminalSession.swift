import SwiftUI
import AppKit
import Combine
import Darwin

/// Binds a `PTY` to a `TerminalEmulator` and exposes a redraw signal to SwiftUI.
///
/// ## The coalescing detail that makes this cheap
/// A build tool can emit thousands of writes per second. Publishing a SwiftUI
/// change per write would melt a core re-laying-out the grid. Instead every
/// chunk is fed to the emulator immediately (so the model is always current) but
/// the *redraw* is coalesced to at most 30fps. Output stays correct; rendering
/// stays bounded.
///
/// ## Lifecycle
/// Nothing exists until `start()`, which the Terminal tab calls from
/// `.onAppear`. `stop()` on `.onDisappear` kills the process group and releases
/// the emulator's buffers -- unless the user has explicitly opted into keeping a
/// background session alive, which is off by default per the brief.
@MainActor
final class TerminalSession: ObservableObject {
    /// Shared so that "keep alive in background" can actually outlive the view.
    /// This is pane 1 of the workspace; further panes are ordinary instances.
    static let shared = TerminalSession()

    /// Stable identity, so SwiftUI can tell four panes apart in a ForEach.
    let id = UUID()

    @Published private(set) var generation = 0
    @Published private(set) var isRunning = false
    @Published private(set) var exitMessage: String?

    let emulator = TerminalEmulator()
    private let pty = PTY()
    private var redrawScheduled = false
    /// Hook for the approval detector to observe the byte stream.
    var outputObserver: ((Data) -> Void)?

    /// `private` until splits existed. A workspace of up to four panes needs to
    /// create its own, and the singleton stays only because "keep alive in
    /// background" has to outlive the view that made it.
    init() {}

    func start(columns: Int, rows: Int) {
        guard !isRunning else {
            // Already alive from a kept-open background session; just resize.
            resize(columns: columns, rows: rows)
            return
        }
        exitMessage = nil
        emulator.resize(columns: columns, rows: rows)

        pty.onOutput = { [weak self] data in
            guard let self else { return }
            self.emulator.feed(data)
            self.outputObserver?(data)
            self.scheduleRedraw()
        }
        pty.onExit = { [weak self] status in
            guard let self else { return }
            self.isRunning = false
            self.exitMessage = status == 0 ? "Session ended." : "Shell exited (\(status))."
            self.generation &+= 1
        }

        // Advertise ourselves so a CLI running in here can detect that it has an
        // approval channel available. The approval hook reads this.
        let extraEnvironment = [
            "NOTCHSCOTCH_SESSION": "1",
            "NOTCHSCOTCH_HOOK_SOCKET": AppPaths.hookDirectory.appendingPathComponent("approval.sock").path
        ]

        isRunning = pty.start(shell: Settings.shared.data.terminalShell,
                              columns: UInt16(columns), rows: UInt16(rows),
                              extraEnvironment: extraEnvironment)
        if !isRunning { exitMessage = "Couldn't start a shell." }
    }

    func stop() {
        guard !Settings.shared.data.keepTerminalAliveInBackground else {
            Log.term.debug("keeping terminal session alive in background (user setting)")
            return
        }
        forceStop()
    }

    func forceStop() {
        pty.terminate()
        emulator.reset()
        isRunning = false
        outputObserver = nil
        generation &+= 1
    }

    /// Publishes a redraw for a change the emulator made that did not come from
    /// the pty -- scrolling the viewport, say. The coalescing path in
    /// `scheduleRedraw` exists to throttle *output*; a user-driven change should
    /// land on the next frame, not up to a frame later.
    func bumpGeneration() { generation &+= 1 }

    /// The shell's current working directory, straight from the kernel.
    ///
    /// `proc_pidinfo` rather than parsing the prompt or shipping a shell hook:
    /// the prompt is user-configurable and a hook would mean editing someone's
    /// zshrc to support a feature they may never use. This asks the kernel what
    /// the process's cwd actually is, which is both exact and free.
    ///
    /// It reports the *shell's* cwd, not a child's. Running `cd` inside `vim`'s
    /// shell-out is not reflected, which is correct -- that directory is gone by
    /// the time anyone asks.
    var workingDirectory: String? {
        guard pty.pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pty.pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard read == Int32(size) else { return nil }
        var path = info.pvi_cdir.vip_path
        let directory = withUnsafePointer(to: &path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return directory.isEmpty ? nil : directory
    }

    /// Everything on screen and in scrollback, as plain text.
    func transcript(lastLines: Int? = nil) -> String {
        emulator.plainText(lastLines: lastLines)
    }

    func send(_ text: String) { pty.write(text) }
    func send(_ data: Data) { pty.write(data) }

    func resize(columns: Int, rows: Int) {
        emulator.resize(columns: columns, rows: rows)
        pty.resize(columns: UInt16(columns), rows: UInt16(rows))
        scheduleRedraw()
    }

    private func scheduleRedraw() {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
            guard let self else { return }
            self.redrawScheduled = false
            self.generation &+= 1
        }
    }

    /// Translates an NSEvent into the bytes a terminal expects. This mapping is
    /// the difference between a working shell and a box that echoes garbage.
    func handle(event: NSEvent) -> Bool {
        guard isRunning else { return false }
        let modifiers = event.modifierFlags

        // Control sequences: ctrl-C, ctrl-D, ctrl-Z and friends are the
        // characters 1-26, i.e. the letter's position in the alphabet.
        if modifiers.contains(.control), let characters = event.charactersIgnoringModifiers?.lowercased(),
           let scalar = characters.unicodeScalars.first {
            if scalar.value >= 97 && scalar.value <= 122 {
                send(Data([UInt8(scalar.value - 96)]))
                return true
            }
            switch scalar {
            case "[": send(Data([0x1B])); return true
            case "\\": send(Data([0x1C])); return true
            case "]": send(Data([0x1D])); return true
            default: break
            }
        }

        // Option-as-meta: prefix with ESC, which is what every Unix shell expects
        // for alt-b / alt-f word motion.
        if modifiers.contains(.option), let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            send(Data([0x1B]) + Data(characters.utf8))
            return true
        }

        switch event.keyCode {
        case 36:  send("\r"); return true                  // Return
        case 51:  send(Data([0x7F])); return true          // Delete -> DEL
        case 117: send("\u{1B}[3~"); return true           // Forward delete
        case 48:  send("\t"); return true
        case 53:  send(Data([0x1B])); return true          // Escape
        // Arrows. Application-cursor mode would use ESC O A; normal mode ESC [ A.
        // We always send normal mode, which shells accept in both.
        case 126: send("\u{1B}[A"); return true
        case 125: send("\u{1B}[B"); return true
        case 124: send("\u{1B}[C"); return true
        case 123: send("\u{1B}[D"); return true
        case 115: send("\u{1B}[H"); return true            // Home
        case 119: send("\u{1B}[F"); return true            // End
        case 116: send("\u{1B}[5~"); return true           // Page up
        case 121: send("\u{1B}[6~"); return true           // Page down
        default: break
        }

        if let characters = event.characters, !characters.isEmpty {
            send(characters)
            return true
        }
        return false
    }
}

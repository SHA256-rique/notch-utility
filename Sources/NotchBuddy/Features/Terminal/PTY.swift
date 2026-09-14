import Foundation
import Darwin

/// A pseudo-terminal running a real login shell.
///
/// ## Why a pty at all, instead of `Process` with pipes
/// A pipe is not a terminal. With pipes you get:
///   * No job control, so ctrl-C kills nothing.
///   * `isatty()` false, so every well-behaved CLI disables colour, disables
///     progress bars, and switches to non-interactive mode. `git log` will not
///     page. `claude` will not prompt.
///   * No window size, so anything that draws a UI renders at 80x24 or refuses.
///
/// Since one of this app's headline features is intercepting an interactive
/// approval prompt from a CLI agent, a pipe-backed "run one command" box would
/// have made the feature impossible. The pty is what makes the owned-pty
/// approval path in §8 of the brief available at all.
///
/// ## Why posix_spawn and not fork()
/// `fork()` in a process with an active Swift/ObjC runtime, GCD queues and
/// CoreFoundation is genuinely unsafe -- only async-signal-safe calls are legal
/// between fork and exec, and the Swift runtime is not. `posix_spawn` performs
/// the fork+exec atomically inside libsystem, which is the supported way.
///
/// The two flags that make it a *controlling* terminal:
///   * `POSIX_SPAWN_SETSID` makes the child a session leader.
///   * The file actions then `open()` the slave tty path in the child. On BSD
///     (and therefore macOS), the first terminal a session leader opens becomes
///     its controlling terminal -- which is what gives us working job control
///     without needing a TIOCSCTTY ioctl we cannot issue from the parent.
final class PTY {
    private(set) var masterFD: Int32 = -1
    private(set) var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var terminationSource: DispatchSourceProcess?

    /// Delivered on the main queue.
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning = false

    // MARK: - Spawn

    @discardableResult
    func start(shell: String? = nil, columns: UInt16 = 100, rows: UInt16 = 28,
               workingDirectory: String? = nil,
               extraEnvironment: [String: String] = [:]) -> Bool {
        guard !isRunning else { return true }

        // 1. Open the master side and unlock the pair.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slaveNamePointer = ptsname(master) else {
            if master >= 0 { close(master) }
            Log.term.error("failed to allocate pty")
            return false
        }
        let slavePath = String(cString: slaveNamePointer)

        // 2. Size it before the shell starts, so the first prompt is drawn at
        //    the right width rather than reflowing on the first resize.
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        // Advisory: a failure here means the shell starts at the default 80x24
        // and corrects on the first resize, which is not worth failing over.
        _ = ioctl(master, TIOCSWINSZ, &size)

        // 3. File actions: the child opens the slave as fd 0, then dups it to
        //    1 and 2, and closes the master it inherited.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addclose(&fileActions, master)
        posix_spawn_file_actions_addopen(&fileActions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        // 4. Resolve the shell. $SHELL is right far more often than a hardcoded
        //    path; /bin/zsh is the modern macOS default as a fallback.
        let shellPath = shell.flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"

        // `-l` for a login shell so the user's profile is sourced and their PATH
        // matches what they see in Terminal.app. A GUI app's inherited PATH is
        // famously not the user's PATH.
        let arguments = [shellPath, "-l"]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "NotchBuddy"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["COLUMNS"] = String(columns)
        environment["LINES"] = String(rows)
        for (key, value) in extraEnvironment { environment[key] = value }

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { if let p = $0 { free(p) } }
            envp.forEach { if let p = $0 { free(p) } }
        }

        var childPID: pid_t = 0
        let previousDirectory = FileManager.default.currentDirectoryPath
        if let workingDirectory { FileManager.default.changeCurrentDirectoryPath(workingDirectory) }
        let status = posix_spawn(&childPID, shellPath, &fileActions, &attributes, argv, envp)
        if workingDirectory != nil { FileManager.default.changeCurrentDirectoryPath(previousDirectory) }

        guard status == 0 else {
            close(master)
            Log.term.error("posix_spawn failed: \(String(cString: strerror(status)), privacy: .public)")
            return false
        }

        masterFD = master
        pid = childPID
        isRunning = true
        installReadSource()
        installTerminationWatcher()
        Log.term.info("pty started pid=\(childPID) shell=\(shellPath, privacy: .public)")
        return true
    }

    // MARK: - IO

    private func installReadSource() {
        // Non-blocking so the dispatch source, not a blocked read(), controls
        // when we touch the fd.
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD,
                                                   queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer[0..<n])
                DispatchQueue.main.async { self.onOutput?(data) }
            } else if n == 0 {
                // EOF: the shell closed its end.
                DispatchQueue.main.async { self.handleExit(status: 0) }
            }
            // n < 0 with EAGAIN is normal for a non-blocking fd; the source will
            // fire again when there is more.
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            close(self.masterFD)
            self.masterFD = -1
        }
        source.resume()
        readSource = source
    }

    private func installTerminationWatcher() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)   // reap, so we do not leave a zombie
            self.handleExit(status: status)
        }
        source.resume()
        terminationSource = source
    }

    func write(_ data: Data) {
        guard isRunning, masterFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(masterFD, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n }
                else if errno == EAGAIN { usleep(500); continue }
                else { break }
            }
        }
    }

    func write(_ string: String) { write(Data(string.utf8)) }

    func resize(columns: UInt16, rows: UInt16) {
        guard masterFD >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
        // SIGWINCH tells the foreground program (vim, less, htop) to redraw at
        // the new size. Without it the kernel knows the new size but the program
        // does not.
        if pid > 0 { kill(-pid, SIGWINCH) }
    }

    // MARK: - Teardown

    /// Terminates the whole process *group*, not just the shell.
    ///
    /// Signalling only the shell's pid leaves its children -- the thing you were
    /// actually running -- orphaned and still holding the pty. `kill(-pid)`
    /// targets the group, which exists because we spawned with SETSID.
    func terminate() {
        guard isRunning else { return }
        isRunning = false
        if pid > 0 {
            kill(-pid, SIGHUP)
            // Give it a moment to unwind, then insist. SIGKILL immediately would
            // skip shell cleanup (history flush, atexit traps).
            let doomed = pid
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                kill(-doomed, SIGKILL)
                var status: Int32 = 0
                waitpid(doomed, &status, WNOHANG)
            }
        }
        terminationSource?.cancel(); terminationSource = nil
        readSource?.cancel(); readSource = nil   // the cancel handler closes masterFD
        pid = -1
        Log.term.info("pty terminated")
    }

    private func handleExit(status: Int32) {
        guard isRunning else { return }
        isRunning = false
        readSource?.cancel(); readSource = nil
        terminationSource?.cancel(); terminationSource = nil
        onExit?(status)
    }

    deinit {
        if isRunning { terminate() }
    }
}

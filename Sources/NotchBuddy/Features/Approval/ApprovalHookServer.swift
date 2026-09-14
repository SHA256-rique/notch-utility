import Foundation
import Darwin

/// **Detection path 1 (primary): the CLI's own hook mechanism.**
///
/// This is the path the brief asks for first, and it is first because it is the
/// only one that is not guessing. Claude Code's `PreToolUse` hook runs a command
/// before a tool executes, hands it a JSON description of what is about to
/// happen on stdin, and *blocks* until that command exits. Whatever the command
/// prints is read back as a permission decision.
///
/// So the flow is:
///
///     claude ──PreToolUse──> nb-approve (tiny shell script)
///                                 │ writes JSON request to the socket
///                                 ▼
///                       ~/.notchbuddy/approval.sock  ◀── this server
///                                 │                        │
///                                 │                   badge appears in the notch
///                                 │                        │
///                                 │                   user clicks Approve
///                                 ▼                        │
///                            reads one line  ◀─────────────┘
///                                 │
///                      prints hookSpecificOutput JSON, exits
///                                 │
///                                 ▼
///                          claude proceeds / stops
///
/// ## Why a unix domain socket rather than a TCP port
/// A loopback TCP port is reachable by **every** process and every user on the
/// machine, and by anything that can make the browser issue a request. A unix
/// socket is a filesystem object: it is protected by file permissions (created
/// here at 0600, in a 0700 directory), and nothing that cannot read that path
/// can send us an approval decision. Given that the thing on the other end is
/// "should this agent be allowed to run this shell command", that difference
/// matters a great deal.
///
/// ## Why the hook script blocks instead of polling
/// The hook process sits in a blocking `read` on the socket. No timer, no
/// polling, no busy loop -- it is descheduled entirely until we write a reply.
final class ApprovalHookServer {
    static let shared = ApprovalHookServer()

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.notchbuddy.approval.server")
    private(set) var isRunning = false

    var socketURL: URL { AppPaths.hookDirectory.appendingPathComponent("approval.sock") }
    var scriptURL: URL { AppPaths.hookDirectory.appendingPathComponent("nb-approve") }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard Settings.shared.data.approvalHookEnabled else { return }

        installHookScript()
        tightenDirectoryPermissions()

        let path = socketURL.path
        // A stale socket file from a crash would make bind() fail with EADDRINUSE.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.approval.error("approval socket() failed")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Log.approval.error("approval socket path too long")
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            Log.approval.error("approval bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }

        // Owner-only. Anything looser and any local process could answer
        // permission prompts on the user's behalf.
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            Log.approval.error("approval listen() failed")
            close(fd)
            unlink(path)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { [weak self] in
            guard let self, self.listenFD >= 0 else { return }
            close(self.listenFD)
            self.listenFD = -1
            unlink(path)
        }
        source.resume()
        acceptSource = source
        isRunning = true
        Log.approval.info("approval hook server listening at \(path, privacy: .public)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        isRunning = false
    }

    private func tightenDirectoryPermissions() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: AppPaths.hookDirectory.path)
    }

    // MARK: - Connection handling

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Each connection is one request/response and is handled on its own
        // work item. A hung client cannot block the accept loop.
        queue.async { [weak self] in self?.handle(clientFD: clientFD) }
    }

    private func handle(clientFD: Int32) {
        // A generous read timeout: the client is a short-lived script, so if it
        // has not sent its request within a few seconds it is broken.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        // The client sends one JSON object terminated by a newline, then waits.
        while true {
            let n = read(clientFD, &buffer, buffer.count)
            guard n > 0 else { break }
            request.append(contentsOf: buffer[0..<n])
            if request.last == 0x0A { break }
            if request.count > 512 * 1024 { break }   // runaway guard
        }

        guard !request.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
            respond(clientFD, decision: .allow, reason: "NotchBuddy could not parse the request")
            return
        }

        let approvalID = UUID()
        let source = (json["source"] as? String) ?? "Claude Code"
        let toolName = (json["tool_name"] as? String) ?? ""
        let toolInput = json["tool_input"]
        let detail = Self.summarise(toolName: toolName, input: toolInput)
        let prompt = (json["prompt"] as? String)
            ?? (toolName.isEmpty ? "A command is waiting for your approval."
                                 : "Allow \(source) to run \(toolName)?")

        // Hand the decision back over the same connection, then close it.
        // `DispatchSemaphore` is not needed: the client is blocked in read(),
        // so we can simply reply whenever the user gets around to answering.
        let approval = PendingApproval(
            id: approvalID,
            transport: .hook,
            source: source,
            toolName: toolName,
            prompt: prompt,
            detail: detail,
            createdAt: Date(),
            respond: { [weak self] decision in
                self?.queue.async {
                    self?.respond(clientFD, decision: decision, reason: "Answered in NotchBuddy")
                }
            })

        // If the client disappears (the user ctrl-C'd the agent), drop the badge
        // instead of leaving a question nobody is waiting on.
        watchForClientDisconnect(clientFD, approvalID: approvalID)

        Task { @MainActor in ApprovalCenter.shared.submit(approval) }
    }

    private func watchForClientDisconnect(_ clientFD: Int32, approvalID: UUID) {
        // A dup'd fd so the write path and the watcher do not fight over it.
        let watchFD = dup(clientFD)
        guard watchFD >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: watchFD, queue: queue)
        source.setEventHandler {
            var probe = [UInt8](repeating: 0, count: 1)
            let n = recv(watchFD, &probe, 1, MSG_PEEK)
            if n == 0 {          // EOF: the hook process exited
                source.cancel()
                Task { @MainActor in ApprovalCenter.shared.withdraw(id: approvalID) }
            }
        }
        source.setCancelHandler { close(watchFD) }
        source.resume()
    }

    /// Emits exactly the JSON shape Claude Code's PreToolUse hook expects.
    private func respond(_ clientFD: Int32, decision: ApprovalDecision, reason: String) {
        let permissionDecision: String
        switch decision {
        case .allow, .alwaysAllow: permissionDecision = "allow"
        case .deny: permissionDecision = "deny"
        }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": permissionDecision,
                "permissionDecisionReason": reason
            ]
        ]
        var data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(clientFD, base.advanced(by: written), raw.count - written)
                guard n > 0 else { break }
                written += n
            }
        }
        // Half-close so the client's read returns instead of waiting for more.
        shutdown(clientFD, SHUT_WR)
        close(clientFD)
    }

    /// Turns a tool's input payload into one readable line.
    private static func summarise(toolName: String, input: Any?) -> String? {
        guard let dictionary = input as? [String: Any] else { return nil }
        // The fields worth showing differ per tool; these cover the ones whose
        // approval actually carries risk.
        for key in ["command", "file_path", "path", "url", "pattern", "query"] {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value.count > 400 ? String(value.prefix(400)) + "…" : value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }

    // MARK: - Hook script

    /// Writes the small script the user points their CLI's hook config at.
    ///
    /// It is generated rather than shipped as a bundle resource so that the
    /// socket path inside it is always correct for this user, and so the user
    /// can read the entire thing -- it is 20 lines of shell -- before wiring it
    /// into a tool that runs commands on their machine. Nothing about this
    /// should require trust in an opaque binary.
    func installHookScript() {
        let script = """
        #!/bin/sh
        # NotchBuddy approval bridge -- generated, safe to read and edit.
        #
        # Wire this into Claude Code by adding a PreToolUse hook that runs it.
        # It forwards the hook payload to the NotchBuddy app over a unix socket
        # and blocks until you answer in the notch. If NotchBuddy is not running
        # it allows the action through unchanged, so your agent never hangs
        # because a UI app was closed.

        SOCKET="\(socketURL.path)"

        # No socket -> NotchBuddy is not running. Stay out of the way.
        [ -S "$SOCKET" ] || exit 0

        # nc -U speaks unix sockets. It is part of the base macOS install.
        command -v nc >/dev/null 2>&1 || exit 0

        PAYLOAD=$(cat)
        RESPONSE=$(printf '%s\\n' "$PAYLOAD" | nc -U "$SOCKET" 2>/dev/null)

        # Empty response (socket vanished mid-flight) -> defer to normal prompting.
        [ -n "$RESPONSE" ] || exit 0

        printf '%s\\n' "$RESPONSE"
        exit 0
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            Log.approval.error("could not write hook script: \(String(describing: error), privacy: .public)")
        }
    }

    /// The exact JSON the user needs in `~/.claude/settings.json`. Shown in the
    /// Settings tab with a copy button rather than written for them -- editing
    /// another tool's config file behind the user's back would be rude, and
    /// would break the moment they hand-edit it themselves.
    var settingsSnippet: String {
        """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash|Write|Edit|MultiEdit",
                "hooks": [
                  { "type": "command", "command": "\(scriptURL.path)" }
                ]
              }
            ]
          }
        }
        """
    }
}

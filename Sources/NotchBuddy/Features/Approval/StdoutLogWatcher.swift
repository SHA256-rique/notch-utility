import Foundation

/// **Detection path 2 (fallback): tail a log file another process is writing.**
///
/// This is the least reliable of the three and is **off by default**. It exists
/// for the case where the user runs their agent in some other terminal and that
/// terminal (or a wrapper like `script`, `tee`, or a tmux pipe-pane) is writing
/// output to a file we can watch.
///
/// ## Why a file rather than reading another process's stdout directly
/// You cannot read another process's file descriptors on macOS. There is no
/// supported API for it; the approaches that appear to work (attaching with
/// ptrace, DTrace) require disabling SIP or root, and would be wildly
/// disproportionate for this. Asking the user to pipe their session to a file --
/// `claude 2>&1 | tee ~/agent.log` -- is honest about what is actually possible.
///
/// ## Why FSEvents rather than polling the file
/// A 500ms `stat` loop on a log file is exactly the kind of background cost this
/// app exists to avoid. `DispatchSourceFileSystemObject` with `.extend` gives a
/// kernel notification when the file grows, and costs nothing between writes.
///
/// We only ever read the **newly appended** bytes -- the offset is tracked -- so
/// a multi-megabyte session log is never re-read.
@MainActor
final class StdoutLogWatcher {
    static let shared = StdoutLogWatcher()

    private var fileDescriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: off_t = 0
    private var accumulated = ""
    private var activeApprovalID: UUID?
    private var settleWork: DispatchWorkItem?
    private(set) var watchedPath: String?
    /// Where a decision is written, for tools that read a response file.
    private var responsePath: String?

    private init() {}

    func start(path: String, responseFile: String? = nil) {
        stop()
        guard Settings.shared.data.approvalStdoutFallbackEnabled else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Log.approval.error("cannot watch \(path, privacy: .public)")
            return
        }
        fileDescriptor = fd
        watchedPath = path
        responsePath = responseFile

        // Start at the end: existing content is history, not a live prompt.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        offset = off_t((attributes?[.size] as? NSNumber)?.int64Value ?? 0)

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Log rotation. Re-open from the top of the new file.
                let path = self.watchedPath
                let response = self.responsePath
                self.stop()
                if let path { self.start(path: path, responseFile: response) }
                return
            }
            self.readNewBytes()
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.fileDescriptor >= 0 else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        source.resume()
        self.source = source
        Log.approval.info("stdout fallback watching \(path, privacy: .public)")
    }

    func stop() {
        settleWork?.cancel(); settleWork = nil
        source?.cancel(); source = nil
        watchedPath = nil
        responsePath = nil
        accumulated = ""
        if let id = activeApprovalID {
            ApprovalCenter.shared.withdraw(id: id)
            activeApprovalID = nil
        }
    }

    private func readNewBytes() {
        guard let path = watchedPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            offset += off_t(data.count)
            guard let text = String(data: data, encoding: .utf8) else { return }
            accumulated += OwnedPTYDetector.stripANSI(text)
            if accumulated.count > 8000 { accumulated = String(accumulated.suffix(4000)) }

            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.evaluate() }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } catch {
            Log.approval.error("log read failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func evaluate() {
        guard activeApprovalID == nil,
              let hit = ApprovalPatterns.match(in: accumulated) else { return }

        let id = UUID()
        activeApprovalID = id
        let responsePath = self.responsePath

        let approval = PendingApproval(
            id: id,
            transport: .stdoutPattern,
            source: hit.pattern.source,
            toolName: "",
            prompt: "A command may be waiting for approval.",
            detail: hit.detail ?? String(accumulated.suffix(220)),
            createdAt: Date(),
            respond: { [weak self] decision in
                Task { @MainActor in
                    // The only channel available here is a response file the
                    // other side has agreed to read. There is no way to inject
                    // into a pty we do not own -- which is precisely why this
                    // transport is the last resort.
                    if let responsePath {
                        let answer = decision == .deny ? "deny" : "allow"
                        try? answer.write(toFile: responsePath, atomically: true, encoding: .utf8)
                    }
                    self?.activeApprovalID = nil
                    self?.accumulated = ""
                }
            })

        ApprovalCenter.shared.submit(approval)
    }
}

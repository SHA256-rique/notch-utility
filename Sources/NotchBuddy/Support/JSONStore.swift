import Foundation

/// Tiny debounced JSON-file store used for snippets, notes, timers, settings.
///
/// Why a plain JSON file rather than SQLite or Core Data:
///   * The largest collection in this app is clipboard history, capped at a few
///     hundred entries. That is kilobytes. A database engine's connection, page
///     cache and background threads cost more RAM than the data does.
///   * Core Data would pull a persistent container and a managed object context
///     into memory for the whole process lifetime -- for data that is only read
///     when a tab is open.
/// See docs/decisions/0009-json-files-over-coredata.md
///
/// Writes are debounced and moved off the main thread, and use an atomic
/// replace so a crash mid-write cannot leave a truncated file behind.
final class JSONStore<T: Codable> {
    private let url: URL
    private let queue: DispatchQueue
    private var pendingWork: DispatchWorkItem?
    private let debounce: TimeInterval

    init(filename: String, debounce: TimeInterval = 0.75) {
        self.url = AppPaths.dataDirectory.appendingPathComponent(filename)
        self.queue = DispatchQueue(label: "com.notchbuddy.store.\(filename)", qos: .utility)
        self.debounce = debounce
    }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            Log.store.error("decode failed for \(self.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Coalesces bursts of mutations (typing in the notes tab, a run of clipboard
    /// captures) into one disk write.
    func save(_ value: T) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [url] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            do {
                let data = try encoder.encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                Log.store.error("encode/write failed: \(String(describing: error), privacy: .public)")
            }
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Used on terminate, where we cannot wait out the debounce window.
    func saveNow(_ value: T) {
        pendingWork?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum AppPaths {
    /// ~/Library/Application Support/NotchBuddy
    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NotchBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/.notchbuddy -- the *only* thing that lives here is the approval hook
    /// socket and the generated hook script. It is outside Application Support
    /// on purpose: the hook script's path ends up inside the user's
    /// ~/.claude/settings.json, and a path with spaces in it ("Application
    /// Support") is a reliable source of quoting bugs in other people's tooling.
    static let hookDirectory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".notchbuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

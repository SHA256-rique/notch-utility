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
        self.queue = DispatchQueue(label: "com.notchscotch.store.\(filename)", qos: .utility)
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
    /// The name this app used to have. Everything it wrote is still on disk
    /// under it, and the user has no idea a rename happened.
    private static let previousName = "NotchBuddy"
    private static let currentName = "NotchScotch"

    /// ~/Library/Application Support/NotchScotch
    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(currentName, isDirectory: true)
        migrateIfNeeded(from: base.appendingPathComponent(previousName, isDirectory: true), to: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Brings the old app's data across after the rename.
    ///
    /// A rename that silently loses someone's clipboard history, snippets,
    /// timers, notes and screen-time record is not a rename, it is a data-loss
    /// bug with a new icon.
    ///
    /// **Per file, not the whole directory.** The first version moved the
    /// directory only when the destination did not exist, which looked right
    /// and was wrong: anything that touches `dataDirectory` before the
    /// migration matters -- a test run, a crash on a previous launch, a
    /// half-started process -- creates an empty new directory, and from then on
    /// the real data is stranded where nothing will ever look for it again.
    /// Moving file by file survives that.
    ///
    /// **A file is only adopted when the new directory does not have one.**
    /// Never overwrite: if both exist the newer app has already written
    /// something, and clobbering it to restore an older state is the same bug
    /// pointed the other way.
    ///
    /// **Move, not copy.** Leaving both would be two sources of truth, and the
    /// next version would have to guess which is current. What is left behind
    /// is only what was already superseded.
    private static func migrateIfNeeded(from old: URL, to new: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: old.path) else { return }
        try? manager.createDirectory(at: new, withIntermediateDirectories: true)

        guard let contents = try? manager.contentsOfDirectory(
            at: old, includingPropertiesForKeys: nil) else { return }

        var moved = 0
        for file in contents {
            let destination = new.appendingPathComponent(file.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.moveItem(at: file, to: destination)
                moved += 1
            } catch {
                // A failed move must not take the app down with it. The file
                // stays where it is and can be recovered by hand.
                Log.store.error("could not migrate \(file.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if moved > 0 {
            Log.store.info("migrated \(moved) file(s) from \(previousName, privacy: .public)")
        }
        // Only removes the old directory once nothing is left in it, so a
        // partial migration never destroys the fallback.
        if let remaining = try? manager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil),
           remaining.isEmpty {
            try? manager.removeItem(at: old)
        }
    }

    /// ~/.notchscotch -- the *only* thing that lives here is the approval hook
    /// socket and the generated hook script. It is outside Application Support
    /// on purpose: the hook script's path ends up inside the user's
    /// ~/.claude/settings.json, and a path with spaces in it ("Application
    /// Support") is a reliable source of quoting bugs in other people's tooling.
    static let hookDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".notchscotch", isDirectory: true)
        // The old hook directory is *not* moved. Its path is written into the
        // user's ~/.claude/settings.json, and moving the script out from under
        // a path another tool holds would break approvals silently. The hook
        // installer rewrites that setting; until it is re-run, the old script
        // keeps working from where it is.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where the hook lived before the rename, so the installer can clean up.
    static var previousHookDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchbuddy", isDirectory: true)
    }
}

import Foundation
import AppKit
import Combine

/// State behind the Disk Map tab: where we are, what is in it, and what the
/// user has selected.
///
/// The scanning itself lives in `DiskScanner` (an actor, off the main thread);
/// this is the part that has to be on the main actor because SwiftUI reads it.
@MainActor
final class DiskMapModel: ObservableObject {

    @Published private(set) var directory: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var entries: [DiskEntry] = []
    @Published private(set) var isScanning = false
    @Published var selected: DiskEntry?
    @Published var confirmingTrash: DiskEntry?
    @Published private(set) var lastError: String?

    @Published private(set) var categories: [CleanupCategory] = []
    @Published private(set) var categorySizes: [String: UInt64] = [:]
    @Published private(set) var lastScanned: Date?
    /// True when macOS refused to list the folder we are looking at.
    @Published private(set) var directoryUnreadable = false
    /// Biggest individual files under the current folder, found on demand.
    @Published private(set) var largestFiles: [DiskEntry] = []
    @Published private(set) var isFindingLargest = false

    private var largestTask: Task<Void, Never>?

    /// Places worth one click. Everything here is somewhere people actually
    /// lose space, and three of them are TCC-protected -- which is exactly why
    /// they need to be reachable without typing a path.
    struct Shortcut: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let symbol: String
        let url: URL
    }

    static func shortcuts() -> [Shortcut] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, String, URL)] = [
            ("Home", "house", home),
            ("Documents", "doc.text", home.appendingPathComponent("Documents")),
            ("Desktop", "menubar.dock.rectangle", home.appendingPathComponent("Desktop")),
            ("Downloads", "arrow.down.circle", home.appendingPathComponent("Downloads")),
            ("Pictures", "photo", home.appendingPathComponent("Pictures")),
            ("Movies", "film", home.appendingPathComponent("Movies")),
            ("Music", "music.note", home.appendingPathComponent("Music")),
            ("Library", "building.columns", home.appendingPathComponent("Library")),
            ("Applications", "square.grid.2x2", URL(fileURLWithPath: "/Applications"))
        ]
        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.2.path) }
            .map { Shortcut(name: $0.0, symbol: $0.1, url: $0.2) }
    }

    /// Results are cached per directory for the life of the app.
    ///
    /// Without this the tab re-walked the filesystem every time it was opened,
    /// and every time you navigated back up one level -- which is the single
    /// most expensive thing in the app, on the busiest device in the machine.
    /// Opening a tab should never cost a disk scan when a recent answer exists.
    ///
    /// The cache is checked against the directory's own modification date, so a
    /// folder that has actually changed is rescanned and one that has not is
    /// not. Time alone would either go stale or thrash.
    private struct CachedScan {
        let entries: [DiskEntry]
        let directoryModified: Date?
        let scannedAt: Date
    }
    private static var scanCache: [String: CachedScan] = [:]
    private static var categoryCache: [String: (bytes: UInt64, measuredAt: Date)] = [:]

    /// How long a cached answer is offered without rechecking. Disk usage moves
    /// slowly; a five-minute-old number is not wrong in any way that matters,
    /// and the Rescan button is right there.
    private static let scanTTL: TimeInterval = 300
    /// Categories get longer, because measuring them is the expensive one --
    /// eight recursive walks of ~/Library, which is hundreds of thousands of
    /// files.
    private static let categoryTTL: TimeInterval = 1800

    let storage = StorageService()

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var categoryTask: Task<Void, Never>?

    /// Total of everything scanned in the current folder.
    var scannedBytes: UInt64 { entries.reduce(0) { $0 + $1.bytes } }

    var categoryTotal: UInt64 { categorySizes.values.reduce(0, +) }

    var canGoUp: Bool {
        directory.path != "/" && directory.pathComponents.count > 1
    }

    /// The path from the volume root to here, so any ancestor is one click away.
    var breadcrumbs: [URL] {
        var crumbs: [URL] = []
        var cursor = directory
        while cursor.path != "/" {
            crumbs.insert(cursor, at: 0)
            let parent = cursor.deletingLastPathComponent()
            if parent == cursor { break }
            cursor = parent
        }
        // Only the last few: the strip is about 300pt and a deep path would push
        // the folder you are actually in off the end of it.
        return Array(crumbs.suffix(4))
    }

    nonisolated static func crumbName(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if url == home { return "~" }
        return url.lastPathComponent
    }

    // MARK: - Lifecycle

    func activate() {
        storage.activate()
        categories = CleanupCategory.all()
        // Serve whatever is cached first, so opening the tab is instant, then
        // refresh only what has actually gone stale.
        applyCachedCategories()
        measureCategories()
        loadDirectory(directory, allowCache: true)
    }

    func deactivate() {
        storage.deactivate()
        scanTask?.cancel()
        scanTask = nil
        categoryTask?.cancel()
        categoryTask = nil
        // Entries are dropped on close. A folder listing of a few hundred rows
        // is small, but keeping it alive for a tab nobody has open is the habit
        // that turns into a leak somewhere that is not small.
        entries = []
        selected = nil
        confirmingTrash = nil
    }

    // MARK: - Navigation

    func open(_ url: URL) {
        guard url != directory else { return }
        directory = url
        selected = nil
        confirmingTrash = nil
        lastError = nil
        loadDirectory(url, allowCache: true)
    }

    func drill(_ entry: DiskEntry) {
        guard entry.isDrillable else {
            // A file or a bundle has nothing to drill into, so the useful
            // double-click action is the one Finder would do.
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            return
        }
        open(entry.url)
    }

    func goUp() {
        guard canGoUp else { return }
        open(directory.deletingLastPathComponent())
    }

    func select(_ entry: DiskEntry) {
        selected = selected?.id == entry.id ? nil : entry
        confirmingTrash = nil
    }

    // MARK: - Scanning

    /// Explicit user action: always re-walks, ignoring the cache.
    func rescan() {
        loadDirectory(directory, allowCache: false)
    }

    private func loadDirectory(_ target: URL, allowCache: Bool) {
        scanTask?.cancel()

        if allowCache, let cached = Self.scanCache[target.path], Self.isFresh(cached, for: target) {
            entries = cached.entries
            lastScanned = cached.scannedAt
            isScanning = false
            return
        }

        entries = []
        largestFiles = []
        isScanning = true
        directoryUnreadable = false

        scanTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let found = await scanner.scan(directory: target) { partial in
                Task { @MainActor [weak self] in
                    // Guard against a slow scan of a folder the user has
                    // already navigated away from writing over the new one.
                    guard let self, self.directory == target else { return }
                    self.entries = partial
                }
            }
            let readable = await scanner.isReadable(target)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.directoryUnreadable = !readable && found.isEmpty
                let modified = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                Self.scanCache[target.path] = CachedScan(entries: found,
                                                         directoryModified: modified,
                                                         scannedAt: Date())
                guard self.directory == target else { return }
                self.entries = found
                self.lastScanned = Date()
                self.isScanning = false
            }
        }
    }

    /// A cached scan is good while it is young *and* the directory has not been
    /// touched since. Either test alone is wrong: time alone serves stale
    /// results after a large download, and mtime alone never expires for a
    /// folder whose own timestamp does not change when its children grow.
    private static func isFresh(_ cached: CachedScan, for url: URL) -> Bool {
        guard Date().timeIntervalSince(cached.scannedAt) < scanTTL else { return false }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return modified == cached.directoryModified
    }

    /// Human note for the breadcrumb bar, so "is this number current" is never
    /// a guess.
    var freshnessNote: String {
        guard let lastScanned else { return "" }
        let age = Int(Date().timeIntervalSince(lastScanned))
        if age < 5 { return "just now" }
        if age < 60 { return "\(age)s ago" }
        return "\(age / 60)m ago"
    }

    /// Sizes the quick-win categories in the background.
    ///
    /// Sequential rather than concurrent: these are all on the same disk, and
    /// eight parallel walks of ~/Library contend for the same device while
    /// making every one of them slower.
    private func applyCachedCategories() {
        for (id, cached) in Self.categoryCache {
            categorySizes[id] = cached.bytes
        }
    }

    /// Sizes the quick-win categories in the background, skipping any measured
    /// recently enough.
    ///
    /// Sequential rather than concurrent, and at `background` priority: these
    /// are eight recursive walks of ~/Library on the same physical device.
    /// Running them in parallel makes every one of them slower while the user
    /// is waiting on the folder scan they actually asked for.
    private func measureCategories() {
        categoryTask?.cancel()
        let stale = categories.filter { category in
            guard let cached = Self.categoryCache[category.id] else { return true }
            return Date().timeIntervalSince(cached.measuredAt) >= Self.categoryTTL
        }
        guard !stale.isEmpty else { return }

        categoryTask = Task.detached(priority: .background) { [weak self] in
            for category in stale {
                if Task.isCancelled { return }
                let total = DiskScanner.total(of: category.url)
                if Task.isCancelled { return }
                guard let model = self else { return }
                await MainActor.run {
                    Self.categoryCache[category.id] = (total.bytes, Date())
                    model.categorySizes[category.id] = total.bytes
                }
            }
        }
    }

    // MARK: - Largest files

    /// The single most useful question a disk tool answers: not "which folder is
    /// big" -- you usually know -- but "which *file* is big", which is almost
    /// never where you would look.
    ///
    /// Deliberately on demand rather than automatic. It is a full recursive walk
    /// with no early exit, which is the expensive thing this tab otherwise goes
    /// out of its way to avoid doing on open.
    func findLargestFiles(limit: Int = 30) {
        largestTask?.cancel()
        isFindingLargest = true
        let target = directory

        largestTask = Task.detached(priority: .utility) { [weak self] in
            let found = DiskScanner.largestFiles(under: target, limit: limit)
            guard !Task.isCancelled, let model = self else { return }
            await MainActor.run {
                guard model.directory == target else { return }
                model.largestFiles = found
                model.isFindingLargest = false
            }
        }
    }

    func clearLargestFiles() {
        largestTask?.cancel()
        largestTask = nil
        largestFiles = []
        isFindingLargest = false
    }

    /// Opens System Settings at the pane that grants folder access.
    ///
    /// Renaming the app changed its bundle identifier, and TCC keys grants to
    /// the identifier -- so every folder permission the previous name had was
    /// dropped on the floor. There is no API to re-request them silently;
    /// pointing at the right settings pane is the whole of what an app can do.
    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Folders in the current listing that macOS would not let us read.
    var unreadableEntries: [DiskEntry] { entries.filter(\.isUnreadable) }

    // MARK: - Treemap input

    /// What the treemap draws: the biggest tiles, plus one "everything else".
    ///
    /// Drawing all of them produced 400 rectangles smaller than their own
    /// labels, which is a texture rather than a chart. Truncating silently was
    /// worse -- the tiles no longer summed to the folder, so the picture
    /// quietly lied about proportions. Rolling the tail into a single tile keeps
    /// the areas honest *and* every tile legible.
    var treemapEntries: [DiskEntry] {
        let limit = 28
        guard entries.count > limit else { return entries }
        let shown = Array(entries.prefix(limit))
        let rest = entries.dropFirst(limit)
        let restBytes = rest.reduce(0) { $0 + $1.bytes }
        guard restBytes > 0 else { return shown }
        return shown + [DiskEntry(url: directory.appendingPathComponent(".nb-everything-else"),
                                  name: "Everything else",
                                  isDirectory: false,
                                  bytes: restBytes,
                                  items: rest.reduce(0) { $0 + $1.items },
                                  isBundle: false)]
    }

    var aggregatedCount: Int { max(0, entries.count - 28) }

    // MARK: - Composition

    /// Rough split of the current folder by file kind, for the sidebar bar.
    /// Directories are attributed to the kind of their own name, which is
    /// meaningless -- so they are counted as `other` rather than pretending.
    var kindBreakdown: [(kind: FileKind, bytes: UInt64)] {
        var totals: [FileKind: UInt64] = [:]
        for entry in entries {
            let kind = entry.isDirectory ? FileKind.other : FileKind.of(entry.url)
            totals[kind, default: 0] += entry.bytes
        }
        return totals
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (kind: $0.key, bytes: $0.value) }
    }

    // MARK: - Actions

    func copyPath(_ entry: DiskEntry) {
        ClipboardWatcher.shared.suppressNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url.path, forType: .string)
        NotchArbiter.shared.flash("Copied path", symbol: "doc.on.doc.fill",
                                  module: .files, detail: entry.name)
    }

    /// Moves the confirmed item to the Bin.
    ///
    /// `trashItem` rather than `removeItem`: recoverable, visible in Finder, and
    /// it refuses on things it should refuse on. An app that walks someone's
    /// home directory and offers a real Delete had better be right every time;
    /// offering the Bin means it only has to be useful.
    func trashSelected() {
        guard let entry = confirmingTrash else { return }
        lastError = nil
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resulting)
            entries.removeAll { $0.id == entry.id }
            selected = nil
            confirmingTrash = nil
            NotchArbiter.shared.flash("Moved to Bin", symbol: "trash.fill",
                                      module: .files,
                                      detail: "\(StorageService.format(entry.bytes)) freed")
            // The cached answers for this folder and its categories are now
            // wrong by exactly the size of what just moved.
            Self.scanCache.removeValue(forKey: directory.path)
            Self.categoryCache.removeAll()
            storage.refresh()
            measureCategories()
        } catch {
            confirmingTrash = nil
            lastError = (error as NSError).localizedDescription
        }
    }
}

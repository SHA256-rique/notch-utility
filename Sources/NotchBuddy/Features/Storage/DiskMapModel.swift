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
        measureCategories()
        if entries.isEmpty { rescan() }
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
        rescan()
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

    func rescan() {
        scanTask?.cancel()
        entries = []
        isScanning = true
        let target = directory

        scanTask = Task { [weak self] in
            guard let self else { return }
            let found = await scanner.scan(directory: target) { partial in
                Task { @MainActor [weak self] in
                    // Guard against a slow scan of a folder the user has
                    // already navigated away from writing over the new one.
                    guard let self, self.directory == target else { return }
                    self.entries = partial
                }
            }
            await MainActor.run {
                guard self.directory == target else { return }
                self.entries = found
                self.isScanning = false
            }
        }
    }

    /// Sizes the quick-win categories in the background.
    ///
    /// Sequential rather than concurrent: these are all on the same disk, and
    /// eight parallel walks of ~/Library contend for the same device while
    /// making every one of them slower.
    private func measureCategories() {
        categoryTask?.cancel()
        let targets = categories
        categoryTask = Task.detached(priority: .utility) { [weak self] in
            for category in targets {
                if Task.isCancelled { return }
                let total = DiskScanner.total(of: category.url)
                guard let model = self else { return }
                await MainActor.run { model.categorySizes[category.id] = total.bytes }
            }
        }
    }

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
            storage.refresh()
            measureCategories()
        } catch {
            confirmingTrash = nil
            lastError = (error as NSError).localizedDescription
        }
    }
}

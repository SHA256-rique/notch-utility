import Foundation
import AppKit
import Combine
import SwiftUI

/// One row in the storage explorer: a file or folder with its recursive size.
struct DiskEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Bytes on disk, recursive for a directory.
    var bytes: UInt64
    /// Files underneath, recursive. Zero for a plain file.
    var items: Int
    /// A bundle (.app, .photoslibrary) is a directory the user thinks of as one
    /// thing, so it is sized whole and never drilled into.
    let isBundle: Bool
    /// The folder exists but macOS would not let us look inside it.
    ///
    /// Without this a TCC-protected folder reports 0 bytes and sinks to the
    /// bottom of the list, which reads as "Documents is empty" -- a confident,
    /// wrong answer. Far better to say we were not allowed to look.
    var isUnreadable: Bool = false

    var isDrillable: Bool { isDirectory && !isBundle }
}

/// Walks a directory and sizes what is in it.
///
/// ## Why one level at a time
/// The obvious design is "scan everything into a tree, then browse the tree".
/// A home directory is two million files; holding a node per file is hundreds of
/// megabytes of RAM to answer a question about the ten biggest folders, in an
/// app whose entire argument is that it does not do that.
///
/// So this sizes the *immediate children* of one directory, recursing only to
/// total each child up. Drilling in scans the next level. The cost is that each
/// step re-walks a subtree; the benefit is that memory is bounded by the number
/// of entries in one folder, and results stream in rather than arriving after a
/// ten-second freeze.
///
/// ## Why allocated size
/// `totalFileAllocatedSize` is what the file occupies on disk, including the
/// slack in its last block and any resource fork. `fileSize` is the logical
/// length, which for a folder of a thousand small files understates the real
/// cost substantially -- and "how much space will I get back" is the only
/// question anyone opens this to answer.
actor DiskScanner {

    /// Directories that are never worth walking into.
    ///
    /// `/System/Volumes/Data` is a mount of the volume being scanned and would
    /// recurse forever; `/dev` and `/proc`-alikes are not files; and the
    /// system volume is sealed and read-only, so its size is a fact the user
    /// can do nothing about.
    private static let skippedPaths: Set<String> = [
        "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM",
        "/System/Volumes/Update", "/System/Volumes/xarts", "/System/Volumes/iSCPreboot",
        "/dev", "/net", "/home", "/.vol", "/private/var/vm"
    ]

    private static let sizeKeys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey
    ]

    /// Whether the directory itself could be listed at all.
    ///
    /// Distinct from a per-entry flag: if the folder you navigated *into* is
    /// protected, there are no entries to flag.
    func isReadable(_ directory: URL) -> Bool { Self.canRead(directory) }

    /// Sizes the immediate children of `directory`, newest results first as they
    /// finish, via `onProgress`. Returns the complete set.
    ///
    /// The whole call is cooperatively cancellable: drilling into a folder while
    /// the previous scan is still running must abandon it, or a few impatient
    /// clicks leave four walks of `~/Library` competing for the disk.
    func scan(directory: URL,
              onProgress: @Sendable @escaping ([DiskEntry]) -> Void) async -> [DiskEntry] {
        let manager = FileManager.default
        let children = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(Self.sizeKeys) + [.isPackageKey, .isSymbolicLinkKey],
            options: [])) ?? []

        var results: [DiskEntry] = []
        // Publish every so often rather than per entry: a folder with 400
        // children would otherwise push 400 SwiftUI invalidations through the
        // main actor while the disk is already busy.
        var sinceLastPublish = 0

        for child in children {
            if Task.isCancelled { return results }
            guard let values = try? child.resourceValues(
                forKeys: Set(Self.sizeKeys).union([.isPackageKey, .isSymbolicLinkKey])) else { continue }
            // A symlink's target is counted where the target lives. Following it
            // would double-count, and on a loop would never finish.
            if values.isSymbolicLink == true { continue }
            if Self.skippedPaths.contains(child.path) { continue }

            let isDirectory = values.isDirectory ?? false
            let isBundle = values.isPackage ?? false

            let entry: DiskEntry
            if isDirectory && !isBundle {
                let total = Self.total(of: child)
                // A protected folder is indistinguishable from an empty one by
                // size alone, so ask directly rather than inferring.
                let unreadable = total.bytes == 0 && !Self.canRead(child)
                entry = DiskEntry(url: child, name: child.lastPathComponent,
                                  isDirectory: true, bytes: total.bytes, items: total.items,
                                  isBundle: false, isUnreadable: unreadable)
            } else if isDirectory && isBundle {
                let total = Self.total(of: child)
                entry = DiskEntry(url: child, name: child.lastPathComponent,
                                  isDirectory: true, bytes: total.bytes, items: total.items,
                                  isBundle: true)
            } else {
                let bytes = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                entry = DiskEntry(url: child, name: child.lastPathComponent,
                                  isDirectory: false, bytes: bytes, items: 1, isBundle: false)
            }

            results.append(entry)
            sinceLastPublish += 1
            if sinceLastPublish >= 8 {
                sinceLastPublish = 0
                let snapshot = results.sorted { $0.bytes > $1.bytes }
                onProgress(snapshot)
                await Task.yield()
            }
        }

        let sorted = results.sorted { $0.bytes > $1.bytes }
        onProgress(sorted)
        return sorted
    }

    /// Whether macOS will let this process list a directory.
    ///
    /// TCC gates Documents, Desktop, Downloads and several others for *every*
    /// app, sandboxed or not, and a denial surfaces as
    /// `NSFileReadNoPermissionError` rather than as an empty directory. The
    /// distinction matters: one means "nothing here", the other means "you were
    /// not allowed to look", and reporting the second as the first is how a
    /// disk tool tells someone their Documents folder is empty.
    ///
    /// This also *triggers* the permission prompt the first time, which is the
    /// point -- the user sees macOS's own dialog at the moment they asked for
    /// the folder.
    nonisolated static func canRead(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [])
            return true
        } catch let error as NSError {
            return !(error.domain == NSCocoaErrorDomain
                     && (error.code == NSFileReadNoPermissionError
                         || error.code == NSFileReadUnknownError))
        }
    }

    /// The biggest individual files under a subtree.
    ///
    /// Keeps only `limit` candidates in memory rather than sorting everything:
    /// a home directory is two million files, and the answer wanted is thirty
    /// of them. Insert-and-trim against the running minimum is O(n log k)
    /// with a bounded footprint, where collecting-then-sorting is O(n log n)
    /// with an unbounded one.
    nonisolated static func largestFiles(under url: URL, limit: Int) -> [DiskEntry] {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }) else { return [] }

        var best: [DiskEntry] = []
        var floor: UInt64 = 0

        for case let child as URL in walker {
            if Task.isCancelled { break }
            if skippedPaths.contains(child.path) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let bytes = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            guard bytes > floor || best.count < limit else { continue }

            best.append(DiskEntry(url: child, name: child.lastPathComponent,
                                  isDirectory: false, bytes: bytes, items: 1, isBundle: false))
            if best.count > limit {
                best.sort { $0.bytes > $1.bytes }
                best.removeLast(best.count - limit)
                floor = best.last?.bytes ?? 0
            }
        }
        return best.sorted { $0.bytes > $1.bytes }
    }

    /// Recursive allocated size and file count of one subtree.
    nonisolated static func total(of url: URL) -> (bytes: UInt64, items: Int) {
        let manager = FileManager.default
        var bytes: UInt64 = 0
        var items = 0

        guard let walker = manager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }) else { return (0, 0) }

        for case let child as URL in walker {
            if Task.isCancelled { break }
            if skippedPaths.contains(child.path) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? child.resourceValues(forKeys: sizeKeys) else { continue }
            guard values.isRegularFile == true || values.isDirectory == true else { continue }
            let size = UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            bytes += size
            if values.isRegularFile == true { items += 1 }
        }
        return (bytes, items)
    }
}

// MARK: - Quick wins

/// A category of space that is usually safe to reclaim.
///
/// ## Why a fixed list and not a heuristic
/// "Find me junk" is an unbounded problem and getting it wrong means deleting
/// someone's work. Every entry here is a directory whose *purpose* is to hold
/// regenerable data -- a cache, a build product, a download -- named explicitly,
/// with a note saying what comes back and how. Nothing is ever deleted without
/// the user choosing it, and everything goes to the Bin rather than being
/// unlinked, so an error is recoverable.
struct CleanupCategory: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let symbol: String
    let url: URL
    /// What happens if this is removed. Shown before anything is deleted.
    let consequence: String
    /// True when the folder itself should be kept and only its contents removed
    /// -- emptying ~/Library/Caches is fine, deleting it is not.
    let emptyContentsOnly: Bool

    static func all() -> [CleanupCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        return [
            CleanupCategory(
                name: "Downloads", symbol: "arrow.down.circle",
                url: home.appendingPathComponent("Downloads"),
                consequence: "Files you downloaded. Nothing regenerates these — check before clearing.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "Caches", symbol: "clock.arrow.circlepath",
                url: library.appendingPathComponent("Caches"),
                consequence: "Rebuilt on demand. Apps may be slower the first time after clearing.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "Logs", symbol: "doc.text.magnifyingglass",
                url: library.appendingPathComponent("Logs"),
                consequence: "Diagnostic logs. Safe to clear unless you are chasing a bug.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "Xcode DerivedData", symbol: "hammer",
                url: library.appendingPathComponent("Developer/Xcode/DerivedData"),
                consequence: "Build products and indexes. Rebuilt on the next build, which will be slow.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "Xcode Archives", symbol: "archivebox",
                url: library.appendingPathComponent("Developer/Xcode/Archives"),
                consequence: "Shipped build archives. Needed to symbolicate old crash reports.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "iOS Simulators", symbol: "iphone",
                url: library.appendingPathComponent("Developer/CoreSimulator/Devices"),
                consequence: "Simulator disk images. Deleting loses simulator state; devices are recreated by Xcode.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "iOS Device Support", symbol: "iphone.gen1",
                url: library.appendingPathComponent("Developer/Xcode/iOS DeviceSupport"),
                consequence: "Symbols for devices you have debugged. Re-downloaded when you attach that device again.",
                emptyContentsOnly: true),
            CleanupCategory(
                name: "Containers", symbol: "shippingbox",
                url: library.appendingPathComponent("Containers"),
                consequence: "Sandboxed app data. This is real app state — inspect before removing anything.",
                emptyContentsOnly: true)
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }
}

// MARK: - File types

/// Rough bucketing by extension, for the composition bar.
enum FileKind: String, CaseIterable, Identifiable {
    case video, audio, image, document, developer, archive, other

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }

    /// Saturated, for dots and bars against the dark panel.
    var color: Color {
        switch self {
        case .video:     return Color(red: 0.93, green: 0.42, blue: 0.47)
        case .audio:     return Color(red: 0.55, green: 0.45, blue: 0.92)
        case .image:     return Color(red: 0.32, green: 0.66, blue: 0.94)
        case .document:  return Color(red: 0.93, green: 0.76, blue: 0.36)
        case .developer: return Color(red: 0.36, green: 0.80, blue: 0.58)
        case .archive:   return Color(red: 0.90, green: 0.57, blue: 0.33)
        case .other:     return Color(white: 0.55)
        }
    }

    /// Pale, for treemap tiles.
    ///
    /// The first version drew the saturated colour at 40% opacity over a dark
    /// panel, which composites to a muddy mid-tone: too dark for the black
    /// label, too light to read as a colour, and almost invisible tile-to-tile.
    /// Opaque pastels with near-black text is what every treemap that works
    /// does -- the tile is the surface, not a tint over the background.
    var tileColor: Color {
        switch self {
        case .video:     return Color(red: 0.98, green: 0.82, blue: 0.83)
        case .audio:     return Color(red: 0.85, green: 0.82, blue: 0.97)
        case .image:     return Color(red: 0.79, green: 0.89, blue: 0.98)
        case .document:  return Color(red: 0.98, green: 0.92, blue: 0.76)
        case .developer: return Color(red: 0.80, green: 0.94, blue: 0.86)
        case .archive:   return Color(red: 0.99, green: 0.87, blue: 0.76)
        case .other:     return Color(white: 0.88)
        }
    }

    private static let table: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        for ext in ["mp4", "mov", "m4v", "avi", "mkv", "webm"] { map[ext] = .video }
        for ext in ["mp3", "m4a", "wav", "aiff", "flac", "aac"] { map[ext] = .audio }
        for ext in ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp", "raw", "psd"] { map[ext] = .image }
        for ext in ["pdf", "doc", "docx", "pages", "txt", "md", "key", "numbers", "xlsx", "csv"] { map[ext] = .document }
        for ext in ["swift", "js", "ts", "py", "rs", "go", "c", "h", "m", "java", "o", "a", "dylib", "framework"] { map[ext] = .developer }
        for ext in ["zip", "tar", "gz", "bz2", "xz", "dmg", "pkg", "7z", "rar"] { map[ext] = .archive }
        return map
    }()

    static func of(_ url: URL) -> FileKind {
        table[url.pathExtension.lowercased()] ?? .other
    }
}

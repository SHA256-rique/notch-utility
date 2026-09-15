import Foundation
import AppKit
import Combine

/// Disk space, and the Bin.
///
/// ## Why "available for important usage" and not `volumeAvailableCapacityKey`
/// macOS reports three different free-space numbers and they disagree by tens of
/// gigabytes. `volumeAvailableCapacityKey` is the raw figure and it *understates*
/// what you can actually use, because it ignores purgeable space -- local Time
/// Machine snapshots, cached iCloud files, Xcode's derived data, everything the
/// system will evict on demand. Finder shows the purgeable-inclusive number, and
/// a utility that disagrees with Finder about free space is simply reporting a
/// bug to its user.
///
/// `volumeAvailableCapacityForImportantUsageKey` is what the system itself uses
/// to answer "can this download fit", and it is the number Finder shows. That is
/// the one people mean.
///
/// ## Why the Bin is measured lazily
/// Sizing the Bin means walking it, and someone who has just dragged a 40GB
/// video library in there has a Bin that takes a moment to add up. It is
/// measured when the Storage tab opens, on a utility queue, never at launch.
@MainActor
final class StorageService: ObservableObject {

    struct Volume: Identifiable, Equatable {
        var id: String { url.path }
        let url: URL
        let name: String
        let total: UInt64
        /// Purgeable-inclusive, matching Finder.
        let available: UInt64
        /// The raw figure, for the "purgeable" line.
        let availableStrict: UInt64
        let isRoot: Bool
        let isRemovable: Bool

        var used: UInt64 { total > available ? total - available : 0 }
        var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
        /// What the system would reclaim under pressure.
        var purgeable: UInt64 { available > availableStrict ? available - availableStrict : 0 }
    }

    struct BinContents: Equatable {
        var itemCount: Int
        var bytes: UInt64
        var isMeasuring: Bool
        var isEmpty: Bool { itemCount == 0 }
    }

    @Published private(set) var volumes: [Volume] = []
    @Published private(set) var bin = BinContents(itemCount: 0, bytes: 0, isMeasuring: false)
    @Published private(set) var lastError: String?

    private var token: UUID?
    private var measureTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func activate() {
        refreshVolumes()
        measureBin()
        // Disk space moves slowly. A 30-second tick is enough to watch a large
        // copy progress and is, as always, hub-registered so it stops dead when
        // the tab closes.
        token = WidgetPollingHub.shared.register(label: "storage", interval: 30) { [weak self] in
            Task { @MainActor in self?.refreshVolumes() }
        }
    }

    func deactivate() {
        WidgetPollingHub.shared.unregister(token)
        token = nil
        measureTask?.cancel()
        measureTask = nil
    }

    func refresh() {
        refreshVolumes()
        measureBin()
    }

    // MARK: - Volumes

    private func refreshVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []

        let root = URL(fileURLWithPath: "/")
        var found: [Volume] = []

        for url in mounted {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Browsable is what separates a real disk from the dozens of system
            // mounts macOS keeps (the sealed system volume, VM, Preboot). Without
            // this the list is mostly noise.
            guard values.volumeIsBrowsable ?? true else { continue }
            guard let total = values.volumeTotalCapacity, total > 0 else { continue }

            let strict = UInt64(max(0, values.volumeAvailableCapacity ?? 0))
            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) } ?? strict

            found.append(Volume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                total: UInt64(total),
                available: max(important, strict),
                availableStrict: strict,
                isRoot: url.path == root.path,
                isRemovable: values.volumeIsRemovable ?? false))
        }

        // Boot volume first, then by size. The boot volume is the one anyone
        // opening this is asking about.
        volumes = found.sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.total > $1.total
        }
    }

    var bootVolume: Volume? { volumes.first { $0.isRoot } ?? volumes.first }

    // MARK: - Bin

    /// The user's Bin. `.trashDirectory` resolves per-volume; this is the one in
    /// the home directory, which is what "empty the Bin" means to a person.
    static var trashURL: URL? {
        try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
    }

    func measureBin() {
        guard let trash = Self.trashURL else { return }
        measureTask?.cancel()
        bin.isMeasuring = true

        measureTask = Task.detached(priority: .utility) {
            let result = Self.measure(trash)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.bin = result }
        }
    }

    nonisolated private static func measure(_ trash: URL) -> BinContents {
        let manager = FileManager.default
        let top = (try? manager.contentsOfDirectory(at: trash,
                                                    includingPropertiesForKeys: nil,
                                                    options: [])) ?? []

        var bytes: UInt64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]

        // Allocated size, not file size: a thousand tiny files occupy far more
        // of the disk than their contents add up to, and the number the user
        // cares about is how much space emptying the Bin will give back.
        if let walker = manager.enumerator(at: trash, includingPropertiesForKeys: Array(keys),
                                           options: [.skipsPackageDescendants]) {
            for case let url as URL in walker {
                if Task.isCancelled { break }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { continue }
                bytes += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }

        return BinContents(itemCount: top.count, bytes: bytes, isMeasuring: false)
    }

    /// Empties the Bin.
    ///
    /// ## Why NSWorkspace's recycler and not `removeItem`
    /// Deleting the Bin's contents by hand skips everything the system does
    /// around it: it does not update Finder's Bin icon, it does not handle
    /// locked or in-use files, it does not respect per-volume `.Trashes`
    /// directories, and it silently fails on anything owned by another user.
    /// `recycle` is the wrong direction; the right call is to ask the Finder,
    /// which owns this operation, to do it.
    ///
    /// This is irreversible, so the caller must confirm first -- and does.
    func emptyBin(completion: @escaping (Bool) -> Void) {
        lastError = nil
        let script = """
        tell application "Finder"
            empty trash
        end tell
        """
        // AppleScript rather than a private API: emptying the Bin is a Finder
        // operation and Finder exposes it deliberately. The one cost is that the
        // user gets a "NotchBuddy wants to control Finder" prompt the first
        // time, which is the correct amount of friction for an irreversible
        // delete of everything in the Bin.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let ran = NSAppleScript(source: script)?.executeAndReturnError(&error)
            let message = error?[NSAppleScript.errorMessage] as? String

            Task { @MainActor in
                if ran == nil {
                    self.lastError = message ?? "Finder declined to empty the Bin."
                    completion(false)
                } else {
                    self.measureBin()
                    self.refreshVolumes()
                    NotchArbiter.shared.flash("Bin emptied", symbol: "trash.fill",
                                              module: .files)
                    completion(true)
                }
            }
        }
    }

    func openBin() {
        guard let trash = Self.trashURL else { return }
        NSWorkspace.shared.open(trash)
    }

    // MARK: - Formatting

    nonisolated static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

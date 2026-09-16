import Foundation
import Darwin
import Combine

/// CPU / memory / disk read straight from the Darwin kernel interfaces.
///
/// ## The rule this file exists to honour
/// Never shell out for data an API can give you. The tempting implementation is
/// `Process` + `top -l 1` or `ps -A -o %cpu` + string parsing. That is wrong on
/// four counts, and the first is the expensive one:
///
///  1. **Spawn cost.** `posix_spawn` + dynamic linking + the tool's own startup
///     is on the order of 10-30ms of CPU *per sample*. At a 2-second interval
///     that is roughly 0.5-1.5% of a core, burned continuously, to display a
///     number. The measurement would cost more than everything else the app does
///     combined. `host_statistics64` is a single Mach trap: microseconds.
///  2. **Output stability.** `top`'s column layout is not API. It has changed
///     across releases and differs by locale.
///  3. **Localisation.** Decimal separators differ; "1,5%" parses to 1 in a
///     naive `Double(...)`.
///  4. **Security surface.** Spawning shells widens the process tree and
///     inherits environment in ways that are easy to get subtly wrong.
///
/// ## How each number is actually obtained
///  * **CPU** -- `host_statistics(HOST_CPU_LOAD_INFO)` returns monotonically
///    increasing tick counters for user/system/idle/nice. A percentage requires
///    two samples: we diff against the previous snapshot. This is why the very
///    first sample after a tab opens reports 0 and the second is the first real
///    reading.
///  * **Memory** -- `host_statistics64(HOST_VM_INFO64)`. "Used" deliberately
///    follows Activity Monitor's definition of Memory Used: active + wired +
///    compressed. Excluding `purgeable` and counting `external` (file-backed)
///    pages as free is what makes our number agree with the one users can check
///    us against; a naive "total - free" reads as 90% on every healthy Mac and
///    makes the widget look broken.
///  * **Disk** -- `URLResourceKey.volumeAvailableCapacityForImportantUsageKey`,
///    which accounts for purgeable space the way Finder does, rather than raw
///    statfs free blocks.
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    struct Snapshot: Equatable {
        var cpuPercent: Double = 0        // 0...100 across all cores
        var memUsedBytes: UInt64 = 0
        var memTotalBytes: UInt64 = 0
        var diskUsedBytes: UInt64 = 0
        var diskTotalBytes: UInt64 = 0
        var memPercent: Double { memTotalBytes == 0 ? 0 : Double(memUsedBytes) / Double(memTotalBytes) * 100 }
        var diskPercent: Double { diskTotalBytes == 0 ? 0 : Double(diskUsedBytes) / Double(diskTotalBytes) * 100 }
    }

    @Published private(set) var snapshot = Snapshot()

    private var previousCPUTicks: host_cpu_load_info?
    private var hubToken: UUID?
    /// Refcount: both the pill and the Home rings may want stats. The hub
    /// registration is shared and only torn down when the last consumer leaves.
    private var consumers = 0
    /// Disk barely moves; sampling it every 2s alongside CPU would be wasteful.
    private var sampleIndex = 0

    private init() {
        snapshot.memTotalBytes = ProcessInfo.processInfo.physicalMemory
    }

    // MARK: - Lifecycle, driven by tab open/close

    func addConsumer() {
        consumers += 1
        guard consumers == 1 else { return }
        sampleDisk()
        hubToken = WidgetPollingHub.shared.register(
            label: "system-stats",
            interval: Settings.shared.data.statsPollInterval
        ) { [weak self] in self?.sample() }
        Log.tier1.debug("system stats: first consumer, registered with hub")
    }

    func removeConsumer() {
        consumers = max(0, consumers - 1)
        guard consumers == 0 else { return }
        WidgetPollingHub.shared.unregister(hubToken)
        hubToken = nil
        // Drop the baseline so a later re-open does not compute a CPU average
        // across the whole idle gap and report a nonsense spike.
        previousCPUTicks = nil
        NotchArbiter.shared.withdraw("stats")
        Log.tier1.debug("system stats: last consumer left, unregistered")
    }

    // MARK: - Sampling

    private func sample() {
        var next = snapshot
        if let cpu = readCPU() { next.cpuPercent = cpu }
        if let mem = readMemory() {
            next.memUsedBytes = mem.used
            next.memTotalBytes = mem.total
        }
        sampleIndex += 1
        if sampleIndex % 15 == 0 { sampleDisk() }   // ~every 30s at a 2s tick

        guard next != snapshot else { return }
        snapshot = next
        publishClaim()
    }

    private func readCPU() -> Double? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previousCPUTicks = info }

        guard let prev = previousCPUTicks else { return nil }   // need a baseline
        let user   = Double(info.cpu_ticks.0 - prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle   = Double(info.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice   = Double(info.cpu_ticks.3 - prev.cpu_ticks.3)
        let total  = user + system + idle + nice
        guard total > 0 else { return nil }
        return min(100, max(0, (user + system + nice) / total * 100))
    }

    private func readMemory() -> (used: UInt64, total: UInt64)? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        // Activity Monitor's "Memory Used". See the header comment for why this
        // specific combination and not `total - free`.
        let active     = UInt64(stats.active_count) * page
        let wired      = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return (active + wired + compressed, ProcessInfo.processInfo.physicalMemory)
    }

    private func sampleDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) else { return }
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let available = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        snapshot.diskTotalBytes = total
        snapshot.diskUsedBytes = total > available ? total - available : 0
    }

    private func publishClaim() {
        guard Settings.shared.data.showStatsInPill else {
            NotchArbiter.shared.withdraw("stats")
            return
        }
        NotchArbiter.shared.claim(PillClaim(
            id: "stats", priority: .ambient, module: .system,
            symbol: "cpu", text: "\(Int(snapshot.cpuPercent))%",
            detail: "RAM \(Int(snapshot.memPercent))%",
            rank: 20, expiresAt: nil, progress: snapshot.cpuPercent / 100))
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .memory
        return f.string(fromByteCount: Int64(bytes))
    }
}

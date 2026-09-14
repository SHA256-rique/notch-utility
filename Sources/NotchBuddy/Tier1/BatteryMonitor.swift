import Foundation
import IOKit.ps
import Combine

/// Battery state, entirely event-driven.
///
/// ## Why not poll
/// The obvious implementation is a 30-second timer calling
/// `IOPSCopyPowerSourcesInfo`. That is 2,880 wakeups a day to learn a number
/// that changes maybe 200 times. Worse, it is 2,880 wakeups that happen while
/// the panel is collapsed -- exactly the state this app promises costs nothing.
///
/// ## What we do instead
/// `IOPSNotificationCreateRunLoopSource` gives a run-loop source that fires when
/// the power-management subsystem itself decides something changed: percentage
/// tick, charger plugged/unplugged, low-power-mode toggle, time-remaining
/// recalculation. Between those events the process is genuinely asleep.
///
/// This monitor is therefore exempt from the polling hub -- it never polls, so
/// there is nothing for the hub to switch off. It stays live while collapsed
/// because it is free.
///
/// ## The C-interop shape
/// The callback is a bare C function pointer with a `void *` context, so we pass
/// an unretained pointer to self. The source is retained for the process
/// lifetime (this is a singleton), so the unretained pointer cannot dangle.
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    struct State: Equatable {
        var percent: Int = 100
        var isCharging = false
        var isPluggedIn = false
        var isPresent = false
        /// Minutes, or nil when macOS says "calculating".
        var timeRemaining: Int? = nil
        var isLowPowerMode = false
    }

    @Published private(set) var state = State()

    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func start() {
        refresh()

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            // IOKit delivers on the run loop we registered with, which is the
            // main run loop, so no hop is needed -- but being explicit here
            // protects against a future move to a background run loop.
            DispatchQueue.main.async { monitor.refresh() }
        }, context)?.takeRetainedValue() else {
            Log.tier1.error("could not create power-source notification source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source

        // Low Power Mode is a separate notification from the power-source one.
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }

        Log.tier1.info("battery monitor armed (event-driven, 0 timers)")
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    private func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        var next = State()
        next.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let type = info[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType
            else { continue }

            next.isPresent = true
            if let current = info[kIOPSCurrentCapacityKey] as? Int,
               let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
                next.percent = Int((Double(current) / Double(max) * 100).rounded())
            }
            next.isCharging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            next.isPluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            // -1 means "still calculating"; showing "-1 min" is worse than
            // showing nothing, so it becomes nil.
            let key = next.isPluggedIn ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = info[key] as? Int, minutes >= 0 { next.timeRemaining = minutes }
            break
        }

        guard next != state else { return }   // do not invalidate SwiftUI for a no-op
        state = next
        publishClaim()
    }

    /// Battery is *ambient*: it is the pill's resting content, and it must never
    /// evict a running timer or a blocked CLI approval.
    private func publishClaim() {
        guard Settings.shared.data.showBatteryInPill, state.isPresent else {
            NotchArbiter.shared.withdraw("battery")
            return
        }
        let symbol: String
        if state.isCharging { symbol = "battery.100.bolt" }
        else if state.percent <= 10 { symbol = "battery.0" }
        else if state.percent <= 35 { symbol = "battery.25" }
        else if state.percent <= 65 { symbol = "battery.50" }
        else { symbol = "battery.100" }

        var detail: String? = nil
        if let minutes = state.timeRemaining, !state.isCharging {
            detail = "\(minutes / 60)h \(minutes % 60)m left"
        }

        NotchArbiter.shared.claim(PillClaim(
            id: "battery", priority: .ambient, module: .battery,
            symbol: symbol, text: "\(state.percent)%", detail: detail,
            rank: 10, expiresAt: nil, progress: Double(state.percent) / 100.0))

        // A genuinely urgent state gets a transient pop-in once, on the edge.
        if state.percent <= 10 && !state.isPluggedIn {
            NotchArbiter.shared.flash("Battery \(state.percent)%", symbol: "battery.0", module: .battery, detail: "Plug in soon", duration: 4)
        }
    }
}

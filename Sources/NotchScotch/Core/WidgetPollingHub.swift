import Foundation
import QuartzCore

/// The single lever that makes idle cost near-zero.
///
/// ## The problem this solves
/// The naive structure for an app like this is: every widget owns a `Timer`.
/// Ten widgets, ten timers, ten independent wakeups. On Apple Silicon each timer
/// fire is a scheduler wakeup that can pull a core out of its idle state; the
/// cost is not the work the callback does, it is the wakeup itself. macOS's own
/// power accounting punishes exactly this pattern ("wakeups per second" is a
/// first-class metric in `powermetrics`).
///
/// ## The rule
/// No widget is permitted to own a `Timer`. Widgets register an interval and a
/// closure here. The hub keeps **one** `DispatchSourceTimer` running at the
/// greatest common divisor of all registered intervals and dispatches each
/// registration when its own interval has elapsed. Ten widgets at 1s/2s/5s
/// produce one wakeup per second, not ten.
///
/// ## The kill switch
/// `setActive(false)` stops the underlying source entirely -- not "sets a flag
/// and keeps ticking". When the panel is collapsed and unpinned, the process has
/// no scheduled work at all, which is what lets the idle benchmark in the README
/// land where it does.
///
/// ## Leeway
/// The timer is configured with generous leeway (25% of the interval). Leeway
/// lets the kernel coalesce our wakeup with one it was going to perform anyway,
/// which is the single highest-leverage line in this file. Nothing here needs
/// millisecond precision -- it is a CPU gauge and a countdown label.
final class WidgetPollingHub {
    static let shared = WidgetPollingHub()

    private struct Registration {
        let id: UUID
        let interval: TimeInterval
        let action: () -> Void
        var lastFired: CFTimeInterval
        /// A label purely for the Settings > Diagnostics view, so a user chasing
        /// battery drain can see exactly what is registered right now.
        let label: String
    }

    private var registrations: [Registration] = []
    private var timer: DispatchSourceTimer?
    private var active = false
    private let lock = NSLock()

    /// Exposed for the diagnostics panel and for tests.
    private(set) var tickCount: Int = 0

    private init() {}

    // MARK: - Registration

    /// Register a repeating action. Returns a token the caller **must** pass to
    /// `unregister` in its teardown path (tab close, not app quit).
    @discardableResult
    func register(label: String, interval: TimeInterval, action: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        registrations.append(Registration(id: id,
                                          interval: max(0.25, interval),
                                          action: action,
                                          // -interval so the first tick fires immediately
                                          // rather than after a full period of blank UI.
                                          lastFired: CACurrentMediaTime() - interval,
                                          label: label))
        lock.unlock()
        Log.hub.debug("register \(label, privacy: .public) @\(interval)s")
        rebuildTimer()
        return id
    }

    func unregister(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        let before = registrations.count
        registrations.removeAll { $0.id == id }
        let changed = registrations.count != before
        lock.unlock()
        if changed { rebuildTimer() }
    }

    // MARK: - Activation

    /// Called by the panel controller on expand/collapse/pin. This is the only
    /// way the hub ever starts running.
    func setActive(_ newValue: Bool) {
        lock.lock()
        guard newValue != active else { lock.unlock(); return }
        active = newValue
        lock.unlock()
        Log.hub.debug("setActive \(newValue)")
        rebuildTimer()
    }

    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

    /// Snapshot for the diagnostics UI: what is registered and at what rate.
    func diagnostics() -> (active: Bool, entries: [(label: String, interval: TimeInterval)], effectiveTick: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (active,
                registrations.map { ($0.label, $0.interval) },
                registrations.isEmpty ? 0 : Self.gcdInterval(registrations.map(\.interval)))
    }

    // MARK: - Timer plumbing

    private func rebuildTimer() {
        lock.lock()
        let shouldRun = active && !registrations.isEmpty
        let tick = registrations.isEmpty ? 1.0 : Self.gcdInterval(registrations.map(\.interval))
        lock.unlock()

        // Always tear the old source down first. Re-arming a live
        // DispatchSourceTimer with a new interval is legal but leaves the old
        // schedule in flight for one fire; cancel/recreate is unambiguous.
        timer?.cancel()
        timer = nil

        guard shouldRun else {
            Log.hub.debug("hub idle -- no scheduled work")
            return
        }

        let source = DispatchSource.makeTimerSource(flags: [], queue: .main)
        source.schedule(deadline: .now() + tick,
                        repeating: tick,
                        leeway: .milliseconds(Int(tick * 250)))
        source.setEventHandler { [weak self] in self?.fire() }
        source.resume()
        timer = source
        Log.hub.debug("hub tick \(tick, format: .fixed(precision: 2))s for \(self.registrations.count) registration(s)")
    }

    private func fire() {
        let now = CACurrentMediaTime()
        lock.lock()
        tickCount += 1
        var due: [() -> Void] = []
        for index in registrations.indices {
            // The 1ms slack absorbs the leeway the kernel applied, otherwise a
            // wakeup delivered 0.3ms early would skip a whole period.
            if now - registrations[index].lastFired >= registrations[index].interval - 0.001 {
                registrations[index].lastFired = now
                due.append(registrations[index].action)
            }
        }
        lock.unlock()
        // Callbacks run outside the lock: a widget is allowed to unregister
        // itself from inside its own callback without deadlocking.
        for action in due { action() }
    }

    /// GCD over the registered intervals, quantised to 250ms so we do not end up
    /// with a 10ms tick because someone registered 0.75s alongside 2s.
    private static func gcdInterval(_ values: [TimeInterval]) -> TimeInterval {
        let quanta = values.map { max(1, Int(($0 * 4).rounded())) }   // quarter-seconds
        let g = quanta.reduce(quanta[0]) { gcd($0, $1) }
        return max(0.25, TimeInterval(g) / 4.0)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}

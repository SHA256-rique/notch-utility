import AppKit
import Combine

/// Screen-time tracking, done ourselves, event-driven.
///
/// ## Why not read Apple's Screen Time database
/// Apple's data lives in `~/Library/Application Support/Knowledge/knowledgeC.db`.
/// Reading it requires **Full Disk Access** -- a permission that cannot be
/// requested programmatically, only granted by the user walking into System
/// Settings and dragging the app into a list. Asking for the single most
/// alarming permission macOS offers, so a widget can show a bar chart, is a
/// terrible trade for an app whose entire pitch is restraint. The schema is also
/// private and has changed shape between releases.
///
/// ## What we do instead
/// `NSWorkspace.didActivateApplicationNotification` fires when the frontmost app
/// changes. That is the only signal needed: attribute the elapsed wall time
/// since the last switch to the app that was frontmost. Zero permissions, zero
/// polling, and the numbers are *ours* so they are explainable.
///
/// Edge cases that would otherwise inflate the numbers, all handled:
///   * **Sleep / lock.** `NSWorkspace.willSleepNotification` and the screen-lock
///     distributed notification close the open segment; waking starts a new one.
///     Without this, closing the lid at 6pm and opening it at 9am credits
///     15 hours to whatever app was frontmost.
///   * **Day rollover.** A segment spanning midnight is split at midnight so
///     neither day is over-credited.
///   * **Our own app.** NotchBuddy excludes itself; it is an accessory app and
///     counting it would be noise.
final class AppUsageTracker: ObservableObject {
    static let shared = AppUsageTracker()

    struct DayUsage: Codable {
        var date: String                    // yyyy-MM-dd, local
        var seconds: [String: Double] = [:] // bundle id -> seconds
        var names: [String: String] = [:]   // bundle id -> display name
        var total: Double { seconds.values.reduce(0, +) }
    }

    private struct Model: Codable { var days: [DayUsage] = [] }

    @Published private(set) var today = DayUsage(date: AppUsageTracker.key(Date()))
    @Published private(set) var history: [DayUsage] = []

    private let store = JSONStore<Model>(filename: "screentime.json", debounce: 5)
    private var model = Model()
    private var currentBundle: String?
    private var currentName: String?
    private var segmentStart: Date?
    private var observers: [NSObjectProtocol] = []
    private var isSuspended = false

    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.notchbuddy.app"

    private init() {}

    // MARK: - Lifecycle

    /// Started at launch, unlike most subsystems: usage data is only meaningful
    /// if it is collected continuously, and the cost is a notification handler
    /// that fires when the user switches apps -- far below the noise floor.
    func start() {
        model = store.load() ?? Model()
        pruneAndPublish()

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.switchTo(bundle: app?.bundleIdentifier, name: app?.localizedName)
        })
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspend()
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        })
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.suspend()
        })
        observers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.resume()
        })

        let front = NSWorkspace.shared.frontmostApplication
        switchTo(bundle: front?.bundleIdentifier, name: front?.localizedName)
        Log.tier1.info("app usage tracker armed (event-driven, 0 timers)")
    }

    func flush() {
        closeSegment(at: Date())
        store.saveNow(model)
    }

    // MARK: - Segment accounting

    private func suspend() {
        guard !isSuspended else { return }
        closeSegment(at: Date())
        isSuspended = true
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        segmentStart = Date()
    }

    private func switchTo(bundle: String?, name: String?) {
        closeSegment(at: Date())
        guard let bundle, bundle != Self.ownBundleID else {
            currentBundle = nil; currentName = nil; segmentStart = nil
            return
        }
        currentBundle = bundle
        currentName = name ?? bundle
        segmentStart = Date()
    }

    private func closeSegment(at end: Date) {
        guard !isSuspended,
              let bundle = currentBundle,
              let start = segmentStart,
              end > start else { segmentStart = end; return }

        // Split at midnight so a segment that straddles the day boundary is
        // credited to both days correctly.
        let midnight = Calendar.current.startOfDay(for: end)
        if start < midnight {
            credit(bundle: bundle, name: currentName ?? bundle, seconds: midnight.timeIntervalSince(start), day: Self.key(start))
            credit(bundle: bundle, name: currentName ?? bundle, seconds: end.timeIntervalSince(midnight), day: Self.key(end))
        } else {
            credit(bundle: bundle, name: currentName ?? bundle, seconds: end.timeIntervalSince(start), day: Self.key(end))
        }
        segmentStart = end
        store.save(model)
        pruneAndPublish()
    }

    private func credit(bundle: String, name: String, seconds: Double, day: String) {
        guard seconds > 0.5 else { return }   // ignore alt-tab flickers
        if let index = model.days.firstIndex(where: { $0.date == day }) {
            model.days[index].seconds[bundle, default: 0] += seconds
            model.days[index].names[bundle] = name
        } else {
            var d = DayUsage(date: day)
            d.seconds[bundle] = seconds
            d.names[bundle] = name
            model.days.append(d)
        }
    }

    /// Keeps 30 days. Beyond that the JSON file grows without anyone looking at
    /// it, which is exactly the kind of quiet cost this app is meant to avoid.
    private func pruneAndPublish() {
        model.days.sort { $0.date < $1.date }
        if model.days.count > 30 { model.days.removeFirst(model.days.count - 30) }
        let todayKey = Self.key(Date())
        today = model.days.first { $0.date == todayKey } ?? DayUsage(date: todayKey)
        history = model.days
    }

    /// Called by the Screen Time widget when it appears, so the number on screen
    /// includes the in-progress segment rather than lagging by one app switch.
    func refreshNow() {
        closeSegment(at: Date())
    }

    // MARK: - Derived values for the widget

    var last7Days: [DayUsage] {
        let keys = (0..<7).map { Self.key(Calendar.current.date(byAdding: .day, value: -$0, to: Date())!) }.reversed()
        return keys.map { k in model.days.first { $0.date == k } ?? DayUsage(date: k) }
    }

    /// Percentage change of today vs the mean of the previous 6 days.
    var percentChangeVsAverage: Double? {
        let previous = last7Days.dropLast()
        let counted = previous.filter { $0.total > 0 }
        guard !counted.isEmpty else { return nil }
        let mean = counted.reduce(0) { $0 + $1.total } / Double(counted.count)
        guard mean > 60 else { return nil }
        return (today.total - mean) / mean * 100
    }

    var mostUsedToday: (name: String, seconds: Double)? {
        guard let top = today.seconds.max(by: { $0.value < $1.value }) else { return nil }
        return (today.names[top.key] ?? top.key, top.value)
    }

    var topAppsToday: [(name: String, bundle: String, seconds: Double)] {
        today.seconds.sorted { $0.value > $1.value }.prefix(8).map {
            (today.names[$0.key] ?? $0.key, $0.key, $0.value)
        }
    }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func humanDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}

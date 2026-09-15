import Foundation
import AppKit
import Combine
import UserNotifications

/// Drink water: a tally of glasses today and an optional recurring nudge.
///
/// ## Why this is not a `WidgetPollingHub` registration
/// The hub exists to coalesce *display* refreshes, and it is switched off
/// entirely while the panel is collapsed -- which is exactly when a water
/// reminder needs to fire. A nudge that only arrives while you happen to be
/// looking at the notch is not a reminder.
///
/// So the reminder is a single one-shot `DispatchSourceTimer` re-armed after
/// each fire, the same pattern `TimeEngine` uses for timer deadlines: one
/// scheduled wakeup, generous leeway (a reminder five minutes late is still a
/// reminder), and nothing at all pending when nudges are off.
///
/// ## Why the tally resets by date comparison rather than a midnight timer
/// A midnight timer has to survive sleep, clock changes and the app not running.
/// Storing the day the tally belongs to and comparing on read has none of those
/// failure modes: close the lid on Tuesday with six glasses logged, open it on
/// Thursday, and the count is zero because the stored day is not today.
@MainActor
final class WaterTracker: ObservableObject {
    static let shared = WaterTracker()

    private struct Model: Codable {
        var day: String = ""
        var glasses: Int = 0
        /// Per-day totals, kept for the last fortnight so the section can show
        /// whether today is better or worse than usual.
        var history: [String: Int] = [:]
        var lastNudge: Date?
    }

    @Published private(set) var glasses: Int = 0
    @Published private(set) var history: [String: Int] = [:]
    @Published private(set) var nextNudge: Date?

    private var model = Model()
    private let store = JSONStore<Model>(filename: "water.json", debounce: 1.0)
    private var nudgeSource: DispatchSourceTimer?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        model = store.load() ?? Model()
        rolloverIfNeeded()
        glasses = model.glasses
        history = model.history
        rearm()
    }

    func flush() { store.saveNow(model) }

    // MARK: - Tally

    func addGlass() {
        rolloverIfNeeded()
        model.glasses += 1
        model.history[Self.today()] = model.glasses
        publish()

        let goal = Settings.shared.data.waterGlassGoal
        if model.glasses == goal {
            NotchArbiter.shared.flash("Goal reached", symbol: "drop.fill",
                                      module: .time, detail: "\(goal) glasses", duration: 3)
        } else {
            NotchArbiter.shared.flash("\(model.glasses) glasses", symbol: "drop.fill", module: .time)
        }
        // Logging a glass restarts the clock. Being reminded ninety seconds
        // after you have just had one is how a nudge becomes an annoyance.
        rearm()
    }

    func removeGlass() {
        rolloverIfNeeded()
        model.glasses = max(0, model.glasses - 1)
        model.history[Self.today()] = model.glasses
        publish()
    }

    func resetToday() {
        rolloverIfNeeded()
        model.glasses = 0
        model.history[Self.today()] = 0
        publish()
    }

    var goal: Int { max(1, Settings.shared.data.waterGlassGoal) }
    var progress: Double { min(1, Double(glasses) / Double(goal)) }

    /// Mean glasses per day over the days actually recorded, excluding today --
    /// today is still in progress and would drag the comparison down all morning.
    var dailyAverage: Double {
        let others = history.filter { $0.key != Self.today() }
        guard !others.isEmpty else { return 0 }
        return Double(others.values.reduce(0, +)) / Double(others.count)
    }

    /// Last 14 days, oldest first, zero-filled. Backs the small bar strip.
    var recentDays: [(day: String, glasses: Int)] {
        let calendar = Calendar.current
        return (0..<14).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.key(date)
            return (key, history[key] ?? 0)
        }
    }

    // MARK: - Settings

    func setNudges(enabled: Bool) {
        Settings.shared.data.waterNudgesEnabled = enabled
        rearm()
    }

    func setInterval(minutes: Double) {
        Settings.shared.data.waterIntervalMinutes = minutes
        rearm()
    }

    // MARK: - Nudging

    private func rearm() {
        nudgeSource?.cancel()
        nudgeSource = nil
        nextNudge = nil

        guard Settings.shared.data.waterNudgesEnabled else { return }
        let interval = max(60, Settings.shared.data.waterIntervalMinutes * 60)
        let fireAt = Date().addingTimeInterval(interval)
        nextNudge = fireAt

        let source = DispatchSource.makeTimerSource(queue: .main)
        // A minute of leeway. This lets the kernel fold the wakeup into one it
        // was going to make anyway, and nobody can tell a water reminder is
        // fifty seconds late.
        source.schedule(deadline: .now() + interval, leeway: .seconds(60))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        source.resume()
        nudgeSource = source
    }

    private func fire() {
        rolloverIfNeeded()
        model.lastNudge = Date()

        // The pill toast is the primary channel -- it is the whole point of the
        // app. The system notification is the fallback for when the Mac is
        // showing something fullscreen and the notch is not visible.
        NotchArbiter.shared.flash("Drink water", symbol: "drop.fill", module: .time,
                                  detail: "\(model.glasses)/\(goal) today", duration: 4)

        let content = UNMutableNotificationContent()
        content.title = "Time for a glass of water"
        content.body = "\(model.glasses) of \(goal) so far today."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "water.nudge",
                                  content: content,
                                  trigger: nil))

        persist()
        rearm()
    }

    // MARK: - Day handling

    private func rolloverIfNeeded() {
        let today = Self.today()
        guard model.day != today else { return }
        if !model.day.isEmpty { model.history[model.day] = model.glasses }
        model.day = today
        model.glasses = 0
        // Keep a fortnight. This is a habit nudge, not a health record.
        let cutoff = Self.key(Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date())
        model.history = model.history.filter { $0.key >= cutoff }
    }

    private func publish() {
        glasses = model.glasses
        history = model.history
        persist()
    }

    private func persist() { store.save(model) }

    static func today() -> String { key(Date()) }

    static func key(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

import Foundation
import AppKit
import UserNotifications
import Combine
import AVFoundation

// MARK: - Models

struct NBTimer: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var duration: TimeInterval
    /// Absolute wall-clock end. Storing the *deadline* rather than a
    /// "remaining" counter is the whole trick: see the note on TimeEngine.
    var endsAt: Date
    var pausedRemaining: TimeInterval?
    var soundName: String = "Glass"

    var isPaused: Bool { pausedRemaining != nil }
    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        return max(0, endsAt.timeIntervalSinceNow)
    }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / duration))
    }
    var isFinished: Bool { !isPaused && remaining <= 0 }
}

struct NBAlarm: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var hour: Int
    var minute: Int
    /// 1 = Sunday ... 7 = Saturday, matching Calendar's weekday component.
    /// Empty means a one-shot alarm at the next occurrence.
    var weekdays: Set<Int> = []
    var isEnabled = true
    var soundName: String = "Glass"
    var snoozeMinutes: Int = 9
    /// Set while snoozed so the alarm re-fires at this exact time instead of its
    /// scheduled one.
    var snoozedUntil: Date?

    /// Next fire date at or after `from`, honouring the repeat schedule.
    func nextFire(from: Date = Date()) -> Date? {
        guard isEnabled else { return nil }
        if let snoozedUntil, snoozedUntil > from { return snoozedUntil }
        let cal = Calendar.current
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = 0

        if weekdays.isEmpty {
            return cal.nextDate(after: from, matching: components, matchingPolicy: .nextTime)
        }
        // Ask for the next occurrence on each selected weekday and take the
        // soonest. Cheaper and far less error-prone than hand-rolling the
        // day-of-week arithmetic across DST boundaries.
        return weekdays.compactMap { weekday -> Date? in
            var c = components
            c.weekday = weekday
            return cal.nextDate(after: from, matching: c, matchingPolicy: .nextTime)
        }.min()
    }
}

struct PomodoroState: Codable, Equatable {
    enum Phase: String, Codable { case focus, shortBreak, longBreak, idle }
    var phase: Phase = .idle
    var endsAt: Date = .distantPast
    var pausedRemaining: TimeInterval?
    var completedFocusSessions: Int = 0
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    var sessionsBeforeLongBreak: Int = 4

    var isRunning: Bool { phase != .idle && pausedRemaining == nil }
    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        return phase == .idle ? 0 : max(0, endsAt.timeIntervalSinceNow)
    }
    var phaseLength: TimeInterval {
        switch phase {
        case .focus: return Double(focusMinutes) * 60
        case .shortBreak: return Double(shortBreakMinutes) * 60
        case .longBreak: return Double(longBreakMinutes) * 60
        case .idle: return Double(focusMinutes) * 60
        }
    }
    var progress: Double {
        guard phaseLength > 0, phase != .idle else { return 0 }
        return min(1, max(0, 1 - remaining / phaseLength))
    }
}

struct StopwatchState: Codable, Equatable {
    var startedAt: Date?
    var accumulated: TimeInterval = 0
    var laps: [TimeInterval] = []
    var isRunning: Bool { startedAt != nil }
    var elapsed: TimeInterval {
        accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }
}

// MARK: - Engine

/// Unified owner of timers, alarms, pomodoro and stopwatch.
///
/// ## The one design decision that matters here
/// Every running thing stores an **absolute deadline** (`endsAt`), never a
/// decrementing counter. Consequences, all good:
///   * The engine does not need to tick to stay *correct* -- only to redraw.
///     A timer is right even if nothing ran for ten minutes.
///   * Sleeping the Mac for an hour does not add an hour to your pasta timer,
///     which is the classic bug in counter-based implementations.
///   * It lets the redraw tick be registered with the polling hub and therefore
///     switched off with everything else while the panel is collapsed. The
///     countdown in the pill stops *animating* but never stops being accurate.
///
/// ## Firing while nothing is ticking
/// Because redraws stop when the panel collapses, completion cannot be detected
/// by a tick. Each running item schedules a `UNTimeIntervalNotificationTrigger`
/// with the system, plus a one-shot `DispatchSourceTimer` armed for the exact
/// deadline. The one-shot is a single scheduled wakeup per running timer -- not
/// a repeating poll -- so an idle machine with a 30-minute timer set has exactly
/// one pending wakeup 30 minutes out.
@MainActor
final class TimeEngine: ObservableObject {
    static let shared = TimeEngine()

    private struct Model: Codable {
        var timers: [NBTimer] = []
        var alarms: [NBAlarm] = []
        var pomodoro = PomodoroState()
        var stopwatch = StopwatchState()
    }

    @Published var timers: [NBTimer] = []      { didSet { persist(); rearm() } }
    @Published var alarms: [NBAlarm] = []      { didSet { persist(); rearm() } }
    @Published var pomodoro = PomodoroState()  { didSet { persist(); rearm() } }
    @Published var stopwatch = StopwatchState(){ didSet { persist() } }

    /// Bumped by the redraw tick purely to invalidate SwiftUI views that read
    /// `remaining`, which is computed rather than stored.
    @Published private(set) var redrawTick: Int = 0

    private let store = JSONStore<Model>(filename: "time.json", debounce: 1.0)
    private var deadlineSources: [UUID: DispatchSourceTimer] = [:]
    private var redrawToken: UUID?
    private var isLoading = false

    private init() {}

    func start() {
        isLoading = true
        let model = store.load() ?? Model()
        timers = model.timers.filter { !$0.isFinished || $0.isPaused }
        alarms = model.alarms
        pomodoro = model.pomodoro
        stopwatch = model.stopwatch
        isLoading = false

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.tier1.info("notification authorization granted=\(granted)")
        }
        rearm()
        publishClaims()
    }

    func flush() {
        store.saveNow(Model(timers: timers, alarms: alarms, pomodoro: pomodoro, stopwatch: stopwatch))
    }

    private func persist() {
        guard !isLoading else { return }
        store.save(Model(timers: timers, alarms: alarms, pomodoro: pomodoro, stopwatch: stopwatch))
    }

    // MARK: - Redraw registration (hub-owned, torn down with the tab)

    /// Called by the Time tab on appear and by the pill while a countdown is
    /// visible. Refcounted so both can ask independently.
    private var redrawConsumers = 0
    func addRedrawConsumer() {
        redrawConsumers += 1
        guard redrawConsumers == 1 else { return }
        redrawToken = WidgetPollingHub.shared.register(label: "time-redraw", interval: 1.0) { [weak self] in
            guard let self else { return }
            self.redrawTick &+= 1
            self.publishClaims()
        }
    }
    func removeRedrawConsumer() {
        redrawConsumers = max(0, redrawConsumers - 1)
        guard redrawConsumers == 0 else { return }
        WidgetPollingHub.shared.unregister(redrawToken)
        redrawToken = nil
    }

    // MARK: - Timers

    func addTimer(label: String, duration: TimeInterval) {
        let t = NBTimer(label: label.isEmpty ? "Timer" : label,
                        duration: duration,
                        endsAt: Date().addingTimeInterval(duration))
        timers.append(t)
        NotchArbiter.shared.flash("\(t.label) started", symbol: "timer", module: .time,
                                  detail: Self.format(duration))
    }

    func togglePause(_ id: UUID) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        if let remaining = timers[i].pausedRemaining {
            timers[i].endsAt = Date().addingTimeInterval(remaining)
            timers[i].pausedRemaining = nil
        } else {
            timers[i].pausedRemaining = timers[i].remaining
        }
    }

    func addMinute(_ id: UUID, seconds: TimeInterval = 60) {
        guard let i = timers.firstIndex(where: { $0.id == id }) else { return }
        if let paused = timers[i].pausedRemaining {
            timers[i].pausedRemaining = paused + seconds
        } else {
            timers[i].endsAt = timers[i].endsAt.addingTimeInterval(seconds)
        }
        timers[i].duration += seconds
    }

    func removeTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
        NotchArbiter.shared.withdraw("timer-\(id.uuidString)")
    }

    // MARK: - Alarms

    func addAlarm(_ alarm: NBAlarm) { alarms.append(alarm) }
    func removeAlarm(_ id: UUID) { alarms.removeAll { $0.id == id } }
    func toggleAlarm(_ id: UUID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].isEnabled.toggle()
        alarms[i].snoozedUntil = nil
    }
    func snooze(_ id: UUID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].snoozedUntil = Date().addingTimeInterval(Double(alarms[i].snoozeMinutes) * 60)
    }

    // MARK: - Pomodoro

    func startPomodoro() {
        var p = pomodoro
        if p.phase == .idle { p.phase = .focus }
        p.pausedRemaining = nil
        p.endsAt = Date().addingTimeInterval(p.phaseLength)
        pomodoro = p
    }
    func togglePomodoroPause() {
        var p = pomodoro
        guard p.phase != .idle else { startPomodoro(); return }
        if let remaining = p.pausedRemaining {
            p.endsAt = Date().addingTimeInterval(remaining)
            p.pausedRemaining = nil
        } else {
            p.pausedRemaining = p.remaining
        }
        pomodoro = p
    }
    func resetPomodoro() {
        var p = pomodoro
        p.phase = .idle
        p.pausedRemaining = nil
        p.endsAt = .distantPast
        p.completedFocusSessions = 0
        pomodoro = p
        NotchArbiter.shared.withdraw("pomodoro")
    }
    func skipPomodoroPhase() { advancePomodoro(completed: false) }

    private func advancePomodoro(completed: Bool) {
        var p = pomodoro
        switch p.phase {
        case .focus:
            if completed { p.completedFocusSessions += 1 }
            p.phase = (p.completedFocusSessions % p.sessionsBeforeLongBreak == 0 && p.completedFocusSessions > 0)
                ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            p.phase = .focus
        case .idle:
            p.phase = .focus
        }
        p.pausedRemaining = nil
        p.endsAt = Date().addingTimeInterval(p.phaseLength)
        pomodoro = p
    }

    // MARK: - Stopwatch

    func startStopwatch() {
        guard !stopwatch.isRunning else { return }
        stopwatch.startedAt = Date()
    }
    func stopStopwatch() {
        guard let started = stopwatch.startedAt else { return }
        stopwatch.accumulated += Date().timeIntervalSince(started)
        stopwatch.startedAt = nil
    }
    func lapStopwatch() { stopwatch.laps.insert(stopwatch.elapsed, at: 0) }
    func resetStopwatch() { stopwatch = StopwatchState() }

    // MARK: - Deadline scheduling

    /// Rebuilds the set of one-shot wakeups so that exactly one exists per
    /// running item, armed for that item's deadline. Cheap to call often.
    private func rearm() {
        guard !isLoading else { return }
        for (_, source) in deadlineSources { source.cancel() }
        deadlineSources.removeAll()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        for timer in timers where !timer.isPaused && !timer.isFinished {
            // assumeIsolated rather than a Task hop: armDeadline schedules on
            // the main queue, so we are already on the main actor when this runs,
            // and an async hop would let a second's worth of UI render with a
            // finished timer still showing.
            armDeadline(id: timer.id, at: timer.endsAt) { [weak self] in
                MainActor.assumeIsolated { self?.timerFired(timer.id) }
            }
            scheduleNotification(id: timer.id.uuidString, title: timer.label,
                                 body: "Timer finished", at: timer.endsAt, sound: timer.soundName)
        }
        for alarm in alarms {
            guard let fire = alarm.nextFire() else { continue }
            armDeadline(id: alarm.id, at: fire) { [weak self] in
                MainActor.assumeIsolated { self?.alarmFired(alarm.id) }
            }
            scheduleNotification(id: alarm.id.uuidString, title: alarm.label.isEmpty ? "Alarm" : alarm.label,
                                 body: Self.clockString(hour: alarm.hour, minute: alarm.minute),
                                 at: fire, sound: alarm.soundName)
        }
        if pomodoro.isRunning {
            armDeadline(id: pomodoroID, at: pomodoro.endsAt) { [weak self] in
                MainActor.assumeIsolated { self?.pomodoroFired() }
            }
            scheduleNotification(id: pomodoroID.uuidString,
                                 title: pomodoro.phase == .focus ? "Focus complete" : "Break over",
                                 body: pomodoro.phase == .focus ? "Time for a break" : "Back to it",
                                 at: pomodoro.endsAt, sound: "Glass")
        }
        publishClaims()
    }

    /// Fixed sentinel so the pomodoro's one-shot wakeup lives in the same
    /// `deadlineSources` dictionary as the timers' and alarms' without needing a
    /// parallel field.
    private let pomodoroID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func armDeadline(id: UUID, at date: Date, action: @escaping @Sendable () -> Void) {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { DispatchQueue.main.async(execute: action); return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        // No leeway here -- this is the one place in the app where precision
        // actually matters, and it is a single wakeup, not a repeating one.
        source.schedule(deadline: .now() + interval)
        source.setEventHandler { action() }
        source.resume()
        deadlineSources[id] = source
    }

    private func scheduleNotification(id: String, title: String, body: String, at date: Date, sound: String) {
        let interval = date.timeIntervalSinceNow
        guard interval > 0.5 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(sound + ".aiff"))
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Fire handlers

    private func timerFired(_ id: UUID) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        playSound(timer.soundName)
        NotchArbiter.shared.flash("\(timer.label) done", symbol: "bell.fill", module: .time, duration: 5)
        NotchPanelController.shared.expand(selecting: .builtin(.time))
        timers.removeAll { $0.id == id }
    }

    private func alarmFired(_ id: UUID) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        playSound(alarms[i].soundName)
        NotchArbiter.shared.flash(alarms[i].label.isEmpty ? "Alarm" : alarms[i].label,
                                  symbol: "alarm.fill", module: .time, duration: 8)
        NotchPanelController.shared.expand(selecting: .builtin(.time))
        if alarms[i].weekdays.isEmpty {
            alarms[i].isEnabled = false     // one-shot alarms disarm themselves
        }
        alarms[i].snoozedUntil = nil
    }

    private func pomodoroFired() {
        playSound("Glass")
        let finishedFocus = pomodoro.phase == .focus
        advancePomodoro(completed: true)
        NotchArbiter.shared.flash(finishedFocus ? "Focus complete" : "Break over",
                                  symbol: "brain.head.profile", module: .time, duration: 5)
    }

    private func playSound(_ name: String) {
        NSSound(named: name)?.play()
    }

    // MARK: - Tier-1 claims

    /// Anything running is a **persistent** claim: it holds the pill until it
    /// resolves. `rank` is seconds-remaining, which is how the arbiter's generic
    /// "lowest rank wins" rule produces "show the timer closest to finishing"
    /// without the arbiter knowing what a timer is.
    private func publishClaims() {
        guard Settings.shared.data.showTimersInPill else { return }

        var live = Set<String>()
        for timer in timers where !timer.isPaused && !timer.isFinished {
            let id = "timer-\(timer.id.uuidString)"
            live.insert(id)
            NotchArbiter.shared.claim(PillClaim(
                id: id, priority: .persistent, module: .time,
                symbol: "timer", text: Self.format(timer.remaining),
                detail: timer.label, rank: timer.remaining,
                expiresAt: nil, progress: timer.progress))
        }
        if pomodoro.isRunning {
            live.insert("pomodoro")
            NotchArbiter.shared.claim(PillClaim(
                id: "pomodoro", priority: .persistent, module: .time,
                symbol: "brain.head.profile", text: Self.format(pomodoro.remaining),
                detail: pomodoro.phase == .focus ? "Focus" : "Break",
                rank: pomodoro.remaining, expiresAt: nil, progress: pomodoro.progress))
        }
        // Withdraw anything that stopped running since the last publish.
        for key in NotchArbiter.shared.claims.keys
        where (key.hasPrefix("timer-") || key == "pomodoro") && !live.contains(key) {
            NotchArbiter.shared.withdraw(key)
        }
    }

    // MARK: - Formatting

    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    nonisolated static func formatPrecise(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let m = Int(total) / 60, s = Int(total) % 60, cs = Int((total - floor(total)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    nonisolated static func clockString(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Sounds shipped with macOS; using system sounds avoids bundling audio and
    /// keeps the app binary small.
    nonisolated static let availableSounds = ["Glass", "Ping", "Submarine", "Blow", "Bottle", "Funk", "Hero", "Morse", "Purr", "Sosumi", "Tink"]
}

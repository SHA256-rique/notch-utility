import SwiftUI

/// Time: timers, alarms, pomodoro and stopwatch behind one tab, as the brief
/// specifies. They are four views over one engine, not four features.
struct TimeTabView: View {
    enum Section: String, CaseIterable, Identifiable {
        case timers = "Timers", alarms = "Alarms", pomodoro = "Pomodoro", stopwatch = "Stopwatch"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .timers: return "timer"
            case .alarms: return "alarm"
            case .pomodoro: return "brain.head.profile"
            case .stopwatch: return "stopwatch"
            }
        }
    }

    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var engine = TimeEngine.shared
    @State private var section: Section = .timers

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.symbol).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Group {
                switch section {
                case .timers:    TimersSection()
                case .alarms:    AlarmsSection()
                case .pomodoro:  PomodoroSection()
                case .stopwatch: StopwatchSection()
                }
            }
            .animation(Motion.tabSwitch, value: section)
        }
        // The 1Hz redraw tick is a hub registration, released the moment this
        // tab closes. The countdowns stay *correct* regardless -- they are
        // computed from absolute deadlines -- they just stop re-rendering.
        .onAppear { engine.addRedrawConsumer() }
        .onDisappear { engine.removeRedrawConsumer() }
    }
}

// MARK: - Timers

struct TimersSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var engine = TimeEngine.shared
    @State private var label = ""
    @State private var minutes = "10"

    private let presets: [(String, TimeInterval)] = [
        ("1m", 60), ("5m", 300), ("10m", 600), ("25m", 1500), ("1h", 3600)
    ]

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                NBTextField(placeholder: "Label (e.g. Pasta)", text: $label)
                    .frame(maxWidth: .infinity)
                NBTextField(placeholder: "Min", text: $minutes) { start() }
                    .frame(width: 52)
                Button {
                    start()
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.time), filled: true))
            }
            .padding(.horizontal, 12)

            HStack(spacing: 5) {
                ForEach(presets, id: \.0) { preset in
                    Button(preset.0) {
                        engine.addTimer(label: label.isEmpty ? preset.0 + " timer" : label,
                                        duration: preset.1)
                        label = ""
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            if engine.timers.isEmpty {
                NBEmptyState(symbol: "timer", title: "No timers running",
                             subtitle: "Several can run at once — each keeps its own label and shows up in the notch.")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        // Closest to finishing first: the same ordering the pill
                        // uses, so what you see here matches what the notch shows.
                        ForEach(engine.timers.sorted { $0.remaining < $1.remaining }) { timer in
                            timerRow(timer, theme: theme)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func start() {
        guard let value = Double(minutes.trimmingCharacters(in: .whitespaces)), value > 0 else { return }
        engine.addTimer(label: label, duration: value * 60)
        label = ""
    }

    private func timerRow(_ timer: NBTimer, theme: Theme) -> some View {
        NBCard(tint: .time, padding: 9) {
            HStack(spacing: 10) {
                ZStack {
                    NBRing(progress: timer.progress, tint: theme.tint(.time),
                           lineWidth: 3, glow: theme.glowRadius(4))
                    Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                        .font(.system(size: 9)).foregroundStyle(theme.tint(.time))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text(timer.label).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryText).lineLimit(1)
                    Text(TimeEngine.format(timer.remaining))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(timer.isPaused ? theme.secondaryText : theme.primaryText)
                }
                Spacer()
                Button("+1m") { engine.addMinute(timer.id) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
                Button {
                    engine.togglePause(timer.id)
                } label: {
                    Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
                Button {
                    engine.removeTimer(timer.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
            }
        }
    }
}

// MARK: - Alarms

struct AlarmsSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var engine = TimeEngine.shared
    @State private var isAdding = false
    @State private var draft = NBAlarm(label: "", hour: 8, minute: 0)

    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 8) {
            HStack {
                NBSectionHeader(title: "Alarms")
                Button(isAdding ? "Cancel" : "New alarm") {
                    withAnimation(Motion.sheet) {
                        isAdding.toggle()
                        if isAdding { draft = NBAlarm(label: "", hour: 8, minute: 0) }
                    }
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
            }
            .padding(.horizontal, 12)

            if isAdding { editor(theme) }

            if engine.alarms.isEmpty && !isAdding {
                NBEmptyState(symbol: "alarm", title: "No alarms",
                             subtitle: "Wall-clock alarms with repeat days, a custom label and a snooze.")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(engine.alarms) { alarm in alarmRow(alarm, theme: theme) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
    }

    private func editor(_ theme: Theme) -> some View {
        NBCard(tint: .time, padding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Stepper(value: $draft.hour, in: 0...23) {
                        Text(String(format: "%02d", draft.hour))
                            .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 92)
                    Text(":").font(.system(size: 18, weight: .semibold))
                    Stepper(value: $draft.minute, in: 0...59) {
                        Text(String(format: "%02d", draft.minute))
                            .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 92)
                    Spacer()
                }
                NBTextField(placeholder: "Label", text: $draft.label)

                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { weekday in
                        Button {
                            if draft.weekdays.contains(weekday) { draft.weekdays.remove(weekday) }
                            else { draft.weekdays.insert(weekday) }
                        } label: {
                            Text(weekdaySymbols[weekday - 1])
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(draft.weekdays.contains(weekday)
                                                          ? theme.tint(.time).opacity(0.8)
                                                          : Color.white.opacity(0.08)))
                                .foregroundStyle(draft.weekdays.contains(weekday) ? .black : theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Picker("", selection: $draft.soundName) {
                        ForEach(TimeEngine.availableSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                }

                HStack {
                    Text(draft.weekdays.isEmpty ? "Rings once, at the next occurrence" : "Repeats weekly")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button("Add alarm") {
                        engine.addAlarm(draft)
                        withAnimation(Motion.sheet) { isAdding = false }
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.time), filled: true, compact: true))
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func alarmRow(_ alarm: NBAlarm, theme: Theme) -> some View {
        NBCard(tint: .time, padding: 9) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(TimeEngine.clockString(hour: alarm.hour, minute: alarm.minute))
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(alarm.isEnabled ? theme.primaryText : theme.secondaryText)
                    HStack(spacing: 4) {
                        if !alarm.label.isEmpty {
                            Text(alarm.label).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        }
                        Text(repeatDescription(alarm))
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                }
                Spacer()
                if alarm.snoozedUntil != nil {
                    Text("Snoozed").font(.system(size: 9))
                        .foregroundStyle(theme.tint(.time))
                }
                Button("Snooze") { engine.snooze(alarm.id) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
                Toggle("", isOn: Binding(get: { alarm.isEnabled },
                                         set: { _ in engine.toggleAlarm(alarm.id) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Button {
                    engine.removeAlarm(alarm.id)
                } label: { Image(systemName: "trash").font(.system(size: 9)) }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
            }
        }
    }

    private func repeatDescription(_ alarm: NBAlarm) -> String {
        guard !alarm.weekdays.isEmpty else {
            guard let next = alarm.nextFire() else { return "Off" }
            return next.formatted(.dateTime.weekday(.abbreviated))
        }
        if alarm.weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if alarm.weekdays == [1, 7] { return "Weekends" }
        if alarm.weekdays.count == 7 { return "Every day" }
        return alarm.weekdays.sorted()
            .map { ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][$0 - 1] }
            .joined(separator: " ")
    }
}

// MARK: - Pomodoro

struct PomodoroSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var engine = TimeEngine.shared

    var body: some View {
        let theme = themes.theme
        let p = engine.pomodoro
        VStack(spacing: 12) {
            ZStack {
                NBRing(progress: p.progress,
                       tint: p.phase == .focus ? theme.tint(.time) : theme.tint(.snippets),
                       lineWidth: 8, glow: theme.glowRadius(8))
                VStack(spacing: 2) {
                    Text(p.phase == .idle ? TimeEngine.format(p.phaseLength) : TimeEngine.format(p.remaining))
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(theme.primaryText)
                    Text(phaseLabel(p))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(width: 130, height: 130)
            .padding(.top, 6)

            HStack(spacing: 8) {
                Button {
                    engine.togglePomodoroPause()
                } label: {
                    Image(systemName: p.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.time), filled: true))

                Button {
                    engine.skipPomodoroPhase()
                } label: { Image(systemName: "forward.end.fill").font(.system(size: 11)) }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.time)))

                Button {
                    engine.resetPomodoro()
                } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 11)) }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText))
            }

            HStack(spacing: 5) {
                ForEach(0..<p.sessionsBeforeLongBreak, id: \.self) { index in
                    Circle()
                        .fill(index < (p.completedFocusSessions % p.sessionsBeforeLongBreak)
                              || (p.completedFocusSessions > 0 && p.completedFocusSessions % p.sessionsBeforeLongBreak == 0)
                              ? theme.tint(.time) : Color.white.opacity(0.15))
                        .frame(width: 7, height: 7)
                }
                Text("\(p.completedFocusSessions) done")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .padding(.leading, 4)
            }

            HStack(spacing: 12) {
                lengthStepper("Focus", value: Binding(
                    get: { engine.pomodoro.focusMinutes },
                    set: { engine.pomodoro.focusMinutes = $0 }), theme: theme)
                lengthStepper("Break", value: Binding(
                    get: { engine.pomodoro.shortBreakMinutes },
                    set: { engine.pomodoro.shortBreakMinutes = $0 }), theme: theme)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    private func phaseLabel(_ p: PomodoroState) -> String {
        switch p.phase {
        case .focus: return "FOCUS"
        case .shortBreak: return "SHORT BREAK"
        case .longBreak: return "LONG BREAK"
        case .idle: return "READY"
        }
    }

    private func lengthStepper(_ title: String, value: Binding<Int>, theme: Theme) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            Stepper(value: value, in: 1...120) {
                Text("\(value.wrappedValue)m").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.primaryText).monospacedDigit()
            }
            .frame(width: 74)
        }
    }
}

// MARK: - Stopwatch

struct StopwatchSection: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var engine = TimeEngine.shared

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 10) {
            Text(TimeEngine.formatPrecise(engine.stopwatch.elapsed))
                .font(.system(size: 36, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.primaryText)
                .padding(.top, 14)

            HStack(spacing: 8) {
                Button(engine.stopwatch.isRunning ? "Stop" : "Start") {
                    engine.stopwatch.isRunning ? engine.stopStopwatch() : engine.startStopwatch()
                }
                .buttonStyle(NBButtonStyle(tint: engine.stopwatch.isRunning ? .orange : theme.tint(.time), filled: true))

                Button("Lap") { engine.lapStopwatch() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.time)))
                    .disabled(!engine.stopwatch.isRunning)

                Button("Reset") { engine.resetStopwatch() }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText))
            }

            if engine.stopwatch.laps.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(engine.stopwatch.laps.enumerated()), id: \.offset) { index, lap in
                            HStack {
                                Text("Lap \(engine.stopwatch.laps.count - index)")
                                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                                Spacer()
                                Text(TimeEngine.formatPrecise(lap))
                                    .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                                    .foregroundStyle(theme.primaryText)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
        }
    }
}

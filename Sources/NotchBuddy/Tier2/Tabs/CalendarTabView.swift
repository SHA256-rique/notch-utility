import SwiftUI
import AppKit

/// Calendar: an agenda for the immediate glance and a month grid for the wider
/// look, over Apple's EventKit and Google's API together.
///
/// The two views are not two features. They are two zoom levels on one merged
/// event list, which is why `CalendarEvent` exists -- neither view knows or
/// cares which source a row came from.
struct CalendarTabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case agenda = "Up next", month = "Month"
        var id: String { rawValue }
        var symbol: String { self == .agenda ? "list.bullet" : "calendar" }
    }

    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings
    @StateObject private var apple = AppleCalendarService()
    @StateObject private var google = GoogleCalendarService()

    @State private var mode: Mode = .agenda
    @State private var visibleMonth = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay: Date?

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            header(theme)

            switch mode {
            case .agenda: agenda(theme)
            case .month:  month(theme)
            }
        }
        .onAppear {
            applyWindow()
            apple.activate()
            google.activate()
        }
        .onDisappear {
            apple.deactivate()
            google.deactivate()
        }
        .onChange(of: mode) { _, _ in applyWindow() }
        .onChange(of: visibleMonth) { _, _ in applyWindow() }
    }

    // MARK: - Merged events

    /// Both sources, interleaved by start time.
    ///
    /// Deduplication is deliberately *not* attempted. The same meeting can
    /// legitimately exist in two accounts with different titles, and matching on
    /// fuzzy title-and-time would sometimes hide a real second event -- a worse
    /// failure than showing one twice, which the source badge at least explains.
    private var events: [CalendarEvent] {
        (apple.events + google.events).sorted { $0.start < $1.start }
    }

    private var bothSourcesOn: Bool {
        settings.data.calendarUseAppleEventKit && settings.data.calendarUseGoogle
    }

    /// The span each view needs. The agenda wants three days; the month grid
    /// wants the visible month plus the leading and trailing week it renders.
    private func applyWindow() {
        let calendar = Calendar.current
        let start: Date, end: Date
        switch mode {
        case .agenda:
            start = Date()
            end = calendar.date(byAdding: .day, value: 3, to: start) ?? start
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth))
                ?? visibleMonth
            start = calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
            end = calendar.date(byAdding: .day, value: 45, to: monthStart) ?? monthStart
        }
        apple.setWindow(start: start, end: end)
        google.setWindow(start: start, end: end)
    }

    // MARK: - Header

    private func header(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)

            if mode == .month {
                Button {
                    step(-1)
                } label: { Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                Text(Self.monthTitle(visibleMonth))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 104)
                Button {
                    step(1)
                } label: { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                if !Calendar.current.isDate(visibleMonth, equalTo: Date(), toGranularity: .month) {
                    Button("Today") {
                        withAnimation(Motion.sheet) {
                            visibleMonth = Date()
                            selectedDay = Calendar.current.startOfDay(for: Date())
                        }
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                }
            }

            Spacer()
            sourceBadges(theme)
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func step(_ months: Int) {
        withAnimation(Motion.sheet) {
            visibleMonth = Calendar.current.date(byAdding: .month, value: months, to: visibleMonth) ?? visibleMonth
        }
    }

    private func sourceBadges(_ theme: Theme) -> some View {
        HStack(spacing: 4) {
            if settings.data.calendarUseAppleEventKit {
                badge("applelogo", ok: apple.access == .granted, theme: theme,
                      help: apple.access == .granted ? "Apple Calendar connected"
                                                     : "Apple Calendar access not granted")
            }
            if settings.data.calendarUseGoogle {
                badge("globe", ok: google.state == .ready, theme: theme,
                      help: Self.describe(google.state))
            }
            Button {
                apple.reload()
                google.reload()
            } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9)) }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                .help("Refresh")
        }
    }

    private func badge(_ symbol: String, ok: Bool, theme: Theme, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9))
            .foregroundStyle(ok ? theme.tint(.calendar) : theme.secondaryText.opacity(0.5))
            .help(help)
    }

    private static func describe(_ state: GoogleCalendarService.State) -> String {
        switch state {
        case .off:          return "Google Calendar is off"
        case .needsSignIn:  return "Google Calendar needs sign-in"
        case .signingIn:    return "Signing in to Google…"
        case .ready:        return "Google Calendar connected"
        case .failed(let m): return m
        }
    }

    // MARK: - Agenda

    @ViewBuilder
    private func agenda(_ theme: Theme) -> some View {
        let upcoming = events
            .filter { $0.end > Date() }
            .filter { !$0.isAllDay || Calendar.current.isDateInToday($0.start) }
            .prefix(30)

        if let prompt = connectionPrompt(theme) {
            prompt
        } else if upcoming.isEmpty {
            NBEmptyState(symbol: "calendar", title: "Nothing in the next three days")
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(upcoming)) { event in
                        agendaRow(event, theme: theme)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func agendaRow(_ event: CalendarEvent, theme: Theme) -> some View {
        let tint = event.colour ?? theme.tint(.calendar)
        return NBCard(tint: .calendar, padding: 8) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(event.title)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                            .foregroundStyle(theme.primaryText)
                        if bothSourcesOn {
                            Image(systemName: event.origin.symbol)
                                .font(.system(size: 7))
                                .foregroundStyle(theme.secondaryText)
                                .help(event.origin.name)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(Self.timeDescription(event))
                        if !event.location.isEmpty {
                            Text("·"); Text(event.location).lineLimit(1)
                        }
                    }
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Text(Self.relative(event.start))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = event.openURL { NSWorkspace.shared.open(url) } }
    }

    // MARK: - Month

    @ViewBuilder
    private func month(_ theme: Theme) -> some View {
        let calendar = Calendar.current
        let grid = Self.monthGrid(for: visibleMonth, calendar: calendar)
        let monthOf = calendar.component(.month, from: visibleMonth)

        VStack(spacing: 5) {
            // Weekday header, rotated to the user's first weekday. Hardcoding
            // Monday or Sunday is wrong for half the world.
            HStack(spacing: 3) {
                ForEach(Self.weekdaySymbols(calendar), id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)

            VStack(spacing: 3) {
                ForEach(Array(grid.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 3) {
                        ForEach(week, id: \.self) { day in
                            dayCell(day,
                                    inMonth: calendar.component(.month, from: day) == monthOf,
                                    theme: theme)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)

            if let selectedDay {
                selectedDayList(selectedDay, theme: theme)
            } else {
                Text("Pick a day to see its events.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 8)
    }

    private func dayCell(_ day: Date, inMonth: Bool, theme: Theme) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let dayEvents = events.filter { $0.occupies(day: day) }

        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 11, weight: isToday ? .bold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(inMonth ? (isToday ? theme.tint(.calendar) : theme.primaryText)
                                         : theme.secondaryText.opacity(0.45))

            // Up to three dots, then a "+". Counting past three in a 30pt cell
            // is not something anyone does at a glance, and the dots are there
            // to say "this day is busy", not to be enumerated.
            HStack(spacing: 2) {
                ForEach(Array(dayEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                    Circle()
                        .fill(event.colour ?? theme.tint(.calendar))
                        .frame(width: 3.5, height: 3.5)
                }
                if dayEvents.count > 3 {
                    Text("+")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.tint(.calendar).opacity(0.22)
                      : (isToday ? theme.tint(.calendar).opacity(0.10) : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isToday ? theme.tint(.calendar).opacity(0.5) : Color.clear,
                                lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Motion.tabSwitch) {
                selectedDay = isSelected ? nil : calendar.startOfDay(for: day)
            }
        }
    }

    private func selectedDayList(_ day: Date, theme: Theme) -> some View {
        let dayEvents = events.filter { $0.occupies(day: day) }.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            return $0.start < $1.start
        }
        return VStack(alignment: .leading, spacing: 4) {
            NBSectionHeader(title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                            trailing: dayEvents.isEmpty ? "free" : "\(dayEvents.count)")
                .padding(.horizontal, 12)

            if dayEvents.isEmpty {
                Text("Nothing scheduled.")
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(dayEvents) { event in
                            HStack(spacing: 7) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(event.colour ?? theme.tint(.calendar))
                                    .frame(width: 2.5, height: 20)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(event.title)
                                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                                        .foregroundStyle(theme.primaryText)
                                    Text(Self.timeDescription(event))
                                        .font(.system(size: 8))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                Spacer()
                                if bothSourcesOn {
                                    Image(systemName: event.origin.symbol)
                                        .font(.system(size: 7))
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardBackground))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let url = event.openURL { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 110)
            }
        }
    }

    // MARK: - Connection prompts

    /// Shown in place of the agenda when neither source can produce anything.
    /// If one source is working the prompt is suppressed -- half a calendar is
    /// still a calendar, and a full-height "connect something" panel over a
    /// working Apple agenda would be nonsense.
    @ViewBuilder
    private func connectionPrompt(_ theme: Theme) -> (some View)? {
        let appleUsable = settings.data.calendarUseAppleEventKit && apple.access == .granted
        let googleUsable = settings.data.calendarUseGoogle && google.state == .ready

        if !appleUsable && !googleUsable {
            VStack(spacing: 10) {
                NBEmptyState(
                    symbol: "calendar.badge.plus",
                    title: "No calendar connected",
                    subtitle: "Use the Mac's own calendars, link Google directly, or both.")
                    .frame(maxHeight: 130)

                HStack(spacing: 8) {
                    if settings.data.calendarUseAppleEventKit && apple.access == .denied {
                        Button("Open Privacy settings") {
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                    } else if !settings.data.calendarUseAppleEventKit {
                        Button("Use Apple Calendar") {
                            settings.data.calendarUseAppleEventKit = true
                            apple.activate()
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                    }

                    GoogleConnectButton(service: google)
                }

                if case .failed(let message) = google.state {
                    Text(message)
                        .font(.system(size: 9)).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        } else {
            nil as EmptyView?
        }
    }

    // MARK: - Formatting

    /// Six rows of seven days covering the month, padded out to whole weeks in
    /// the user's own calendar.
    static func monthGrid(for date: Date, calendar: Calendar) -> [[Date]] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date))
        else { return [] }

        let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
        // Distance back to the first day of that week, honouring firstWeekday.
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart)
        else { return [] }

        let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        // Always whole weeks, and always enough of them: a 31-day month starting
        // on the last day of a week needs six rows, a 28-day February starting on
        // the first needs four.
        let weeks = Int(ceil(Double(leading + daysInMonth) / 7.0))

        return (0..<weeks).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: gridStart)
            }
        }
    }

    static func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    static func timeDescription(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(event.start)
            ? "" : event.start.formatted(.dateTime.weekday(.abbreviated)) + " "
        return "\(day)\(start) – \(end)"
    }

    static func relative(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "now" }
        if interval < 3600 { return "in \(Int(interval / 60))m" }
        if interval < 86400 { return "in \(Int(interval / 3600))h" }
        return "in \(Int(interval / 86400))d"
    }
}

/// Sign-in/out for Google, shared by the calendar tab and Settings so the two
/// cannot drift into disagreeing about what state the connection is in.
struct GoogleConnectButton: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings
    @ObservedObject var service: GoogleCalendarService

    var body: some View {
        let theme = themes.theme
        switch service.state {
        case .signingIn:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Waiting for your browser…")
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }
        case .ready:
            HStack(spacing: 5) {
                Label("Google linked", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                Button("Disconnect") { service.signOut() }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
            }
        case .off, .needsSignIn, .failed:
            Button("Link Google Calendar") {
                settings.data.calendarUseGoogle = true
                service.signIn()
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), filled: true, compact: true))
            .disabled(settings.data.googleOAuthClientID.isEmpty)
            .help(settings.data.googleOAuthClientID.isEmpty
                  ? "Add an OAuth client ID in Settings → Widgets first"
                  : "Opens your browser to sign in")
        }
    }
}

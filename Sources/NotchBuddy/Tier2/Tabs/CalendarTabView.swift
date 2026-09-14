import SwiftUI
import EventKit

/// Calendar: an "up next" glance backed by EventKit.
///
/// ## The lifecycle point
/// `EKEventStore` is not free. Instantiating one opens a connection to the
/// calendar daemon and pulls indexes into the process. An app in this category
/// that creates the store at launch pays that cost for every user, forever,
/// including the ones who never open the Calendar tab.
///
/// So the store is created in `activate()` -- called from `.onAppear` -- and
/// dropped entirely in `deactivate()`. The permission prompt therefore also
/// only appears when the user opens the tab, which is the moment it makes sense
/// to them, rather than at first launch alongside three other prompts.
@MainActor
final class CalendarService: ObservableObject {
    enum Access: Equatable { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var isLoading = false

    private var store: EKEventStore?
    private var observer: NSObjectProtocol?

    func activate() {
        let store = EKEventStore()
        self.store = store

        // macOS 14 split calendar access into full/write-only. Request the
        // narrower "full access" only, and only for events -- reminders are a
        // separate grant we do not ask for unless the feature needs it.
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor in
                    self?.access = granted ? .granted : .denied
                    if granted { self?.reload() }
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.access = granted ? .granted : .denied
                    if granted { self?.reload() }
                }
            }
        }

        // EventKit posts this when anything changes. Event-driven, so no polling
        // even while the tab is open.
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reload() } }
    }

    func deactivate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        events = []
        store = nil          // releases the daemon connection and its indexes
    }

    func reload() {
        guard let store else { return }
        isLoading = true
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { !$0.isAllDay || Calendar.current.isDateInToday($0.startDate) }
            .sorted { $0.startDate < $1.startDate }
        events = Array(found.prefix(25))
        isLoading = false
    }
}

struct CalendarTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var service = CalendarService()

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            HStack {
                NBSectionHeader(title: "Up next")
                if service.access == .granted {
                    Button("Refresh") { service.reload() }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            switch service.access {
            case .unknown:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                NBEmptyState(symbol: "calendar.badge.exclamationmark",
                             title: "Calendar access not granted",
                             subtitle: "System Settings → Privacy & Security → Calendars. NotchBuddy only reads events, and only while this tab is open.")
            case .granted:
                if service.events.isEmpty {
                    NBEmptyState(symbol: "calendar", title: "Nothing in the next three days")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(service.events, id: \.eventIdentifier) { event in
                                row(event, theme: theme)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
            }
        }
        .onAppear { service.activate() }
        .onDisappear { service.deactivate() }
    }

    private func row(_ event: EKEvent, theme: Theme) -> some View {
        let tint = event.calendar?.cgColor.map { Color(cgColor: $0) } ?? theme.tint(.calendar)
        return NBCard(tint: .calendar, padding: 8) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title ?? "Untitled")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(theme.primaryText)
                    HStack(spacing: 5) {
                        Text(timeDescription(event))
                        if let location = event.location, !location.isEmpty {
                            Text("·"); Text(location).lineLimit(1)
                        }
                    }
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Text(relative(event.startDate))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
    }

    private func timeDescription(_ event: EKEvent) -> String {
        if event.isAllDay { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        let day = Calendar.current.isDateInToday(event.startDate)
            ? "" : event.startDate.formatted(.dateTime.weekday(.abbreviated)) + " "
        return "\(day)\(start) – \(end)"
    }

    private func relative(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval < 0 { return "now" }
        if interval < 3600 { return "in \(Int(interval / 60))m" }
        if interval < 86400 { return "in \(Int(interval / 3600))h" }
        return "in \(Int(interval / 86400))d"
    }
}

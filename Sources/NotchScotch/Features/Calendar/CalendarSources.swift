import Foundation
import EventKit
import SwiftUI
import Combine

/// One event, whatever it came from.
///
/// The agenda and the month grid must not know whether a row arrived via
/// EventKit or Google's REST API, or every feature added to the calendar would
/// have to be written twice. `origin` exists purely so the UI can show a small
/// provenance badge when both sources are on -- which matters, because seeing
/// the same meeting twice is confusing and seeing it once is only reassuring if
/// you know which account it is from.
struct CalendarEvent: Identifiable, Equatable {
    enum Origin: String {
        case apple, google
        var symbol: String { self == .apple ? "applelogo" : "globe" }
        var name: String { self == .apple ? "Apple Calendar" : "Google Calendar" }
    }

    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String
    let calendarName: String
    let colour: Color?
    let origin: Origin
    /// A link to open the event in its own app or in a browser.
    let openURL: URL?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func occupies(day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return start < dayEnd && end > dayStart
    }
}

// MARK: - Apple

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
final class AppleCalendarService: ObservableObject {
    enum Access: Equatable { case unknown, granted, denied, off }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [CalendarEvent] = []

    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    /// The span the month grid needs, not just the agenda's three days.
    private var windowStart = Date()
    private var windowEnd = Date()

    func activate() {
        guard Settings.shared.data.calendarUseAppleEventKit else {
            access = .off
            return
        }
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

    func setWindow(start: Date, end: Date) {
        guard start != windowStart || end != windowEnd else { return }
        windowStart = start
        windowEnd = end
        reload()
    }

    func reload() {
        guard let store, access == .granted else { return }
        // EventKit refuses predicates longer than four years and gets slow well
        // before that; the month grid never asks for more than one month plus
        // padding, so clamp defensively rather than trusting the caller.
        let start = min(windowStart, Date().addingTimeInterval(-370 * 86_400))
        let end = max(windowEnd, Date().addingTimeInterval(3 * 86_400))
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

        events = store.events(matching: predicate).map { event in
            CalendarEvent(
                id: "apple." + (event.eventIdentifier ?? UUID().uuidString) + ".\(event.startDate.timeIntervalSince1970)",
                title: event.title ?? "Untitled",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location ?? "",
                calendarName: event.calendar?.title ?? "",
                colour: event.calendar?.cgColor.map { Color(cgColor: $0) },
                origin: .apple,
                openURL: nil)
        }
        .sorted { $0.start < $1.start }
    }
}

// MARK: - Google

/// Google Calendar over the REST API, authorised by `GoogleOAuth`.
///
/// ## Why this exists alongside EventKit
/// The obvious answer to "show me my Google calendar" is "add the account in
/// System Settings and let EventKit pick it up". That is a fine answer for
/// people who have already done it, and no answer at all for the people who have
/// not -- it means leaving this app, adding a system-wide account, and granting
/// macOS access to their mail and contacts as a side effect of wanting to see
/// meetings in a notch.
///
/// This talks to Google directly with a read-only calendar scope. Nothing is
/// added to the system, the grant is exactly as wide as the feature, and
/// revoking it is one click in the Google account page.
@MainActor
final class GoogleCalendarService: ObservableObject {
    enum State: Equatable {
        case off
        case needsSignIn
        case signingIn
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var calendarNames: [String] = []

    private var tokens: GoogleOAuth.Tokens?
    private var oauth: GoogleOAuth?
    private var task: Task<Void, Never>?
    private var windowStart = Date()
    private var windowEnd = Date().addingTimeInterval(3 * 86_400)

    static let clientSecretAccount = "google.calendar.clientsecret"

    // MARK: Lifecycle

    func activate() {
        guard Settings.shared.data.calendarUseGoogle else {
            state = .off
            return
        }
        guard Keychain.has(GoogleOAuth.refreshTokenAccount) else {
            state = .needsSignIn
            return
        }
        reload()
    }

    func deactivate() {
        task?.cancel()
        task = nil
        events = []
        // The access token is deliberately dropped rather than cached across
        // tab closes. It is a bearer credential with an hour of life; holding
        // one in memory for a tab nobody has open buys nothing.
        tokens = nil
    }

    func setWindow(start: Date, end: Date) {
        guard start != windowStart || end != windowEnd else { return }
        windowStart = start
        windowEnd = end
        reload()
    }

    // MARK: Sign in / out

    func signIn() {
        let clientID = Settings.shared.data.googleOAuthClientID
        guard !clientID.isEmpty else {
            state = .failed(GoogleOAuth.OAuthError.notConfigured.localizedDescription)
            return
        }
        state = .signingIn
        let secret = Keychain.get(Self.clientSecretAccount) ?? ""
        let flow = GoogleOAuth()
        oauth = flow

        task = Task { [weak self] in
            do {
                let tokens = try await flow.signIn(clientID: clientID, clientSecret: secret)
                if let refresh = tokens.refreshToken {
                    Keychain.set(refresh, for: GoogleOAuth.refreshTokenAccount)
                }
                await MainActor.run {
                    self?.tokens = tokens
                    self?.oauth = nil
                    self?.state = .ready
                }
                await self?.fetch()
            } catch {
                await MainActor.run {
                    self?.oauth = nil
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func signOut() {
        Keychain.delete(GoogleOAuth.refreshTokenAccount)
        tokens = nil
        events = []
        calendarNames = []
        state = .needsSignIn
    }

    func reload() {
        task?.cancel()
        task = Task { [weak self] in await self?.fetch() }
    }

    // MARK: Fetch

    private func fetch() async {
        guard Settings.shared.data.calendarUseGoogle else { return }
        do {
            let token = try await accessToken()
            guard !Task.isCancelled else { return }
            let calendars = try await calendarList(token: token)
            var collected: [CalendarEvent] = []
            var names: [String] = []

            for calendar in calendars {
                try Task.checkCancellation()
                names.append(calendar.summary)
                collected += try await events(in: calendar, token: token)
            }

            await MainActor.run {
                self.events = collected.sorted { $0.start < $1.start }
                self.calendarNames = names
                self.state = .ready
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // A revoked grant is the common failure and deserves the
                // actionable message, not "invalid_grant".
                if error.localizedDescription.contains("invalid_grant") {
                    Keychain.delete(GoogleOAuth.refreshTokenAccount)
                    self.state = .needsSignIn
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func accessToken() async throws -> String {
        if let tokens, tokens.expiresAt > Date() { return tokens.accessToken }
        guard let refresh = Keychain.get(GoogleOAuth.refreshTokenAccount) else {
            throw GoogleOAuth.OAuthError.notConfigured
        }
        let clientID = Settings.shared.data.googleOAuthClientID
        let secret = Keychain.get(Self.clientSecretAccount) ?? ""
        var fresh = try await GoogleOAuth.refresh(refreshToken: refresh,
                                                  clientID: clientID, clientSecret: secret)
        fresh.refreshToken = refresh
        tokens = fresh
        return fresh.accessToken
    }

    private struct GoogleCalendar {
        let id: String
        let summary: String
        let colour: Color?
    }

    private func calendarList(token: String) async throws -> [GoogleCalendar] {
        // `minAccessRole=reader` drops calendars the user cannot even read, and
        // `showHidden` stays false so calendars they have unchecked in Google's
        // own UI stay unchecked here.
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        components.queryItems = [
            URLQueryItem(name: "minAccessRole", value: "reader"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        let json = try await get(components.url!, token: token)
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            guard (item["selected"] as? Bool) ?? true else { return nil }
            return GoogleCalendar(id: id,
                                  summary: (item["summary"] as? String) ?? id,
                                  colour: (item["backgroundColor"] as? String).flatMap(Color.init(hex:)))
        }
    }

    private func events(in calendar: GoogleCalendar, token: String) async throws -> [CalendarEvent] {
        let path = "https://www.googleapis.com/calendar/v3/calendars/"
            + (calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id)
            + "/events"
        var components = URLComponents(string: path)!
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: windowStart)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: windowEnd)),
            // Without singleEvents a recurring meeting comes back once, as a
            // rule, and would need expanding by hand -- including exceptions.
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250")
        ]

        let json = try await get(components.url!, token: token)
        let items = (json["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard (item["status"] as? String) != "cancelled" else { return nil }
            guard let id = item["id"] as? String else { return nil }
            guard let (start, isAllDay) = Self.date(from: item["start"]),
                  let (end, _) = Self.date(from: item["end"]) else { return nil }
            return CalendarEvent(
                id: "google.\(calendar.id).\(id)",
                title: (item["summary"] as? String) ?? "Untitled",
                start: start,
                end: end,
                isAllDay: isAllDay,
                location: (item["location"] as? String) ?? "",
                calendarName: calendar.summary,
                colour: calendar.colour,
                origin: .google,
                openURL: (item["htmlLink"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// Google returns either `dateTime` (timed) or `date` (all-day). The all-day
    /// form is a bare `yyyy-MM-dd` with no zone, and parsing it as UTC shifts it
    /// a day for anyone west of Greenwich -- so it is parsed in the *local*
    /// calendar, which is what "all day" means to the person reading it.
    private static func date(from value: Any?) -> (Date, Bool)? {
        guard let dictionary = value as? [String: Any] else { return nil }
        if let stamp = dictionary["dateTime"] as? String {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = withFraction.date(from: stamp) ?? plain.date(from: stamp) {
                return (date, false)
            }
        }
        if let day = dictionary["date"] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.calendar = Calendar.current
            formatter.timeZone = TimeZone.current
            if let date = formatter.date(from: day) { return (date, true) }
        }
        return nil
    }

    private func get(_ url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((payload?["error"] as? [String: Any])?["message"] as? String)
                ?? "HTTP \(http.statusCode)"
            throw NBError.message(message)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

extension Color {
    /// Parses Google's `#rrggbb` calendar colours.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }
}

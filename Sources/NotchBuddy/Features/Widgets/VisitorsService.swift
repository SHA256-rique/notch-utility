import Foundation
import Combine

/// Backs the Visitors tile: live count, percent change, 30-day sparkline.
///
/// ## Why the source is configurable but the widget is not
/// There is no "visitors API". Plausible, Umami, Fathom, GoatCounter, Matomo and
/// a hand-rolled ClickHouse query all answer the same question with different
/// JSON. Hardcoding one vendor would make this widget useless to everyone else;
/// hardcoding none -- a generic "number from a URL" tile -- was the mistake this
/// replaces.
///
/// The split that works: the *shape* is fixed and literal. This widget always
/// renders a count, a change against the previous period, and thirty daily
/// points. What the user configures is only where those three things are found
/// in their own analytics response, via the same dot-path resolver the custom
/// metric tile uses. Presets fill those paths in for the common tools so that
/// for most users configuration is picking a name from a menu.
@MainActor
final class VisitorsService: ObservableObject {

    struct Reading: Equatable {
        var current: Int
        var previous: Int?
        /// Oldest first, up to 30 points.
        var series: [Double]

        var percentChange: Double? {
            guard let previous, previous > 0 else { return nil }
            return (Double(current) - Double(previous)) / Double(previous) * 100
        }
    }

    enum State: Equatable {
        case unconfigured
        case idle, loading
        case ready(Reading)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastUpdated: Date?

    static let keychainAccount = "visitors.token"

    private var token: UUID?
    private var task: Task<Void, Never>?

    /// Known analytics shapes. Picking one fills the four dot-paths in; the
    /// user can still edit them afterwards, which is what makes this a preset
    /// rather than a hardcoded integration.
    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let hint: String
        let currentPath: String
        let previousPath: String
        let seriesPath: String
        let seriesValuePath: String
    }

    static let presets: [Preset] = [
        Preset(id: "plausible", name: "Plausible",
               hint: "/api/v1/stats/aggregate?site_id=…&period=30d&metrics=visitors&compare=previous_period",
               currentPath: "results.visitors.value",
               previousPath: "results.visitors.comparison_value",
               seriesPath: "results", seriesValuePath: "visitors"),
        Preset(id: "umami", name: "Umami",
               hint: "/api/websites/<id>/stats?startAt=…&endAt=…",
               currentPath: "visitors.value",
               previousPath: "visitors.prev",
               seriesPath: "pageviews", seriesValuePath: "y"),
        Preset(id: "goatcounter", name: "GoatCounter",
               hint: "/api/v0/stats/total?start=…",
               currentPath: "total",
               previousPath: "",
               seriesPath: "hits", seriesValuePath: "count"),
        Preset(id: "custom", name: "Custom JSON",
               hint: "Any endpoint — set the four paths by hand",
               currentPath: "", previousPath: "", seriesPath: "", seriesValuePath: "")
    ]

    // MARK: - Lifecycle

    func activate() {
        let config = Settings.shared.data.visitors
        guard !config.url.isEmpty else {
            state = .unconfigured
            return
        }
        fetch()
        let interval = max(120, config.refreshSeconds)
        token = WidgetPollingHub.shared.register(label: "visitors", interval: interval) { [weak self] in
            Task { @MainActor in self?.fetch() }
        }
    }

    func deactivate() {
        WidgetPollingHub.shared.unregister(token)
        token = nil
        task?.cancel()
        task = nil
    }

    func refresh() { fetch() }

    // MARK: - Fetch

    private func fetch() {
        let config = Settings.shared.data.visitors
        guard let url = URL(string: config.url), url.scheme != nil else {
            state = config.url.isEmpty ? .unconfigured : .failed("Invalid URL")
            return
        }
        task?.cancel()
        if case .ready = state {} else { state = .loading }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (key, value) in config.headers { request.setValue(value, forHTTPHeaderField: key) }
        // An API token is a secret, so it is never in the settings JSON with the
        // rest of the headers -- it is pulled from Keychain at request time and
        // attached here.
        if let bearer = Keychain.get(Self.keychainAccount), !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        task = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard (200..<300).contains(http.statusCode) else {
                    throw NBError.message("HTTP \(http.statusCode)")
                }
                let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                guard !Task.isCancelled else { return }

                guard let current = Self.number(at: config.currentPath, in: json) else {
                    throw NBError.message("No count at \(config.currentPath.isEmpty ? "(root)" : config.currentPath)")
                }
                let previous = Self.number(at: config.previousPath, in: json)
                let series = Self.series(config: config, in: json)

                let reading = Reading(current: Int(current),
                                      previous: previous.map(Int.init),
                                      series: series)
                await MainActor.run {
                    self?.state = .ready(reading)
                    self?.lastUpdated = Date()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let text = (error as? NBError)?.text ?? (error as NSError).localizedDescription
                await MainActor.run { self?.state = .failed(text) }
            }
        }
    }

    // MARK: - Extraction

    nonisolated private static func number(at path: String, in json: Any) -> Double? {
        guard !path.isEmpty, let raw = MetricFetcher.value(at: path, in: json) else { return nil }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    /// Resolves the series path, then each element. Elements may be bare numbers
    /// (`[12, 40, 8]`) or objects (`[{"date":…,"visitors":12}]`) -- both shapes
    /// are common enough that supporting only one would fail half of users.
    nonisolated private static func series(config: VisitorsConfig, in json: Any) -> [Double] {
        guard !config.seriesPath.isEmpty,
              let raw = MetricFetcher.value(at: config.seriesPath, in: json),
              let array = raw as? [Any] else { return [] }
        let points: [Double] = array.compactMap { element in
            if let n = element as? NSNumber { return n.doubleValue }
            if !config.seriesValuePath.isEmpty,
               let nested = MetricFetcher.value(at: config.seriesValuePath, in: element),
               let n = nested as? NSNumber { return n.doubleValue }
            return nil
        }
        // Keep the most recent 30 -- an endpoint returning a year of data should
        // not turn the sparkline into a grey smear.
        return Array(points.suffix(30))
    }

    /// `nonisolated` because it is arithmetic on an Int. Leaving a pure
    /// formatter isolated to the main actor makes it unusable from a test, from
    /// a background summariser, and from anywhere else it is obviously safe.
    nonisolated static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }
}

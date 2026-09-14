import Foundation
import Combine

/// Generalised "number from an API" widget.
///
/// The brief explicitly asked for the Revenue/Visitors-style stat tiles to be
/// generalised rather than hardcoded to one analytics vendor, and that turns out
/// to be strictly better in every direction: no vendor SDK, no OAuth dance, no
/// per-vendor breakage, and it works for a user's own internal endpoint just as
/// well as for a SaaS dashboard.
///
/// The user supplies a URL, optional headers (where an API token goes), and a
/// dot-path into the JSON response. `data.today.revenue` or `results.0.count`.
///
/// Refresh is hub-registered, so a metric tile stops costing anything the moment
/// its tab closes -- the same contract as every other widget.
@MainActor
final class MetricFetcher: ObservableObject {
    enum State: Equatable {
        case idle, loading
        case value(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastUpdated: Date?

    private var config: CustomTabConfig
    private var token: UUID?
    private var task: Task<Void, Never>?

    init(config: CustomTabConfig) { self.config = config }

    func activate() {
        fetch()
        // Floor of 30s: a user typo of "1" in the refresh field must not turn
        // into a 1-second hammer on someone's API.
        let interval = max(30, config.refreshSeconds)
        token = WidgetPollingHub.shared.register(label: "metric-\(config.title)", interval: interval) { [weak self] in
            Task { @MainActor in self?.fetch() }
        }
    }

    func deactivate() {
        WidgetPollingHub.shared.unregister(token)
        token = nil
        task?.cancel()
        task = nil
    }

    func update(config: CustomTabConfig) {
        self.config = config
        deactivate()
        activate()
    }

    private func fetch() {
        guard let url = URL(string: config.url), url.scheme != nil else {
            state = .failed("Invalid URL")
            return
        }
        task?.cancel()
        if case .value = state {} else { state = .loading }

        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.timeoutInterval = 15
            for (key, value) in config.headers { r.setValue(value, forHTTPHeaderField: key) }
            return r
        }()
        let path = config.jsonPath
        let unit = config.unit

        task = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "metric", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                }
                let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                let extracted = Self.value(at: path, in: json)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if let extracted {
                        self.state = .value(Self.present(extracted) + (unit.isEmpty ? "" : " \(unit)"))
                        self.lastUpdated = Date()
                    } else {
                        self.state = .failed("No value at \(path.isEmpty ? "(root)" : path)")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Dot-path resolver. Numeric components index into arrays, so
    /// `results.0.count` works as well as `data.today.revenue`. An empty path
    /// means "the whole response", which is what you want for an endpoint that
    /// returns a bare number.
    nonisolated static func value(at path: String, in json: Any) -> Any? {
        guard !path.isEmpty else { return json }
        var current: Any? = json
        for component in path.split(separator: ".") {
            if let index = Int(component), let array = current as? [Any] {
                current = array.indices.contains(index) ? array[index] : nil
            } else if let dict = current as? [String: Any] {
                current = dict[String(component)]
            } else {
                return nil
            }
            if current == nil { return nil }
        }
        return current
    }

    nonisolated private static func present(_ value: Any) -> String {
        switch value {
        case let n as NSNumber:
            // Integers should not render as "1234.0"; anything fractional keeps
            // two places. Grouping separators make a revenue figure readable.
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = floor(n.doubleValue) == n.doubleValue ? 0 : 2
            return formatter.string(from: n) ?? "\(n)"
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        default: return String(describing: value)
        }
    }
}

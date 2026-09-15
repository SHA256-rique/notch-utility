import Foundation
import Combine

/// Stripe-backed revenue for the Home grid's Revenue tile.
///
/// ## Why the raw REST API and not stripe-swift
/// Stripe's official Swift package is an iOS *payment collection* SDK -- it
/// exists to render card fields and tokenise them, and it deliberately does not
/// expose the secret-key endpoints this needs. Reading charges is three HTTP
/// requests against a stable, versioned, form-encoded API. Adding a dependency
/// that cannot do the job would be strange even if this app took dependencies.
///
/// ## Why charges rather than the Reporting API
/// `/v1/reporting/report_runs` produces exactly the numbers we want, but it is
/// asynchronous (you poll a job, then download a CSV), is restricted on some
/// account types, and takes minutes to return. A Home tile that is correct
/// tomorrow is not a Home tile. Charges are immediate and their semantics --
/// `paid`, `refunded`, `amount` in minor units -- are unambiguous.
///
/// ## The window
/// Two 30-day windows, current and the one immediately before it, so the percent
/// change compares like with like. The previous window is what makes the number
/// mean anything; "$4,210 this month" alone is a fact, not a signal.
@MainActor
final class StripeClient: ObservableObject {

    struct Summary: Equatable {
        var total: Double            // major units, e.g. dollars
        var previousTotal: Double
        var payingCustomers: Int
        var chargeCount: Int
        var currencyCode: String
        /// Daily totals across the current window, oldest first. Backs the
        /// sparkline in the detail view.
        var daily: [Double]

        var percentChange: Double? {
            guard previousTotal > 0 else { return nil }
            return (total - previousTotal) / previousTotal * 100
        }
    }

    enum State: Equatable {
        case needsKey
        case idle
        case loading
        case ready(Summary)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastUpdated: Date?

    static let keychainAccount = "stripe.secret"
    static let windowDays = 30

    private var token: UUID?
    private var task: Task<Void, Never>?

    // MARK: - Lifecycle

    func activate() {
        guard Keychain.has(Self.keychainAccount) else {
            state = .needsKey
            return
        }
        fetch()
        // Revenue does not change meaningfully minute to minute, and every
        // refresh is several round trips against someone's rate limit. Fifteen
        // minutes, hub-registered like everything else, so it costs nothing at
        // all once the panel closes.
        token = WidgetPollingHub.shared.register(label: "stripe-revenue", interval: 900) { [weak self] in
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
        guard let key = Keychain.get(Self.keychainAccount), !key.isEmpty else {
            state = .needsKey
            return
        }
        let config = Settings.shared.data.stripe
        task?.cancel()
        if case .ready = state {} else { state = .loading }

        task = Task { [weak self] in
            do {
                let now = Date()
                let windowStart = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)
                let previousStart = windowStart.addingTimeInterval(-Double(Self.windowDays) * 86_400)

                // One request range covering both windows, split locally. Two
                // separate paginated fetches would double the round trips for
                // data we are already downloading.
                let charges = try await Self.charges(since: previousStart, key: key, config: config)
                guard !Task.isCancelled else { return }

                let current = charges.filter { $0.created >= windowStart }
                let previous = charges.filter { $0.created >= previousStart && $0.created < windowStart }

                let summary = Summary(
                    total: current.reduce(0) { $0 + $1.majorAmount },
                    previousTotal: previous.reduce(0) { $0 + $1.majorAmount },
                    payingCustomers: Set(current.compactMap(\.customer)).count,
                    chargeCount: current.count,
                    currencyCode: current.first?.currency.uppercased() ?? "USD",
                    daily: Self.dailySeries(current, from: windowStart, days: Self.windowDays))

                await MainActor.run {
                    self?.state = .ready(summary)
                    self?.lastUpdated = Date()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.state = .failed(Self.describe(error)) }
            }
        }
    }

    // MARK: - Stripe API

    struct Charge {
        let created: Date
        let amount: Int          // minor units
        let currency: String
        let customer: String?
        var majorAmount: Double { Double(amount) / Self.minorUnitDivisor(currency) }

        /// Zero-decimal currencies exist and getting this wrong overstates
        /// revenue by 100x. The list is fixed and published by Stripe.
        static func minorUnitDivisor(_ currency: String) -> Double {
            let zeroDecimal: Set<String> = [
                "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga",
                "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"
            ]
            return zeroDecimal.contains(currency.lowercased()) ? 1 : 100
        }
    }

    /// Paginates `/v1/charges`, newest first, stopping at `since`.
    ///
    /// Capped at 10 pages (1,000 charges). An account doing more than that in
    /// 60 days deserves a real analytics tool, and an uncapped loop on a widget
    /// refresh is how you accidentally write a denial-of-service against your
    /// own Stripe account.
    private static func charges(since: Date, key: String, config: StripeConfig) async throws -> [Charge] {
        var collected: [Charge] = []
        var startingAfter: String?
        let base = config.apiBase.hasSuffix("/") ? String(config.apiBase.dropLast()) : config.apiBase

        for _ in 0..<10 {
            var components = URLComponents(string: "\(base)/charges")
            var items = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "created[gte]", value: String(Int(since.timeIntervalSince1970)))
            ]
            if let startingAfter { items.append(URLQueryItem(name: "starting_after", value: startingAfter)) }
            components?.queryItems = items
            guard let url = components?.url else { throw URLError(.badURL) }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            // Pinning the API version means Stripe's next breaking change is a
            // decision we make, not one that arrives on a Tuesday.
            request.setValue("2024-06-20", forHTTPHeaderField: "Stripe-Version")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode != 401 else {
                throw NBError.message("Stripe rejected the key")
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = ((detail?["error"] as? [String: Any])?["message"] as? String)
                    ?? "HTTP \(http.statusCode)"
                throw NBError.message(message)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["data"] as? [[String: Any]] else { break }

            for row in rows {
                guard let created = row["created"] as? TimeInterval,
                      let amount = row["amount"] as? Int else { continue }
                let paid = (row["paid"] as? Bool) ?? false
                let refunded = (row["refunded"] as? Bool) ?? false
                let status = (row["status"] as? String) ?? ""
                // Authorised-but-uncaptured charges are not revenue. Neither are
                // failed ones, which Stripe still returns in this list.
                guard paid, status == "succeeded" else { continue }
                if refunded && !config.includeRefunded { continue }

                // `amount_refunded` handles the partial-refund case, which
                // `refunded: false` does not cover.
                let refundedAmount = (row["amount_refunded"] as? Int) ?? 0
                let net = config.includeRefunded ? amount : max(0, amount - refundedAmount)

                collected.append(Charge(
                    created: Date(timeIntervalSince1970: created),
                    amount: net,
                    currency: (row["currency"] as? String) ?? "usd",
                    customer: row["customer"] as? String))
            }

            let hasMore = (json["has_more"] as? Bool) ?? false
            guard hasMore, let last = rows.last?["id"] as? String else { break }
            startingAfter = last
            try Task.checkCancellation()
        }
        return collected
    }

    /// Buckets charges into one slot per day so the detail view can draw a
    /// sparkline without re-walking the whole list.
    private static func dailySeries(_ charges: [Charge], from start: Date, days: Int) -> [Double] {
        var buckets = [Double](repeating: 0, count: days)
        for charge in charges {
            let offset = Int(charge.created.timeIntervalSince(start) / 86_400)
            guard buckets.indices.contains(offset) else { continue }
            buckets[offset] += charge.majorAmount
        }
        return buckets
    }

    private static func describe(_ error: Error) -> String {
        if let nb = error as? NBError { return nb.text }
        return (error as NSError).localizedDescription
    }

    // MARK: - Formatting

    /// Compact money: `$4.2k` on a tile, full precision in the detail view.
    nonisolated static func compact(_ value: Double, symbol: String) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 { return symbol + String(format: "%.1fM", value / 1_000_000) }
        if magnitude >= 1_000 { return symbol + String(format: "%.1fk", value / 1_000) }
        return symbol + String(format: magnitude < 100 ? "%.2f" : "%.0f", value)
    }

    nonisolated static func full(_ value: Double, currencyCode: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = value >= 1000 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// A plain carrier for a human-readable failure. `NSError` with a custom domain
/// works too, but this keeps the call sites readable.
struct NBError: Error {
    let text: String
    static func message(_ text: String) -> NBError { NBError(text: text) }
}

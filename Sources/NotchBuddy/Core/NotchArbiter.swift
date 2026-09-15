import Foundation
import SwiftUI
import Combine

/// What kind of claim a piece of content has on the collapsed pill.
enum PillPriority: Int, Comparable {
    /// Ambient, always-eligible background info (battery, stats). Loses to
    /// everything else and is what the pill falls back to when nothing else
    /// is happening.
    case ambient = 0
    /// Ongoing, user-initiated state that must stay visible until it resolves:
    /// a running timer, a blocked CLI waiting for approval.
    case persistent = 1
    /// Momentary confirmations: "Copied", "Converted 3 files". Time-limited.
    case transient = 2

    static func < (lhs: PillPriority, rhs: PillPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A single thing that would like to occupy the collapsed pill.
struct PillClaim: Identifiable, Equatable {
    let id: String
    let priority: PillPriority
    let module: ModuleTint
    let symbol: String
    let text: String
    let detail: String?
    /// Lower sorts first among equal-priority persistent claims. For timers this
    /// is seconds-remaining, which implements "show the one closest to
    /// completion" without the arbiter knowing what a timer is.
    let rank: Double
    /// Only meaningful for `.transient`.
    let expiresAt: Date?
    /// Progress 0...1 for a ring/scrubber, if the claim has one.
    let progress: Double?

    static func == (a: PillClaim, b: PillClaim) -> Bool {
        a.id == b.id && a.text == b.text && a.detail == b.detail
            && a.symbol == b.symbol && a.progress == b.progress && a.priority == b.priority
    }
}

/// Implements the arbitration rule from the brief, in one place, so that
/// "what is the notch showing right now" is never an emergent property of
/// whichever subsystem happened to update last.
///
/// The rule:
///   * **Persistent** claims (active timer, agent-approval badge) HOLD the pill
///     until they are withdrawn. A transient pop-in does not evict them from the
///     data model -- it only overlays the display for its lifetime, after which
///     the persistent claim is still there and reappears with no extra work.
///   * **Transient** claims share exactly ONE rotating slot. Newest wins,
///     replacing any current transient. No stacking, no queue -- a queue would
///     mean a burst of five copies makes the notch unusable for ten seconds.
///   * **Ambient** claims are the floor.
///   * Among equal-priority persistent claims, lowest `rank` wins (closest to
///     completion), but `allPersistent` exposes every one of them so the
///     expanded view can show them all at once.
final class NotchArbiter: ObservableObject {
    static let shared = NotchArbiter()

    /// Keyed by claim id so a subsystem can update its own claim idempotently
    /// every tick without needing to diff anything itself.
    @Published private(set) var claims: [String: PillClaim] = [:]
    @Published private(set) var transient: PillClaim?

    private var transientTimer: DispatchSourceTimer?

    private init() {}

    // MARK: - Claim lifecycle

    func claim(_ c: PillClaim) {
        if c.priority == .transient {
            showTransient(c)
        } else {
            // Skip the publish entirely if nothing changed. Tier-1 subsystems
            // re-assert their claim on every event; without this guard a battery
            // notification storm would cause a SwiftUI invalidation storm.
            if claims[c.id] == c { return }
            claims[c.id] = c
        }
    }

    func withdraw(_ id: String) {
        guard claims[id] != nil else { return }
        claims.removeValue(forKey: id)
    }

    // MARK: - Transient slot

    private func showTransient(_ c: PillClaim) {
        transientTimer?.cancel()
        transient = c
        let ttl = max(0.5, (c.expiresAt ?? Date().addingTimeInterval(2.2)).timeIntervalSinceNow)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + ttl, leeway: .milliseconds(120))
        t.setEventHandler { [weak self] in
            self?.transient = nil
            self?.transientTimer?.cancel()
            self?.transientTimer = nil
        }
        t.resume()
        transientTimer = t
    }

    /// Cancels the current transient immediately instead of waiting out its TTL.
    /// Used when the panel expands (the toast has served its purpose once the
    /// full UI is on screen) and to reset state between tests.
    func clearTransient() {
        transientTimer?.cancel()
        transientTimer = nil
        transient = nil
    }

    /// Convenience for the many "flash a confirmation" call sites.
    ///
    /// Call sites pass a duration only when the message genuinely needs longer
    /// than usual ("Timer finished" holds for five seconds). Everything else
    /// takes the default, which follows the user's toast-hold preference --
    /// so how long a confirmation lingers is one setting, not thirty literals
    /// scattered through the codebase.
    func flash(_ text: String, symbol: String, module: ModuleTint = .system,
               detail: String? = nil, duration: TimeInterval? = nil) {
        let ttl = duration ?? max(0.8, Settings.shared.data.transientToastSeconds)
        claim(PillClaim(id: "transient",
                        priority: .transient,
                        module: module,
                        symbol: symbol,
                        text: text,
                        detail: detail,
                        rank: 0,
                        expiresAt: Date().addingTimeInterval(ttl),
                        progress: nil))
    }

    // MARK: - Resolution

    /// Every persistent claim, closest-to-completion first. The expanded panel
    /// shows all of these; the pill shows only `.first`.
    var allPersistent: [PillClaim] {
        claims.values.filter { $0.priority == .persistent }.sorted { $0.rank < $1.rank }
    }

    var ambient: [PillClaim] {
        claims.values.filter { $0.priority == .ambient }.sorted { $0.rank < $1.rank }
    }

    /// The single claim the collapsed pill renders as its focal item, when it
    /// has to pick exactly one.
    ///
    /// The pill itself no longer uses this: it draws the persistent claim and
    /// the transient as two layers, so that a toast overlays a running timer
    /// rather than replacing it -- which is what the rule above actually says.
    /// This stays because "what would the notch show if it could show one
    /// thing" is the question the status-bar menu and the tests ask.
    var focus: PillClaim? {
        transient ?? allPersistent.first
    }

    /// True when something genuinely needs attention, which the pill uses to
    /// decide whether to widen out of its resting state at all.
    var hasUrgentContent: Bool {
        transient != nil || !allPersistent.isEmpty
    }
}

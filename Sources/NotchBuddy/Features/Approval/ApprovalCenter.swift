import Foundation
import AppKit
import Combine

/// How a pending approval reached us. The UI never branches on this -- it exists
/// so the *response* can be routed back the way it came, and so the user can see
/// how reliable the detection was.
enum ApprovalTransport: String, Codable {
    /// The CLI's own hook mechanism called us and is blocked waiting on a reply.
    /// Structured, versioned, and exact.
    case hook
    /// We own the pty the CLI is running in and matched a prompt in its output.
    case ownedPTY
    /// We are tailing someone else's output and matched a known prompt pattern.
    case stdoutPattern

    var displayName: String {
        switch self {
        case .hook: return "Hook"
        case .ownedPTY: return "Terminal"
        case .stdoutPattern: return "Output match"
        }
    }
    /// Shown in the approval UI so the user knows how much to trust the parse.
    var confidence: String {
        switch self {
        case .hook: return "Exact"
        case .ownedPTY: return "Exact"
        case .stdoutPattern: return "Best-effort"
        }
    }
}

enum ApprovalDecision: String, Codable {
    case allow, deny, alwaysAllow
}

/// A generalised "something is blocked waiting on a human".
///
/// Deliberately not named or shaped around Claude Code. It carries a tool name,
/// a human-readable prompt, optional detail (a command line, a file path) and a
/// responder closure. Any blocking CLI can be taught to produce one of these
/// without the UI or the arbiter learning anything new.
struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let transport: ApprovalTransport
    /// e.g. "Claude Code"
    let source: String
    /// e.g. "Bash", "Edit", or "" for a generic y/n prompt.
    let toolName: String
    /// The question as the user should read it.
    let prompt: String
    /// The command, diff or path being approved, if there is one.
    let detail: String?
    let createdAt: Date

    /// Where the answer goes. Not part of equality -- closures are not equatable
    /// and two approvals with the same id are the same approval.
    let respond: (ApprovalDecision) -> Void

    static func == (a: PendingApproval, b: PendingApproval) -> Bool { a.id == b.id }

    /// The key used for "always allow" matching. Scoped to source+tool so that
    /// allowing `Read` for Claude Code does not silently allow `Read` for some
    /// other agent.
    var ruleKey: String { "\(source):\(toolName)" }
}

/// The single place approvals live, regardless of how they were detected.
///
/// Responsibilities, kept narrow on purpose:
///   * hold the queue of pending approvals
///   * publish a Tier-1 persistent claim while any are pending
///   * apply the user's "always allow" rules before ever showing UI
///   * route a decision back through whichever transport delivered it
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    @Published private(set) var pending: [PendingApproval] = []
    /// Most recent decisions, for the "recent activity" list in the tab.
    @Published private(set) var recent: [(prompt: String, decision: ApprovalDecision, at: Date)] = []

    private init() {}

    var current: PendingApproval? { pending.first }

    // MARK: - Submission

    /// Called by every detector. Returns immediately; the detector's `respond`
    /// closure is invoked later (possibly synchronously, if a rule matched).
    func submit(_ approval: PendingApproval) {
        // Auto-allow rules are applied before anything is shown, so a user who
        // has said "always allow Read" never sees a badge for it again.
        if Settings.shared.data.approvalAlwaysAllowRules.contains(approval.ruleKey) {
            Log.approval.info("auto-allowing \(approval.ruleKey, privacy: .public) via saved rule")
            approval.respond(.allow)
            record(approval, .allow)
            return
        }

        pending.append(approval)
        publishClaim()

        Log.approval.info("pending approval via \(approval.transport.rawValue, privacy: .public): \(approval.toolName, privacy: .public)")

        // The badge is the notification. We do not steal focus or force the
        // panel open -- that would yank the user out of whatever they are doing,
        // which is exactly the behaviour that makes notch apps annoying. The
        // pill lights up; the user comes to it.
        NSSound(named: "Tink")?.play()
    }

    func resolve(_ approval: PendingApproval, with decision: ApprovalDecision) {
        guard pending.contains(where: { $0.id == approval.id }) else { return }

        if decision == .alwaysAllow {
            var rules = Settings.shared.data.approvalAlwaysAllowRules
            if !rules.contains(approval.ruleKey) {
                rules.append(approval.ruleKey)
                Settings.shared.data.approvalAlwaysAllowRules = rules
            }
        }

        approval.respond(decision)
        pending.removeAll { $0.id == approval.id }
        record(approval, decision)
        publishClaim()

        NotchArbiter.shared.flash(
            decision == .deny ? "Denied" : "Approved",
            symbol: decision == .deny ? "xmark.circle.fill" : "checkmark.circle.fill",
            module: .approval, detail: approval.toolName)
    }

    /// A detector calls this when its side went away (the CLI was killed, the
    /// hook process died) so we do not leave a badge for a question nobody is
    /// waiting on the answer to.
    func withdraw(id: UUID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        publishClaim()
    }

    func clearRule(_ key: String) {
        Settings.shared.data.approvalAlwaysAllowRules.removeAll { $0 == key }
    }

    private func record(_ approval: PendingApproval, _ decision: ApprovalDecision) {
        recent.insert((approval.prompt, decision, Date()), at: 0)
        if recent.count > 20 { recent.removeLast() }
    }

    // MARK: - Tier 1

    /// A blocked CLI is **persistent**: it holds the pill until answered. It
    /// outranks a running timer by getting rank 0 -- nothing is more urgent than
    /// a process that is stopped dead waiting for you.
    private func publishClaim() {
        guard Settings.shared.data.showApprovalsInPill, let first = pending.first else {
            NotchArbiter.shared.withdraw("approval")
            return
        }
        let count = pending.count
        NotchArbiter.shared.claim(PillClaim(
            id: "approval",
            priority: .persistent,
            module: .approval,
            symbol: "hand.raised.fill",
            text: count > 1 ? "\(count) waiting" : (first.toolName.isEmpty ? "Approve?" : first.toolName),
            detail: first.source,
            rank: 0,
            expiresAt: nil,
            progress: nil))
    }
}

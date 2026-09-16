import Foundation

/// **Detection path 3 (preferred over stdout-watching): we own the pty.**
///
/// When the user runs their CLI agent inside NotchScotch's own Terminal tab, we
/// are already on both ends of the connection. That makes this strictly better
/// than watching someone else's window:
///   * We see the byte stream directly -- no screen scraping, no Accessibility
///     permission, no guessing which window is the agent's.
///   * The response is a `write()` into the pty the process is already reading
///     from. There is no synthetic-keystroke posting, no focus stealing, and it
///     works even if the panel is not frontmost.
///
/// It is still **pattern-based**, so it inherits the fragility documented in
/// `ApprovalPatterns` and reports itself as such. The hook transport remains the
/// one to prefer when the CLI supports it; this one's advantage over the stdout
/// fallback is the reliable response channel, not better detection.
@MainActor
final class OwnedPTYDetector {
    static let shared = OwnedPTYDetector()

    private weak var session: TerminalSession?
    private var accumulated = ""
    private var activeApprovalID: UUID?
    /// Debounce: a prompt is often emitted across several writes (box top,
    /// text, box bottom). Matching on the first chunk would fire on a partial
    /// prompt, so we wait for the output to go quiet.
    private var settleWork: DispatchWorkItem?

    private init() {}

    func attach(to session: TerminalSession) {
        self.session = session
        accumulated = ""
        session.outputObserver = { [weak self] data in
            Task { @MainActor in self?.ingest(data) }
        }
        Log.approval.info("owned-pty detector attached")
    }

    func detach() {
        settleWork?.cancel()
        settleWork = nil
        session?.outputObserver = nil
        session = nil
        accumulated = ""
        if let id = activeApprovalID {
            ApprovalCenter.shared.withdraw(id: id)
            activeApprovalID = nil
        }
    }

    private func ingest(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        accumulated += text
        // Bounded: we only ever need the tail to spot a prompt.
        if accumulated.count > 8000 { accumulated = String(accumulated.suffix(4000)) }

        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        settleWork = work
        // 220ms of silence means the CLI has finished drawing and is waiting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func evaluate() {
        guard activeApprovalID == nil, let session else { return }

        // Strip ANSI escapes before matching. A prompt wrapped in colour codes
        // would otherwise never match a plain-text pattern.
        let clean = Self.stripANSI(session.emulator.plainText(lastLines: 40))
        guard let hit = ApprovalPatterns.match(in: clean) else { return }

        let menuStyle = ApprovalPatterns.looksLikeMenu(clean)
        let id = UUID()
        activeApprovalID = id

        let approval = PendingApproval(
            id: id,
            transport: .ownedPTY,
            source: hit.pattern.source,
            toolName: "",
            prompt: Self.promptLine(from: clean) ?? "A command in the Terminal tab is waiting for you.",
            detail: hit.detail,
            createdAt: Date(),
            respond: { [weak self] decision in
                Task { @MainActor in
                    // Write the answer straight into the pty the process reads.
                    session.send(ApprovalPatterns.keystroke(for: decision, menuStyle: menuStyle))
                    self?.activeApprovalID = nil
                    self?.accumulated = ""
                }
            })

        ApprovalCenter.shared.submit(approval)
    }

    /// The last non-empty line that looks like a question -- the best single
    /// line to show the user.
    nonisolated private static func promptLine(from text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "│|╮╯╰╭─"))) }
            .last { $0.contains("?") && $0.count > 8 }
    }

    /// Strips CSI (colour, cursor) and OSC (window title) sequences.
    ///
    /// Note the escape character is interpolated rather than written as `\u{1B}`
    /// inside a raw string literal -- in a raw literal that is six literal
    /// characters, not ESC, which is how the original version of this silently
    /// stripped nothing at all.
    nonisolated static func stripANSI(_ text: String) -> String {
        let esc = "\u{1B}"
        return text
            .replacingOccurrences(of: "\(esc)\\[[0-9;?]*[ -/]*[@-~]",
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: "\(esc)\\][^\u{07}]*(\u{07}|\(esc)\\\\)",
                                  with: "", options: .regularExpression)
    }
}

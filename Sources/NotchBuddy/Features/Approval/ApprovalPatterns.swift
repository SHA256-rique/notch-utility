import Foundation

/// ⚠️ **FRAGILE BY CONSTRUCTION — READ BEFORE EDITING.**
///
/// This file is the pattern list for the *fallback* approval detectors. Matching
/// an interactive CLI's prompt by looking at its output is inherently unstable:
/// the wording, the punctuation, the box-drawing characters and the option
/// numbering are all presentation details that tool authors change freely
/// between releases. They are not an interface and were never meant to be one.
///
/// It is isolated in its own file, with no logic in it, specifically so that
/// updating it after a CLI changes its output is a one-file, no-thinking edit.
///
/// **Prefer the hook transport.** `ApprovalHookServer` is exact, versioned and
/// does not care what the prompt looks like. This list exists only for tools
/// that do not offer a hook, and its findings are surfaced to the user as
/// "best-effort" confidence rather than presented as certainty.
///
/// When adding a pattern:
///   * Anchor on the least decorative part of the sentence.
///   * Avoid matching anything that could appear in ordinary output (a pattern
///     of just "y/n" would fire on documentation about y/n prompts).
///   * Keep it case-insensitive; keep it short.
enum ApprovalPatterns {

    struct Pattern {
        let source: String
        let regex: String
        /// Captures the action being approved, when the prompt includes it.
        let detailRegex: String?
    }

    /// Ordered most-specific first: the first match wins, so a Claude Code
    /// prompt is attributed to Claude Code rather than to the generic y/n rule.
    static let all: [Pattern] = [
        // --- Claude Code -------------------------------------------------
        Pattern(source: "Claude Code",
                regex: #"(?i)do you want to (proceed|make this edit|create|run)"#,
                detailRegex: #"(?m)^\s*[│|]?\s*(?:\$|>)\s*(.+)$"#),
        Pattern(source: "Claude Code",
                regex: #"(?i)\bclaude\b.{0,80}\bneeds? your permission\b"#,
                detailRegex: nil),

        // --- Generic agent / CLI prompts ---------------------------------
        Pattern(source: "CLI",
                regex: #"(?i)\ballow this (tool|command|action)\b"#,
                detailRegex: nil),
        Pattern(source: "CLI",
                regex: #"(?i)\bapprove this (change|command|action)\b"#,
                detailRegex: nil),

        // --- Package managers / VCS --------------------------------------
        Pattern(source: "CLI",
                regex: #"(?i)\bok to proceed\?\s*\(y\)"#,
                detailRegex: nil),
        Pattern(source: "CLI",
                regex: #"(?i)are you sure you want to .{0,60}\?\s*\(?y(es)?/no?\)?"#,
                detailRegex: nil),

        // --- Last resort: a bare y/n at the very end of the output --------
        // Deliberately anchored to end-of-buffer so it only fires when the CLI
        // has genuinely stopped and is waiting, not when "[y/N]" merely appears
        // somewhere in a help listing.
        Pattern(source: "CLI",
                regex: #"(?i)\[\s*y(es)?\s*/\s*n(o)?\s*\]\s*[:?]?\s*$"#,
                detailRegex: nil)
    ]

    /// Sequences to write back into a pty for each decision when the prompt is a
    /// plain interactive question rather than a structured hook.
    ///
    /// These are as fragile as the patterns: a menu-style prompt wants "1" or
    /// "2", a y/n prompt wants "y". We send the most broadly-correct answer and
    /// let the user see the terminal to confirm it landed -- which is why the
    /// approval UI for this transport shows the terminal tab rather than just
    /// declaring success.
    static func keystroke(for decision: ApprovalDecision, menuStyle: Bool) -> String {
        switch (decision, menuStyle) {
        case (.allow, true): return "1\r"
        case (.alwaysAllow, true): return "2\r"
        case (.deny, true): return "3\r"
        case (.allow, false), (.alwaysAllow, false): return "y\r"
        case (.deny, false): return "n\r"
        }
    }

    /// Menu-style prompts enumerate numbered options; y/n prompts do not.
    static func looksLikeMenu(_ text: String) -> Bool {
        text.range(of: #"(?m)^\s*[│|]?\s*[1-3][.)]\s+\S"#, options: .regularExpression) != nil
    }

    /// Returns the first matching pattern and the detail it captured.
    static func match(in text: String) -> (pattern: Pattern, detail: String?)? {
        // Only ever look at the tail. A prompt is at the end of the output by
        // definition, and scanning a full scrollback buffer on every chunk of
        // output would be a real cost on a chatty build.
        let tail = String(text.suffix(2000))
        for pattern in all {
            guard tail.range(of: pattern.regex, options: .regularExpression) != nil else { continue }
            var detail: String?
            if let detailRegex = pattern.detailRegex,
               let range = tail.range(of: detailRegex, options: .regularExpression) {
                detail = tail[range].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (pattern, detail)
        }
        return nil
    }
}

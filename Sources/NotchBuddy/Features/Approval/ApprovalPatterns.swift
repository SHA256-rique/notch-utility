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
/// **This is not a Claude Code feature.** The badge exists for *any* CLI that
/// has stopped and is waiting on a human. Claude Code is listed first only
/// because it is the one with a hook, and therefore the one where attribution
/// can be exact; Codex, Aider, Gemini CLI and a plain `rm -i` all reach the
/// same UI through the generic rules below. Adding a tool means adding a
/// pattern here and nothing else -- no new transport, no new view, no new
/// setting.
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

        // --- Codex CLI ----------------------------------------------------
        // OpenAI's Codex CLI asks before running a command and before applying
        // a patch, with the command echoed on its own line.
        Pattern(source: "Codex",
                regex: #"(?i)\bcodex\b.{0,60}\b(wants to|would like to)\b"#,
                detailRegex: #"(?m)^\s*[>$]\s*(.+)$"#),
        Pattern(source: "Codex",
                regex: #"(?i)\ballow command\b|\brun this command\?"#,
                detailRegex: #"(?m)^\s*[>$]\s*(.+)$"#),
        Pattern(source: "Codex",
                regex: #"(?i)\bapply (this )?patch\?"#,
                detailRegex: nil),

        // --- Other coding agents -----------------------------------------
        Pattern(source: "Aider",
                regex: #"(?i)\bapplied edit to\b.{0,80}\?\s*\(y"#,
                detailRegex: nil),
        Pattern(source: "Gemini CLI",
                regex: #"(?i)\ballow execution of\b"#,
                detailRegex: #"(?m)^\s*[>$]\s*(.+)$"#),
        Pattern(source: "Agent",
                regex: #"(?i)\bwaiting for (your )?(approval|confirmation)\b"#,
                detailRegex: nil),
        Pattern(source: "Agent",
                regex: #"(?i)\bpress\s+(y|enter)\s+to\s+(continue|approve|confirm)\b"#,
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

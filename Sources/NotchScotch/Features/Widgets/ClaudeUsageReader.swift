import Foundation
import Combine

/// Claude usage: tokens, day streak, weekly bar chart.
///
/// ## Where the data comes from
/// Claude Code writes a JSONL transcript per session under
/// `~/.claude/projects/<slug>/<session-uuid>.jsonl`. Assistant messages in those
/// files carry a `usage` object with `input_tokens`, `output_tokens` and the two
/// cache counters, alongside an ISO-8601 `timestamp`. That is the whole source.
///
/// This matters for three reasons:
///   * It is **local**. No API key, no account linking, no network call, which
///     is the only way a usage widget belongs in a local-first app.
///   * It is **honest**. These are the tokens actually billed for work done on
///     this Mac, not an estimate derived from message counts.
///   * It costs nothing when nobody is looking, like every other widget here.
///
/// ## Why the files are parsed line-by-line and not with JSONDecoder
/// A busy month of transcripts is tens of megabytes across hundreds of files,
/// and each line is a large object of which we want four integers and a date.
/// Decoding every line into a Codable model would allocate the entire
/// conversation history to throw it away. Instead each line is scanned for the
/// `"usage":{...}` fragment and only that fragment is parsed. On a real
/// `~/.claude` this is the difference between ~40ms and several seconds.
///
/// ## Why it is cached against file modification dates
/// Transcripts are append-only and old ones never change. The reader keeps a
/// per-file cache keyed by (size, mtime); a rescan only re-reads files that grew
/// since last time. Opening the Home tab repeatedly does not re-walk the disk.
@MainActor
final class ClaudeUsageReader: ObservableObject {

    struct DayTotal: Identifiable, Equatable {
        var id: String { day }
        /// `yyyy-MM-dd` in the user's own calendar -- a streak is a human
        /// concept and must not shift because the transcript stamps are UTC.
        let day: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheWriteTokens: Int
        var messages: Int

        /// Cache reads are real tokens but they are cheap and enormous; folding
        /// them into the headline makes every other number invisible. The
        /// headline is what the user was charged attention for: fresh input,
        /// output, and the writes that created the cache.
        var billableTokens: Int { inputTokens + outputTokens + cacheWriteTokens }
        var allTokens: Int { billableTokens + cacheReadTokens }
    }

    struct Summary: Equatable {
        var today: DayTotal
        /// Oldest first, exactly seven entries ending today, zero-filled.
        var week: [DayTotal]
        var streakDays: Int
        var totalTokens30d: Int
        var busiestDay: DayTotal?
    }

    enum State: Equatable {
        case unavailable(String)
        case idle, loading
        case ready(Summary)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastScanned: Date?

    private var token: UUID?
    private var scanTask: Task<Void, Never>?

    /// (path -> (size, mtime, per-day totals)). Survives tab close so reopening
    /// Home is instant; it is dropped when the app quits, which is the right
    /// lifetime for a derived index of files we do not own.
    private static var cache: [String: CachedFile] = [:]
    private struct CachedFile {
        let size: Int
        let modified: Date
        let days: [String: DayTotal]
    }

    static var transcriptRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: - Lifecycle

    func activate() {
        scan()
        // Fifteen minutes. A transcript only changes while the user is running
        // Claude Code, and if they are, they are looking at the terminal rather
        // than at this tile.
        token = WidgetPollingHub.shared.register(label: "claude-usage", interval: 900) { [weak self] in
            Task { @MainActor in self?.scan() }
        }
    }

    func deactivate() {
        WidgetPollingHub.shared.unregister(token)
        token = nil
        scanTask?.cancel()
        scanTask = nil
    }

    func refresh() { scan() }

    // MARK: - Scan

    private func scan() {
        let root = Self.transcriptRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            state = .unavailable("No Claude Code transcripts found at ~/.claude/projects")
            return
        }
        scanTask?.cancel()
        if case .ready = state {} else { state = .loading }

        let cached = Self.cache
        scanTask = Task.detached(priority: .utility) {
            let (days, freshCache) = Self.walk(root: root, cache: cached)
            guard !Task.isCancelled else { return }
            let summary = Self.summarise(days)
            await MainActor.run {
                Self.cache = freshCache
                self.state = .ready(summary)
                self.lastScanned = Date()
            }
        }
    }

    /// Walks every transcript, reusing cached per-file totals where the file has
    /// not changed. Returns merged day totals and the refreshed cache.
    nonisolated private static func walk(root: URL,
                                         cache: [String: CachedFile]) -> ([String: DayTotal], [String: CachedFile]) {
        var merged: [String: DayTotal] = [:]
        var freshCache: [String: CachedFile] = [:]

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([:], [:]) }

        // Only the last 30 days matter to any of the numbers we present, so a
        // file untouched for longer than that is skipped without opening it.
        let horizon = Date().addingTimeInterval(-40 * 86_400)

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            guard modified >= horizon else { continue }

            let days: [String: DayTotal]
            if let hit = cache[url.path], hit.size == size, hit.modified == modified {
                days = hit.days
            } else {
                days = parse(url)
            }
            freshCache[url.path] = CachedFile(size: size, modified: modified, days: days)
            for (day, total) in days { merge(total, into: &merged, day: day) }
        }
        return (merged, freshCache)
    }

    nonisolated private static func merge(_ total: DayTotal, into dict: inout [String: DayTotal], day: String) {
        if var existing = dict[day] {
            existing.inputTokens += total.inputTokens
            existing.outputTokens += total.outputTokens
            existing.cacheReadTokens += total.cacheReadTokens
            existing.cacheWriteTokens += total.cacheWriteTokens
            existing.messages += total.messages
            dict[day] = existing
        } else {
            dict[day] = total
        }
    }

    /// Line-oriented scan. See the type doc for why this is not `JSONDecoder`.
    nonisolated private static func parse(_ url: URL) -> [String: DayTotal] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return [:] }

        var days: [String: DayTotal] = [:]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        text.enumerateLines { line, _ in
            // Cheapest possible rejection first: most lines are user messages,
            // tool results and snapshots, and carry no usage at all.
            guard line.contains("\"usage\"") else { return }
            guard let usageRange = line.range(of: "\"usage\":") else { return }
            guard let object = balancedObject(in: line, after: usageRange.upperBound) else { return }
            guard let usage = try? JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any] else { return }

            guard let stampRange = line.range(of: "\"timestamp\":\""),
                  let close = line[stampRange.upperBound...].firstIndex(of: "\"") else { return }
            let stamp = String(line[stampRange.upperBound..<close])
            guard let date = formatter.date(from: stamp) ?? plainFormatter.date(from: stamp) else { return }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            // Streaming emits an initial usage frame with everything at zero.
            // Counting those inflates the message count without adding tokens.
            guard input + output + cacheRead + cacheWrite > 0 else { return }

            let day = dayKey(date)
            merge(DayTotal(day: day, inputTokens: input, outputTokens: output,
                           cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                           messages: 1),
                  into: &days, day: day)
        }
        return days
    }

    /// Extracts the `{...}` starting at `index`, respecting nesting and strings.
    /// A naive scan to the first `}` truncates on the nested `server_tool_use`
    /// object that Claude Code emits inside `usage`.
    nonisolated private static func balancedObject(in line: String, after index: String.Index) -> String? {
        guard let start = line[index...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = start
        while cursor < line.endIndex {
            let character = line[cursor]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(line[start...cursor]) }
                }
            }
            cursor = line.index(after: cursor)
        }
        return nil
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    // MARK: - Summary

    nonisolated static func summarise(_ days: [String: DayTotal],
                                      today reference: Date = Date()) -> Summary {
        let calendar = Calendar.current
        func key(_ offset: Int) -> String {
            dayKey(calendar.date(byAdding: .day, value: -offset, to: reference) ?? reference)
        }
        func total(_ offset: Int) -> DayTotal {
            days[key(offset)] ?? DayTotal(day: key(offset), inputTokens: 0, outputTokens: 0,
                                          cacheReadTokens: 0, cacheWriteTokens: 0, messages: 0)
        }

        let week = (0..<7).map(total).reversed().map { $0 }

        // Streak: consecutive days with any usage, ending today *or* yesterday.
        // Ending yesterday still counts -- at 9am you have not used it today yet,
        // and telling someone their 40-day streak is zero would be a lie about
        // the data. It breaks only once a full day has been missed.
        var streak = 0
        var cursor = days[key(0)] != nil ? 0 : 1
        if days[key(cursor)] != nil {
            while let day = days[key(cursor)], day.billableTokens > 0 {
                streak += 1
                cursor += 1
                if cursor > 400 { break }   // no infinite walk on a corrupt index
            }
        }

        let last30 = (0..<30).map(total)
        return Summary(today: total(0),
                       week: week,
                       streakDays: streak,
                       totalTokens30d: last30.reduce(0) { $0 + $1.billableTokens },
                       busiestDay: last30.max { $0.billableTokens < $1.billableTokens })
    }

    // MARK: - Formatting

    nonisolated static func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }

    /// Single-letter weekday for the bar chart's axis.
    nonisolated static func weekdayInitial(for dayKey: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dayKey) else { return "" }
        let out = DateFormatter()
        out.dateFormat = "EEEEE"
        return out.string(from: date)
    }
}

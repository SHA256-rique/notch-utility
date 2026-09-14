import AppKit
import Combine
import UniformTypeIdentifiers

/// Where a snippet came from. The brief's key insight: clipboard history,
/// user-authored boilerplate and pinned items are not three features -- they are
/// one list with a provenance field. They share a schema, a search box, a copy
/// action, and the "Sent before" chips in the flash-message composer.
enum SnippetSource: String, Codable {
    case captured      // grabbed automatically off the pasteboard
    case userAuthored  // typed in by the user (address, signature, ...)

    var displayName: String { self == .captured ? "Clipboard" : "Saved" }
    var symbol: String { self == .captured ? "doc.on.clipboard" : "pencil.and.scribble" }
}

enum SnippetPayload: Codable, Equatable {
    case text(String)
    /// File paths rather than file *contents*. Copying a 4GB video must not put
    /// 4GB into clipboard history.
    case files([String])

    var asText: String {
        switch self {
        case .text(let s): return s
        case .files(let paths): return paths.joined(separator: "\n")
        }
    }
}

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: SnippetSource
    var payload: SnippetPayload
    var title: String = ""
    var isPinned = false
    var createdAt = Date()
    var lastUsedAt: Date?
    var useCount: Int = 0
    var sourceAppName: String = ""
    var sourceAppBundleID: String = ""
    var tag: String = ""

    var preview: String {
        let raw = payload.asText.trimmingCharacters(in: .whitespacesAndNewlines)
        let flat = raw.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
    var displayTitle: String { title.isEmpty ? preview : title }

    var wordCount: Int {
        payload.asText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
    var charCount: Int { payload.asText.count }

    var isFile: Bool { if case .files = payload { return true }; return false }
}

/// One store behind the Snippets tab, the flash-message composer's quick-repeat
/// chips, and the `snippetList` custom tab type.
@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    private struct Model: Codable { var snippets: [Snippet] = [] }

    @Published private(set) var snippets: [Snippet] = []
    private let store = JSONStore<Model>(filename: "snippets.json", debounce: 1.5)
    private var isLoading = false

    private init() {}

    func start() {
        isLoading = true
        snippets = (store.load() ?? Model()).snippets
        isLoading = false
        if snippets.isEmpty { seedExamples() }
    }

    func flush() { store.saveNow(Model(snippets: snippets)) }

    private func persist() {
        guard !isLoading else { return }
        store.save(Model(snippets: snippets))
    }

    /// Two example saved snippets on first run, so the tab is not an empty box
    /// that leaves the user guessing what "user-authored" means.
    private func seedExamples() {
        snippets = [
            Snippet(source: .userAuthored, payload: .text("hello@example.com"),
                    title: "Email", isPinned: true, tag: "contact"),
            Snippet(source: .userAuthored, payload: .text("Sent from NotchBuddy ✦"),
                    title: "Signature", tag: "contact")
        ]
        persist()
    }

    // MARK: - Capture

    /// Called by `ClipboardWatcher`. Deduplicates against the most recent entry
    /// so that a copy of the same text twice does not create two rows, and so a
    /// paste-loop in another app cannot flood history.
    func capture(_ payload: SnippetPayload, appName: String, bundleID: String) {
        let text = payload.asText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let existing = snippets.first(where: { $0.source == .captured && $0.payload == payload }) {
            // Promote the existing row to "most recent" rather than duplicating.
            touch(existing.id, copyToPasteboard: false)
            return
        }

        var snippet = Snippet(source: .captured, payload: payload)
        snippet.sourceAppName = appName
        snippet.sourceAppBundleID = bundleID
        snippets.insert(snippet, at: 0)
        trim()
        persist()

        NotchArbiter.shared.flash("Copied", symbol: "doc.on.clipboard.fill",
                                  module: .snippets,
                                  detail: snippet.isFile ? "\(text.split(separator: "\n").count) file(s)" : "\(snippet.charCount) chars")
    }

    /// Enforces the history limit, but **never** evicts pinned items or
    /// user-authored ones. That is the whole point of promoting something to
    /// pinned: it survives rotation.
    private func trim() {
        let limit = Settings.shared.data.clipboardHistoryLimit
        let captured = snippets.filter { $0.source == .captured && !$0.isPinned }
        guard captured.count > limit else { return }
        let doomed = Set(captured.suffix(captured.count - limit).map(\.id))
        snippets.removeAll { doomed.contains($0.id) }
    }

    // MARK: - Mutation

    func add(text: String, title: String, tag: String = "") {
        var snippet = Snippet(source: .userAuthored, payload: .text(text))
        snippet.title = title
        snippet.tag = tag
        snippets.insert(snippet, at: 0)
        persist()
    }

    func update(_ id: UUID, text: String, title: String, tag: String) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].payload = .text(text)
        snippets[i].title = title
        snippets[i].tag = tag
        persist()
    }

    func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].isPinned.toggle()
        persist()
    }

    func clearCaptured() {
        snippets.removeAll { $0.source == .captured && !$0.isPinned }
        persist()
    }

    /// Copy to the pasteboard and record the use.
    func touch(_ id: UUID, copyToPasteboard: Bool = true) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].lastUsedAt = Date()
        snippets[i].useCount += 1
        let snippet = snippets[i]
        persist()

        guard copyToPasteboard else { return }
        // Suppress our own watcher so writing to the pasteboard here does not
        // come straight back in as a fresh "captured" row.
        ClipboardWatcher.shared.suppressNextChange()
        let pb = NSPasteboard.general
        pb.clearContents()
        switch snippet.payload {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .files(let paths):
            pb.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        }
        NotchArbiter.shared.flash("Copied", symbol: "checkmark.circle.fill",
                                  module: .snippets, detail: snippet.displayTitle)
    }

    // MARK: - Queries

    func filtered(query: String, source: SnippetSource?, pinnedOnly: Bool, tag: String = "") -> [Snippet] {
        var result = snippets
        if pinnedOnly { result = result.filter(\.isPinned) }
        if let source { result = result.filter { $0.source == source } }
        if !tag.isEmpty { result = result.filter { $0.tag.caseInsensitiveCompare(tag) == .orderedSame } }
        if !query.isEmpty {
            result = result.filter {
                $0.payload.asText.localizedCaseInsensitiveContains(query)
                    || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.sourceAppName.localizedCaseInsensitiveContains(query)
            }
        }
        // Pinned float to the top; within a group, most recent first.
        return result.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt)
        }
    }

    /// Backs the flash-message composer's "Sent before" chips.
    var recentlyUsedText: [Snippet] {
        snippets.filter { $0.useCount > 0 && !$0.isFile }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(8).map { $0 }
    }

    var allTags: [String] {
        Array(Set(snippets.map(\.tag).filter { !$0.isEmpty })).sorted()
    }
}

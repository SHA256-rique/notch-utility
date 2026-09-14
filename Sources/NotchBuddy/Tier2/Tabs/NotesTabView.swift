import SwiftUI

/// Quick Notes: a local scratchpad.
///
/// Deliberately not synced, not backed by a server, not a database. One JSON
/// file, debounced writes, and the text lives in memory only while the tab is
/// open. The brief asked for "lightweight local scratchpad" and this is the
/// smallest thing that honours it.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    struct Note: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String = ""
        var body: String = ""
        var updatedAt = Date()
        var displayTitle: String {
            if !title.isEmpty { return title }
            let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
            return firstLine.isEmpty ? "Untitled" : String(firstLine.prefix(40))
        }
    }

    private struct Model: Codable { var notes: [Note] = [] }

    @Published var notes: [Note] = [] { didSet { guard !isLoading else { return }; store.save(Model(notes: notes)) } }
    private let store = JSONStore<Model>(filename: "notes.json", debounce: 1.2)
    private var isLoading = false

    private init() {}

    func load() {
        guard notes.isEmpty else { return }
        isLoading = true
        notes = (store.load() ?? Model()).notes
        isLoading = false
    }

    func flush() { store.saveNow(Model(notes: notes)) }

    func add() -> UUID {
        let note = Note()
        notes.insert(note, at: 0)
        return note.id
    }

    func update(_ id: UUID, title: String, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].title = title
        notes[i].body = body
        notes[i].updatedAt = Date()
    }

    func remove(_ id: UUID) { notes.removeAll { $0.id == id } }
}

struct NotesTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var store = NotesStore.shared
    @State private var selection: UUID?
    @State private var draftTitle = ""
    @State private var draftBody = ""

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 0) {
            // List
            VStack(spacing: 6) {
                HStack {
                    NBSectionHeader(title: "Notes")
                    Button {
                        let id = store.add()
                        select(id)
                    } label: { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), filled: true, compact: true))
                }
                .padding(.horizontal, 10).padding(.top, 8)

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.notes) { note in
                            Button { select(note.id) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.displayTitle)
                                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        .foregroundStyle(theme.primaryText)
                                    Text(note.updatedAt.formatted(.relative(presentation: .numeric)))
                                        .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(selection == note.id ? theme.tint(.notes).opacity(0.18) : .clear))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    store.remove(note.id)
                                    if selection == note.id { selection = nil }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
            }
            .frame(width: 180)

            Divider().overlay(theme.panelStroke)

            // Editor
            if selection != nil {
                VStack(spacing: 6) {
                    NBTextField(placeholder: "Title", text: $draftTitle)
                        .padding(.horizontal, 10).padding(.top, 8)
                    TextEditor(text: $draftBody)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .background(Color.clear)
                        .foregroundStyle(theme.primaryText)
                    HStack {
                        Text("\(draftBody.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count) words")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                // Persist on every keystroke through the debounced store, and
                // flush hard when the tab goes away.
                .onChange(of: draftTitle) { commit() }
                .onChange(of: draftBody) { commit() }
            } else {
                NBEmptyState(symbol: "note.text", title: "Pick a note",
                             subtitle: "Or create one. Everything stays on this Mac in a single JSON file.")
            }
        }
        .onAppear {
            store.load()
            if selection == nil, let first = store.notes.first { select(first.id) }
        }
        .onDisappear {
            commit()
            store.flush()
        }
    }

    private func select(_ id: UUID) {
        commit()
        selection = id
        if let note = store.notes.first(where: { $0.id == id }) {
            draftTitle = note.title
            draftBody = note.body
        }
    }

    private func commit() {
        guard let selection else { return }
        store.update(selection, title: draftTitle, body: draftBody)
    }
}

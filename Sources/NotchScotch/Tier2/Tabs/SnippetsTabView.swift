import SwiftUI
import AppKit

/// Snippets: the one list that is simultaneously clipboard history, the user's
/// saved boilerplate, and the pinned set. The filter chips are the only thing
/// separating them, because underneath they are the same rows.
///
/// The task board shares this tab as a right-hand side panel. The two features
/// are the same gesture at different time scales -- something crossed your
/// attention and you want it back later -- and having both on screen makes
/// "turn this clipboard entry into a task" one button rather than a cross-tab
/// round trip.
struct SnippetsTabView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", clipboard = "Clipboard", saved = "Saved", pinned = "Pinned"
        var id: String { rawValue }
    }

    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var store = SnippetStore.shared
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var isComposing = false
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftTag = ""
    @State private var editingID: UUID?
    @AppStorage("snippets.showTasks") private var showTasks = true

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 0) {
            clipboardSide(theme)

            if showTasks {
                Divider().overlay(theme.panelStroke)
                TaskBoardPanel()
                    .frame(width: 216)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.sheet, value: showTasks)
    }

    private func clipboardSide(_ theme: Theme) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                NBTextField(placeholder: "Search snippets…", text: $query)
                    .layoutPriority(1)
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                // `fixedSize` rather than a hardcoded width. Four segments of
                // localised text do not fit in 180pt, and a segmented control
                // given less room than it needs does not shrink -- it draws its
                // last segment straight over whatever comes next, which is how
                // "Pinned" ended up underneath the + button.
                .pickerStyle(.segmented).labelsHidden()
                .fixedSize()
                Button {
                    withAnimation(Motion.sheet) {
                        isComposing.toggle()
                        editingID = nil
                        draftTitle = ""; draftBody = ""; draftTag = ""
                    }
                } label: {
                    Image(systemName: isComposing ? "xmark" : "plus").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.snippets), filled: !isComposing))

                Button {
                    withAnimation(Motion.sheet) { showTasks.toggle() }
                } label: {
                    Image(systemName: showTasks ? "sidebar.right" : "checklist")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.time), filled: showTasks))
                .help(showTasks ? "Hide the task board" : "Show the task board")
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if isComposing { composer(theme) }

            let results = store.filtered(query: query,
                                         source: filter == .clipboard ? .captured : (filter == .saved ? .userAuthored : nil),
                                         pinnedOnly: filter == .pinned)
            if results.isEmpty {
                NBEmptyState(symbol: "doc.on.clipboard",
                             title: query.isEmpty ? "Nothing here yet" : "No matches",
                             subtitle: query.isEmpty
                                ? "Copy something and it lands here. Pin an item to keep it past the history limit."
                                : nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(results) { snippet in row(snippet, theme: theme) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }

            if filter == .clipboard || filter == .all {
                HStack {
                    Text("\(store.snippets.filter { $0.source == .captured }.count) captured · limit \(Settings.shared.data.clipboardHistoryLimit)")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button("Clear clipboard history") { store.clearCaptured() }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    // MARK: - Composer

    private func composer(_ theme: Theme) -> some View {
        NBCard(tint: .snippets, padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    NBTextField(placeholder: "Title (e.g. Home address)", text: $draftTitle)
                    NBTextField(placeholder: "Tag", text: $draftTag).frame(width: 90)
                }
                TextEditor(text: $draftBody)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                HStack {
                    Text("\(draftBody.count) chars")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button(editingID == nil ? "Save snippet" : "Update") {
                        guard !draftBody.isEmpty else { return }
                        if let editingID {
                            store.update(editingID, text: draftBody, title: draftTitle, tag: draftTag)
                        } else {
                            store.add(text: draftBody, title: draftTitle, tag: draftTag)
                        }
                        withAnimation(Motion.sheet) { isComposing = false }
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.snippets), filled: true, compact: true))
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Row

    private func row(_ snippet: Snippet, theme: Theme) -> some View {
        NBCard(tint: .snippets, padding: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: snippet.isFile ? "doc.fill" : snippet.source.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tint(.snippets))
                    .frame(width: 14)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    if !snippet.title.isEmpty {
                        Text(snippet.title).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                    }
                    Text(snippet.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(snippet.title.isEmpty ? theme.primaryText : theme.secondaryText)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text("\(snippet.wordCount)w · \(snippet.charCount)c")
                        if !snippet.sourceAppName.isEmpty { Text(snippet.sourceAppName) }
                        if !snippet.tag.isEmpty {
                            Text(snippet.tag)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(theme.tint(.snippets).opacity(0.18)))
                        }
                        Text(snippet.createdAt.formatted(.relative(presentation: .numeric)))
                    }
                    .font(.system(size: 8))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
                }

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Button {
                        store.touch(snippet.id)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 9)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.snippets), compact: true))
                    .help("Copy")

                    Button {
                        FlashMessageController.shared.flash(text: snippet.payload.asText)
                    } label: { Image(systemName: "sparkles").font(.system(size: 9)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.message), compact: true))
                    .help("Flash across the notch")

                    Button {
                        TaskBoard.shared.add(snippet.payload.asText, from: snippet.id)
                        NotchArbiter.shared.flash("Added to tasks", symbol: "checklist",
                                                  module: .snippets, detail: snippet.displayTitle)
                        withAnimation(Motion.sheet) { showTasks = true }
                    } label: { Image(systemName: "checklist").font(.system(size: 9)) }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
                    .help("Make a task from this")

                    Button {
                        store.togglePin(snippet.id)
                    } label: {
                        Image(systemName: snippet.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(NBButtonStyle(tint: snippet.isPinned ? theme.tint(.time) : theme.secondaryText, compact: true))
                    .help(snippet.isPinned ? "Unpin" : "Pin — survives history rotation")

                    Button {
                        store.remove(snippet.id)
                    } label: { Image(systemName: "trash").font(.system(size: 9)) }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                }
            }
        }
        .contextMenu {
            Button("Copy") { store.touch(snippet.id) }
            if snippet.source == .userAuthored {
                Button("Edit") {
                    editingID = snippet.id
                    draftTitle = snippet.title
                    draftBody = snippet.payload.asText
                    draftTag = snippet.tag
                    withAnimation(Motion.sheet) { isComposing = true }
                }
            }
            if snippet.source == .captured {
                Button("Save as snippet") {
                    store.add(text: snippet.payload.asText, title: "", tag: "")
                }
            }
            Button("Make a task") {
                TaskBoard.shared.add(snippet.payload.asText, from: snippet.id)
            }
            Divider()
            Button("Delete", role: .destructive) { store.remove(snippet.id) }
        }
    }
}

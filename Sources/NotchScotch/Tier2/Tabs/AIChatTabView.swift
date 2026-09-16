import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Drives one conversation: sending, streaming, and the context it carries.
///
/// State lives in `ChatStore` rather than here, because a conversation has to
/// outlive this view — the tab is torn down on every switch, and a chat panel
/// that forgets what you asked when you glance at a timer is a novelty.
@MainActor
final class AIChatModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorText: String?
    @Published private(set) var isCapturing = false

    private let store = ChatStore.shared
    private var task: Task<Void, Never>?

    var conversation: Conversation { store.current }
    var messages: [LLMMessage] { store.current.messages }
    var attachments: [ChatAttachment] { store.current.attachments }

    /// Rough budget used by the attached context, so "why is this slow and
    /// expensive" has a visible answer before the request is sent.
    var contextTokens: Int { attachments.reduce(0) { $0 + $1.approximateTokens } }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        errorText = nil

        // Context rides on the first user turn of the request rather than as a
        // system prompt: images cannot go in a system prompt at all, and a file
        // the user attached is something they are *asking about*, which reads
        // more naturally as part of their message.
        var message = LLMMessage(role: .user, text: text)
        let textual = attachments.filter { !$0.isImage && !$0.text.isEmpty }
        if !textual.isEmpty {
            let blocks = textual.map { "<file name=\"\($0.name)\">\n\($0.text)\n</file>" }
            message.text = blocks.joined(separator: "\n\n") + "\n\n" + text
        }
        message.images = attachments.compactMap { $0.isImage ? $0.imageData : nil }

        store.appendMessage(message)
        // An empty assistant message is appended up front and filled in as
        // deltas arrive, so the UI has a stable row to grow rather than
        // inserting one partway through the stream.
        store.appendMessage(LLMMessage(role: .assistant, text: ""))
        isStreaming = true

        let history = Array(store.current.messages.dropLast())
        task = Task { [weak self] in
            do {
                for try await delta in LLMClient.stream(messages: history) {
                    guard let self, !Task.isCancelled else { return }
                    self.store.updateLastMessage { $0.text += delta }
                    // The store mutates in place without publishing per token,
                    // so nudge the view ourselves at the same rate.
                    self.objectWillChange.send()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
                self.store.dropLastMessageIfEmpty()
            }
            self?.store.finishStreaming()
            self?.isStreaming = false
            self?.objectWillChange.send()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if isStreaming {
            store.finishStreaming()
            isStreaming = false
        }
    }

    func newConversation() {
        stop()
        errorText = nil
        draft = ""
        store.newConversation()
        objectWillChange.send()
    }

    func select(_ id: UUID) {
        stop()
        errorText = nil
        store.select(id)
        objectWillChange.send()
    }

    func delete(_ id: UUID) {
        stop()
        store.delete(id)
        objectWillChange.send()
    }

    func clearMessages() {
        stop()
        errorText = nil
        store.clearMessages()
        objectWillChange.send()
    }

    // MARK: - Context

    func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            switch ChatContextLoader.load(url: url) {
            case .success(let attachment): store.addAttachment(attachment)
            case .failure(let error): errorText = error.text
            }
        }
        objectWillChange.send()
    }

    func addScreenshot() {
        isCapturing = true
        // The panel has to get out of the way or the user ends up screenshotting
        // this app instead of whatever they wanted to ask about.
        NotchPanelController.shared.collapse()

        ChatContextLoader.captureScreenshot { [weak self] result in
            guard let self else { return }
            self.isCapturing = false
            switch result {
            case .success(let attachment):
                self.store.addAttachment(attachment)
                NotchArbiter.shared.flash("Added to context", symbol: "camera.viewfinder",
                                          module: .ai)
            case .failure(let error):
                // An empty message means the user pressed escape, which is not
                // a failure worth reporting back to them.
                if !error.text.isEmpty { self.errorText = error.text }
            }
            NotchPanelController.shared.expand(selecting: .builtin(.ai))
            self.objectWillChange.send()
        }
    }

    func addPastedText() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "The clipboard has no text in it"
            return
        }
        store.addAttachment(ChatAttachment(kind: .snippet, name: "Pasted text", text: text))
        objectWillChange.send()
    }

    func removeAttachment(_ id: UUID) {
        store.removeAttachment(id)
        objectWillChange.send()
    }
}

struct AIChatTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var store = ChatStore.shared
    @StateObject private var model = AIChatModel()
    @AppStorage("ai.showHistory") private var showHistory = false
    @State private var showContext = true

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 0) {
            if showHistory {
                history(theme)
                    .frame(width: 186)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().overlay(theme.panelStroke)
            }

            conversation(theme)
                .frame(maxWidth: .infinity)
        }
        .animation(Motion.sheet, value: showHistory)
        .onDisappear { model.stop() }
    }

    // MARK: - History

    private func history(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                NBSectionHeader(title: "History", trailing: "\(store.conversations.count)")
            }
            .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 5)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.ordered) { conversation in
                        historyRow(conversation, theme)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(Color.white.opacity(0.03))
    }

    private func historyRow(_ conversation: Conversation, _ theme: Theme) -> some View {
        let isCurrent = conversation.id == store.currentID
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.displayTitle)
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(conversation.updatedAt.formatted(.relative(presentation: .numeric)))
                    if !conversation.attachments.isEmpty {
                        Image(systemName: "paperclip").font(.system(size: 7))
                        Text("\(conversation.attachments.count)")
                    }
                }
                .font(.system(size: 8))
                .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 2)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isCurrent ? theme.tint(.ai).opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .pointerCursor()
        .onTapGesture { model.select(conversation.id) }
        .contextMenu {
            Button("Delete", role: .destructive) { model.delete(conversation.id) }
        }
    }

    // MARK: - Conversation

    private func conversation(_ theme: Theme) -> some View {
        let ready = LLMClient.hasCredentials(for: settings.data.llmProvider)

        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.sheet) { showHistory.toggle() }
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.ai), filled: showHistory, compact: true))
                .help(showHistory ? "Hide history" : "Show history")

                Button {
                    model.newConversation()
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.ai), compact: true))
                .help("Start a new conversation")

                NBSectionHeader(title: settings.data.llmProvider.displayName,
                                trailing: settings.data.llmModel)

                Spacer()

                if model.isStreaming {
                    Button("Stop") { model.stop() }
                        .buttonStyle(NBButtonStyle(tint: .orange, compact: true))
                }
                Button("Clear") { model.clearMessages() }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                    .disabled(model.messages.isEmpty)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            contextBar(theme)

            if !ready {
                NBEmptyState(symbol: "key",
                             title: "No API key for \(settings.data.llmProvider.displayName)",
                             subtitle: "Add one in Settings → AI. It's stored in the macOS Keychain, never in a file, and is only read at the moment a request is made.")
            } else if model.messages.isEmpty {
                NBEmptyState(symbol: "sparkles", title: "Ask anything",
                             subtitle: "Attach files or a screenshot first and they travel with every turn. Requests go straight from this Mac to \(settings.data.llmProvider.displayName) — NotchScotch has no server of its own.")
            } else {
                transcript(theme)
            }

            composer(theme, ready: ready)
        }
    }

    private func transcript(_ theme: Theme) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { message in
                        bubble(message, theme: theme).id(message.id)
                    }
                    if let error = model.errorText {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .onChange(of: model.messages.last?.text) {
                // Follow the stream, but only if the user has not scrolled
                // away — SwiftUI gives us no scroll offset here, so this errs
                // toward following, which is what people expect from a chat.
                if let last = model.messages.last {
                    withAnimation(Motion.tabSwitch) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Context

    /// Context belongs to the conversation, not to one message: you attach a
    /// file and then ask three questions about it. This bar is what makes that
    /// visible — and what stops a forgotten 80k-character attachment quietly
    /// riding along on every future turn.
    private func contextBar(_ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Button {
                    withAnimation(Motion.tabSwitch) { showContext.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 9))
                        Text("Context")
                            .font(.system(size: 10, weight: .medium))
                        if !model.attachments.isEmpty {
                            Text("\(model.attachments.count)")
                                .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        }
                        Image(systemName: showContext ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                    }
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.ai),
                                           filled: !model.attachments.isEmpty, compact: true))

                Button { model.addFiles() } label: {
                    Label("Files", systemImage: "doc.badge.plus")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))

                Button { model.addScreenshot() } label: {
                    Label(model.isCapturing ? "Pick an area…" : "Screenshot",
                          systemImage: "camera.viewfinder")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                .disabled(model.isCapturing)
                .help("Drag to select an area, exactly like ⇧⌘4")

                Button { model.addPastedText() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))

                Spacer()

                if model.contextTokens > 0 {
                    Text("~\(model.contextTokens / 1_000)k tokens")
                        .font(.system(size: 9)).monospacedDigit()
                        .foregroundStyle(model.contextTokens > 60_000 ? .orange : theme.secondaryText)
                        .help("A rough estimate, sent with every turn in this conversation")
                }
            }

            if showContext && !model.attachments.isEmpty {
                FlowRow(spacing: 5) {
                    ForEach(model.attachments) { attachment in
                        attachmentChip(attachment, theme)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func attachmentChip(_ attachment: ChatAttachment, _ theme: Theme) -> some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .font(.system(size: 9))
                .foregroundStyle(theme.tint(.ai))
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.primaryText).lineLimit(1)
                Text(attachment.sizeNote)
                    .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
            }
            Button {
                model.removeAttachment(attachment.id)
            } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }
                .buttonStyle(.plain).pointerCursor()
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Capsule().fill(theme.tint(.ai).opacity(0.14)))
        .frame(maxWidth: 190)
        .help(attachment.path.isEmpty ? attachment.name : attachment.path)
    }

    // MARK: - Composer

    private func composer(_ theme: Theme, ready: Bool) -> some View {
        HStack(spacing: 6) {
            NBTextField(placeholder: "Message…", text: $model.draft) { model.send() }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.ai), filled: true))
            .disabled(!ready || model.isStreaming)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func bubble(_ message: LLMMessage, theme: Theme) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tint(.ai))
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                if message.hasImages {
                    HStack(spacing: 4) {
                        Image(systemName: "photo").font(.system(size: 9))
                        Text("\(message.images.count) image\(message.images.count == 1 ? "" : "s") attached")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(theme.secondaryText)
                }
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(message.role == .user
                          ? theme.tint(.ai).opacity(0.18)
                          : Color.white.opacity(0.06)))
            if message.role == .user { Spacer(minLength: 30) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

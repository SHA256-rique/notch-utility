import SwiftUI

@MainActor
final class AIChatModel: ObservableObject {
    @Published var messages: [LLMMessage] = []
    @Published var draft = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorText: String?

    private var task: Task<Void, Never>?

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        errorText = nil
        messages.append(LLMMessage(role: .user, text: text))
        // An empty assistant message is appended up front and filled in as
        // deltas arrive, so the UI has a stable row to grow rather than
        // inserting one partway through the stream.
        messages.append(LLMMessage(role: .assistant, text: ""))
        isStreaming = true

        let history = Array(messages.dropLast())
        task = Task { [weak self] in
            do {
                for try await delta in LLMClient.stream(messages: history) {
                    guard let self, !Task.isCancelled else { return }
                    if let index = self.messages.indices.last {
                        self.messages[index].text += delta
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
                // Drop the empty placeholder so a failed turn does not leave a
                // blank bubble behind.
                if self.messages.last?.text.isEmpty == true { self.messages.removeLast() }
            }
            self?.isStreaming = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    func clear() {
        stop()
        messages = []
        errorText = nil
    }
}

struct AIChatTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @StateObject private var model = AIChatModel()

    var body: some View {
        let theme = themes.theme
        let ready = LLMClient.hasCredentials(for: settings.data.llmProvider)

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                NBSectionHeader(title: settings.data.llmProvider.displayName,
                                trailing: settings.data.llmModel)
                Spacer()
                if model.isStreaming {
                    Button("Stop") { model.stop() }
                        .buttonStyle(NBButtonStyle(tint: .orange, compact: true))
                }
                Button("Clear") { model.clear() }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if !ready {
                NBEmptyState(symbol: "key",
                             title: "No API key for \(settings.data.llmProvider.displayName)",
                             subtitle: "Add one in Settings → AI. It's stored in the macOS Keychain, never in a file, and is only read at the moment a request is made.")
            } else if model.messages.isEmpty {
                NBEmptyState(symbol: "sparkles", title: "Ask anything",
                             subtitle: "Requests go straight from this Mac to \(settings.data.llmProvider.displayName). NotchScotch has no server of its own.")
            } else {
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
                        // Follow the stream, but only if the user has not
                        // scrolled away — SwiftUI gives us no scroll offset here,
                        // so this errs toward following, which is the behaviour
                        // people expect from a chat.
                        if let last = model.messages.last {
                            withAnimation(Motion.tabSwitch) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

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
        .onDisappear { model.stop() }
    }

    private func bubble(_ message: LLMMessage, theme: Theme) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tint(.ai))
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 2) {
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

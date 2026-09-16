import AppKit
import SwiftUI

/// The small floating panel that appears beside a text selection.
///
/// Kept entirely separate from the notch panel: it has a different anchor (the
/// selection, anywhere on screen), a different lifetime (seconds), and it must
/// not disturb the notch's own state machine.
@MainActor
final class SelectionActionWindow {
    private var panel: NSPanel?
    private let model = SelectionActionModel()

    func present(text: String, near bounds: CGRect) {
        model.reset(with: text)

        if panel == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu     // above the notch panel, below system alerts
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
            p.isMovable = false
            p.contentView = NSHostingView(rootView:
                SelectionActionView(model: model)
                    .environmentObject(ThemeManager.shared))
            panel = p
        }

        // AX reports coordinates in a top-left origin space; AppKit windows use
        // bottom-left. Converting via the screen height is the standard fix and
        // is easy to get subtly wrong on multi-display setups, so the screen is
        // chosen by containment rather than assuming the main one.
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let flippedY = screen.frame.maxY - bounds.maxY - 8
        let size = model.expanded ? CGSize(width: 360, height: 200) : CGSize(width: 300, height: 44)
        var origin = CGPoint(x: bounds.midX - size.width / 2, y: flippedY - size.height)

        // Keep it fully on screen.
        origin.x = max(screen.frame.minX + 8, min(origin.x, screen.frame.maxX - size.width - 8))
        origin.y = max(screen.frame.minY + 8, min(origin.y, screen.frame.maxY - size.height - 8))

        panel?.setFrame(CGRect(origin: origin, size: size), display: true)
        panel?.orderFrontRegardless()
        model.onResize = { [weak self] expanded in
            guard let self, let panel = self.panel else { return }
            let newSize = expanded ? CGSize(width: 360, height: 200) : CGSize(width: 300, height: 44)
            panel.setFrame(CGRect(origin: panel.frame.origin, size: newSize), display: true)
        }
        model.onDismiss = { [weak self] in self?.dismiss() }
    }

    func dismiss() {
        model.cancel()
        panel?.orderOut(nil)
    }
}

@MainActor
final class SelectionActionModel: ObservableObject {
    enum Action: String, CaseIterable, Identifiable {
        case explain = "Explain", rewrite = "Rewrite", translate = "Translate"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .explain: return "questionmark.circle"
            case .rewrite: return "wand.and.stars"
            case .translate: return "character.book.closed"
            }
        }
        /// The system prompt for each action. Short and specific: the result has
        /// to fit in a small popover, and a verbose model response is useless
        /// there.
        var systemPrompt: String {
            switch self {
            case .explain:
                return "Explain the user's selected text clearly and concisely. Two or three sentences. No preamble."
            case .rewrite:
                return "Rewrite the user's selected text to be clearer and better written. Preserve meaning, tone and approximate length. Output only the rewritten text, nothing else."
            case .translate:
                return "Translate the user's selected text into English. If it is already English, translate it into Spanish. Output only the translation."
            }
        }
    }

    @Published var selection = ""
    @Published var expanded = false
    @Published var result = ""
    @Published var isWorking = false
    @Published var errorText: String?
    @Published var activeAction: Action?

    var onResize: ((Bool) -> Void)?
    var onDismiss: (() -> Void)?
    private var task: Task<Void, Never>?

    func reset(with text: String) {
        cancel()
        selection = text
        result = ""
        errorText = nil
        activeAction = nil
        setExpanded(false)
    }

    /// Nothing is sent anywhere until this is called. Selecting text does not
    /// make a network request -- only clicking one of the three buttons does.
    func run(_ action: Action) {
        cancel()
        activeAction = action
        result = ""
        errorText = nil
        isWorking = true
        setExpanded(true)

        let messages = [LLMMessage(role: .user, text: selection)]
        task = Task { [weak self] in
            do {
                for try await delta in LLMClient.stream(messages: messages,
                                                        system: action.systemPrompt,
                                                        maxTokens: 700) {
                    guard let self, !Task.isCancelled else { return }
                    self.result += delta
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
            }
            self?.isWorking = false
        }
    }

    func copyResult() {
        ClipboardWatcher.shared.suppressNextChange()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        NotchArbiter.shared.flash("Copied", symbol: "doc.on.doc", module: .ai)
        onDismiss?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    private func setExpanded(_ value: Bool) {
        expanded = value
        onResize?(value)
    }
}

struct SelectionActionView: View {
    @ObservedObject var model: SelectionActionModel
    @EnvironmentObject private var themes: ThemeManager

    var body: some View {
        let theme = themes.theme
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(SelectionActionModel.Action.allCases) { action in
                    Button {
                        model.run(action)
                    } label: {
                        Label(action.rawValue, systemImage: action.symbol)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.ai),
                                               filled: model.activeAction == action, compact: true))
                }
                Spacer()
                Button {
                    model.onDismiss?()
                } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
            }

            if model.expanded {
                Divider().overlay(theme.panelStroke)
                ScrollView {
                    if let error = model.errorText {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    } else {
                        Text(model.result.isEmpty && model.isWorking ? "…" : model.result)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .foregroundStyle(theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Copy") { model.copyResult() }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.ai), compact: true))
                        .disabled(model.result.isEmpty)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.panelBackground)
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(theme.panelStroke, lineWidth: 1)))
    }
}

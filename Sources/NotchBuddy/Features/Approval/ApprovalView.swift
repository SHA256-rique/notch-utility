import SwiftUI

/// The approval surface. One view for all three transports -- the only thing
/// that differs is a confidence label and which buttons make sense.
struct ApprovalView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var center = ApprovalCenter.shared

    var body: some View {
        let theme = themes.theme
        if let approval = center.current {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tint(.approval))
                        .themeGlow(theme.tint(.approval), radius: theme.glowRadius(6))
                    Text(approval.source)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                    if !approval.toolName.isEmpty {
                        Text(approval.toolName)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(theme.tint(.approval).opacity(0.2)))
                            .foregroundStyle(theme.tint(.approval))
                    }
                    Spacer()
                    // Being explicit about how we detected this is a trust
                    // feature: a "best-effort" match deserves a closer look
                    // before the user clicks Approve.
                    Text("\(approval.transport.displayName) · \(approval.transport.confidence)")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText)
                    if center.pending.count > 1 {
                        Text("+\(center.pending.count - 1) more")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.tint(.approval))
                    }
                }

                Text(approval.prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = approval.detail, !detail.isEmpty {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(theme.secondaryText)
                            .padding(8)
                    }
                    .frame(maxHeight: 110)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                }

                HStack(spacing: 8) {
                    Button("Approve") { center.resolve(approval, with: .allow) }
                        .buttonStyle(NBButtonStyle(tint: .green, filled: true))
                        .keyboardShortcut(.return, modifiers: [])

                    Button("Deny") { center.resolve(approval, with: .deny) }
                        .buttonStyle(NBButtonStyle(tint: .red))
                        .keyboardShortcut(.escape, modifiers: [])

                    // Always-allow only makes sense when there is a stable key to
                    // remember. A bare y/n prompt has no tool name, so allowing
                    // "everything from this source forever" would be reckless.
                    if !approval.toolName.isEmpty {
                        Button("Always allow \(approval.toolName)") {
                            center.resolve(approval, with: .alwaysAllow)
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.approval)))
                    }
                    Spacer()
                    Text(approval.createdAt.formatted(.relative(presentation: .numeric)))
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.tint(.approval).opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.tint(.approval).opacity(0.45), lineWidth: 1))
            )
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(Motion.sheet, value: approval.id)
        }
    }
}

/// Settings/status surface for the approval subsystem, shown inside the
/// Terminal tab and in Settings.
struct ApprovalStatusView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var center = ApprovalCenter.shared
    @State private var copied = false

    var body: some View {
        let theme = themes.theme
        VStack(alignment: .leading, spacing: 8) {
            NBSectionHeader(title: "CLI approvals")

            transportRow(
                title: "Hook (recommended)",
                detail: ApprovalHookServer.shared.isRunning
                    ? "Listening. Exact, version-proof, no output parsing."
                    : "Not running.",
                isOn: Binding(get: { settings.data.approvalHookEnabled },
                              set: { newValue in
                                  settings.data.approvalHookEnabled = newValue
                                  newValue ? ApprovalHookServer.shared.start()
                                           : ApprovalHookServer.shared.stop()
                              }),
                ok: ApprovalHookServer.shared.isRunning, theme: theme)

            transportRow(
                title: "Terminal tab (owned pty)",
                detail: "Automatic whenever you run an agent in the Terminal tab. Pattern-based, but the reply goes straight into the pty.",
                isOn: .constant(true), locked: true, ok: true, theme: theme)

            transportRow(
                title: "Log file watching",
                detail: "Last resort. Tails a file you pipe your agent's output to. Fragile against output changes.",
                isOn: Binding(get: { settings.data.approvalStdoutFallbackEnabled },
                              set: { settings.data.approvalStdoutFallbackEnabled = $0 }),
                ok: settings.data.approvalStdoutFallbackEnabled, theme: theme)

            if settings.data.approvalHookEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add this to ~/.claude/settings.json:")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(ApprovalHookServer.shared.settingsSnippet)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(theme.primaryText)
                            .padding(7)
                    }
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
                    Button(copied ? "Copied" : "Copy snippet") {
                        ClipboardWatcher.shared.suppressNextChange()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ApprovalHookServer.shared.settingsSnippet, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.approval), compact: true))
                }
            }

            if !settings.data.approvalAlwaysAllowRules.isEmpty {
                NBSectionHeader(title: "Always-allow rules")
                FlowRow(spacing: 5) {
                    ForEach(settings.data.approvalAlwaysAllowRules, id: \.self) { rule in
                        Button {
                            center.clearRule(rule)
                        } label: {
                            HStack(spacing: 3) {
                                Text(rule).font(.system(size: 9, design: .monospaced))
                                Image(systemName: "xmark").font(.system(size: 7))
                            }
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.approval), compact: true))
                    }
                }
            }

            if !center.recent.isEmpty {
                NBSectionHeader(title: "Recent")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(center.recent.prefix(4).enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 5) {
                            Image(systemName: entry.decision == .deny ? "xmark.circle" : "checkmark.circle")
                                .font(.system(size: 8))
                                .foregroundStyle(entry.decision == .deny ? Color.red : Color.green)
                            Text(entry.prompt).font(.system(size: 9)).lineLimit(1)
                                .foregroundStyle(theme.secondaryText)
                            Spacer()
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private func transportRow(title: String, detail: String, isOn: Binding<Bool>,
                              locked: Bool = false, ok: Bool, theme: Theme) -> some View {
        NBCard(tint: .approval, padding: 9) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(ok ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Text(detail).font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !locked {
                    Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
            }
        }
    }
}

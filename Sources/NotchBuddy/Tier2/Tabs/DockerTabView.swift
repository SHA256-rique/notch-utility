import SwiftUI

struct DockerTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @State private var containers: [DockerClient.Container] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            HStack {
                NBSectionHeader(title: "Containers",
                                trailing: containers.isEmpty ? nil
                                    : "\(containers.filter(\.isRunning).count) running · \(containers.count) total")
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.docker), compact: true))
                .disabled(isLoading)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if isLoading && containers.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                NBEmptyState(symbol: "shippingbox", title: "Docker unavailable", subtitle: error)
            } else if containers.isEmpty {
                NBEmptyState(symbol: "shippingbox", title: "No containers")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(containers) { container in row(container, theme: theme) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }

            Text("Queried only when you open this tab or press refresh — never in the background.")
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                .padding(.bottom, 8)
        }
        .onAppear { load() }
        .onDisappear { loadTask?.cancel(); loadTask = nil }
    }

    private func row(_ container: DockerClient.Container, theme: Theme) -> some View {
        NBCard(tint: .docker, padding: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor(container.state))
                    .frame(width: 7, height: 7)
                    .themeGlow(stateColor(container.state), radius: theme.glowRadius(4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(container.name)
                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .foregroundStyle(theme.primaryText)
                    Text(container.image)
                        .font(.system(size: 9, design: .monospaced)).lineLimit(1)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 6)
                if !container.ports.isEmpty {
                    Text(container.ports.joined(separator: " "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.tint(.docker))
                        .lineLimit(1)
                }
                Text(container.status)
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
            }
        }
        .contextMenu {
            Button("Copy container ID") {
                ClipboardWatcher.shared.suppressNextChange()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(container.id, forType: .string)
            }
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "running": return .green
        case "paused": return .yellow
        case "restarting": return .orange
        case "exited", "dead": return .red
        default: return .gray
        }
    }

    private func load() {
        loadTask?.cancel()
        isLoading = true
        error = nil
        loadTask = Task {
            do {
                let result = try await DockerClient.list()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    containers = result.sorted {
                        $0.isRunning == $1.isRunning ? $0.name < $1.name : $0.isRunning
                    }
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

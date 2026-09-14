import SwiftUI
import UniformTypeIdentifiers

/// Files: drop images in, pick a format, convert. Everything happens locally.
struct FilesTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @State private var dropped: [URL] = []
    @State private var target = FileConverter.imageTargets[0]
    @State private var quality: Double = 0.85
    @State private var results: [FileConverter.Result] = []
    @State private var isConverting = false
    @State private var isTargeted = false

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 8) {
            dropZone(theme)

            HStack(spacing: 8) {
                Picker("", selection: $target) {
                    ForEach(FileConverter.imageTargets) { Text($0.name).tag($0) }
                }
                .labelsHidden().frame(width: 92)

                if target.utType == .jpeg || target.utType == .heic {
                    HStack(spacing: 4) {
                        Text("Quality").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        Slider(value: $quality, in: 0.1...1).controlSize(.mini).frame(width: 90)
                        Text(String(format: "%.0f%%", quality * 100))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                Button("Choose files…") { pick() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                Button(isConverting ? "Converting…" : "Convert \(dropped.count)") { convert() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), filled: true, compact: true))
                    .disabled(dropped.isEmpty || isConverting)
            }
            .padding(.horizontal, 12)

            if !results.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(results) { result in resultRow(result, theme: theme) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            } else if !dropped.isEmpty {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(dropped, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable().frame(width: 14, height: 14)
                                Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1)
                                    .foregroundStyle(theme.primaryText)
                                Spacer()
                                Button {
                                    dropped.removeAll { $0 == url }
                                } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                .buttonStyle(.plain).foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            } else {
                Spacer()
            }
        }
        .padding(.top, 8)
    }

    private func dropZone(_ theme: Theme) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(isTargeted ? theme.tint(.files) : theme.panelStroke)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? theme.tint(.files).opacity(0.10) : Color.clear))
            .frame(height: 72)
            .overlay {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 16))
                        .foregroundStyle(isTargeted ? theme.tint(.files) : theme.secondaryText)
                    Text(dropped.isEmpty ? "Drop images here"
                                         : "\(dropped.count) file\(dropped.count == 1 ? "" : "s") ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Text("PNG · JPEG · HEIC · TIFF · GIF · PDF — converted on this Mac, nothing uploaded")
                        .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, FileConverter.isImage(url) else { return }
                        DispatchQueue.main.async {
                            if !dropped.contains(url) { dropped.append(url) }
                            results = []
                        }
                    }
                }
                return true
            }
            .animation(Motion.interactive, value: isTargeted)
    }

    private func resultRow(_ result: FileConverter.Result, theme: Theme) -> some View {
        NBCard(tint: .files, padding: 7) {
            HStack(spacing: 7) {
                Image(systemName: result.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(result.error == nil ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.outputURL?.lastPathComponent ?? result.sourceName)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(theme.primaryText)
                    if let error = result.error {
                        Text(error).font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    } else {
                        let delta = result.originalBytes > 0
                            ? Int(Double(result.outputBytes - result.originalBytes) / Double(result.originalBytes) * 100)
                            : 0
                        Text("\(FileConverter.formatBytes(result.originalBytes)) → \(FileConverter.formatBytes(result.outputBytes))  (\(delta > 0 ? "+" : "")\(delta)%)")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                if let url = result.outputURL {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                }
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        dropped.append(contentsOf: panel.urls.filter { !dropped.contains($0) })
        results = []
    }

    private func convert() {
        isConverting = true
        results = []
        let files = dropped
        FileConverter.convert(urls: files, to: target, quality: quality) { result in
            results.append(result)
        } completion: {
            isConverting = false
            dropped = []
            let succeeded = results.filter { $0.error == nil }.count
            NotchArbiter.shared.flash("Converted \(succeeded)", symbol: "checkmark.circle.fill",
                                      module: .files, detail: target.name)
        }
    }
}

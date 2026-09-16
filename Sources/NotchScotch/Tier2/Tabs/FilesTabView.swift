import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Files: drop images in, pick a format and a size cap, convert. Everything
/// happens locally.
///
/// The tab is two lists that never coexist confusingly: the **queue** of files
/// waiting to be converted, and the **done list** of what came out. Converting
/// moves items from one to the other, and each finished file carries its own
/// preview, share and reveal actions -- because "where did it go" is the first
/// question anyone has after a batch conversion.
struct FilesTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @State private var queue: [URL] = []
    @State private var target = FileConverter.imageTargets[0]
    @State private var size = FileConverter.sizePresets[3]     // Original
    @State private var quality: Double = 0.85
    @State private var results: [FileConverter.Result] = []
    @State private var isConverting = false
    @State private var isTargeted = false
    @State private var previewing: FileConverter.Result?

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 8) {
            dropZone(theme)
            controls(theme)

            if !results.isEmpty {
                doneList(theme)
            } else if !queue.isEmpty {
                queueList(theme)
            } else {
                Spacer()
            }
        }
        .padding(.top, 8)
        .sheet(item: $previewing) { result in
            previewSheet(result, theme: theme)
        }
    }

    // MARK: - Controls

    private func controls(_ theme: Theme) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $target) {
                    ForEach(FileConverter.imageTargets) { Text($0.name).tag($0) }
                }
                .labelsHidden().frame(width: 92)

                // The size cap matters more than quality for output size, so it
                // gets the prominent segmented control and quality gets a slider.
                Picker("", selection: $size) {
                    ForEach(FileConverter.sizePresets) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)

                Spacer()

                Button("Choose files…") { pick() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                Button(isConverting ? "Converting…" : "Convert \(queue.count)") { convert() }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), filled: true, compact: true))
                    .disabled(queue.isEmpty || isConverting)
            }

            HStack(spacing: 8) {
                if target.utType == .jpeg || target.utType == .heic {
                    Text("Quality").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    Slider(value: $quality, in: 0.1...1).controlSize(.mini).frame(width: 120)
                    Text(String(format: "%.0f%%", quality * 100))
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("\(target.name) is lossless — the quality slider does not apply.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
                Spacer()
                if size.maxPixels != nil {
                    Text("Longest edge capped at \(size.name). Smaller images are left alone.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
                if !results.isEmpty {
                    Button("Clear") { results = [] }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Drop zone

    private func dropZone(_ theme: Theme) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(isTargeted ? theme.tint(.files) : theme.panelStroke)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? theme.tint(.files).opacity(0.10) : Color.clear))
            .frame(height: 64)
            .overlay {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 15))
                        .foregroundStyle(isTargeted ? theme.tint(.files) : theme.secondaryText)
                    Text(queue.isEmpty ? "Drop images here"
                                       : "\(queue.count) file\(queue.count == 1 ? "" : "s") queued")
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
                            if !queue.contains(url) { queue.append(url) }
                            results = []
                        }
                    }
                }
                return true
            }
            .animation(Motion.interactive, value: isTargeted)
    }

    // MARK: - Queue

    private func queueList(_ theme: Theme) -> some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(queue, id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 14, height: 14)
                        Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(1)
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Button {
                            queue.removeAll { $0 == url }
                        } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                        .buttonStyle(.plain).pointerCursor().foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }

    // MARK: - Done list

    private func doneList(_ theme: Theme) -> some View {
        let succeeded = results.filter { $0.error == nil }
        let saved = succeeded.reduce(0) { $0 + ($1.originalBytes - $1.outputBytes) }
        return VStack(spacing: 5) {
            HStack {
                NBSectionHeader(title: "Done",
                                trailing: "\(succeeded.count) of \(results.count)")
                if saved > 0 {
                    Text("saved \(FileConverter.formatBytes(saved))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
                if succeeded.count > 1 {
                    Button("Reveal all") {
                        NSWorkspace.shared.activateFileViewerSelecting(succeeded.compactMap(\.outputURL))
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                }
            }
            .padding(.horizontal, 12)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(results) { result in resultRow(result, theme: theme) }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }

    private func resultRow(_ result: FileConverter.Result, theme: Theme) -> some View {
        NBCard(tint: .files, padding: 7) {
            HStack(spacing: 8) {
                // The preview is of the *output*, not the input, so what you see
                // is what was actually written.
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.fieldBackground)
                    if let thumbnail = result.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    } else {
                        Image(systemName: result.error == nil ? "doc" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(result.error == nil ? theme.secondaryText : Color.orange)
                    }
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text(result.outputURL?.lastPathComponent ?? result.sourceName)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .foregroundStyle(theme.primaryText)
                    if let error = result.error {
                        Text(error).font(.system(size: 9)).foregroundStyle(Color.orange)
                    } else {
                        let delta = result.originalBytes > 0
                            ? Int(Double(result.outputBytes - result.originalBytes) / Double(result.originalBytes) * 100)
                            : 0
                        HStack(spacing: 5) {
                            Text("\(FileConverter.formatBytes(result.originalBytes)) → \(FileConverter.formatBytes(result.outputBytes))")
                            Text("(\(delta > 0 ? "+" : "")\(delta)%)")
                                .foregroundStyle(delta <= 0 ? Color.green : Color.orange)
                            if let pixels = result.pixelSize {
                                Text("· \(Int(pixels.width))×\(Int(pixels.height))")
                            }
                        }
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    }
                }

                Spacer(minLength: 4)

                if let url = result.outputURL {
                    Button {
                        previewing = result
                    } label: { Image(systemName: "eye").font(.system(size: 9)) }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                        .help("Preview")

                    ShareButton(url: url, tint: theme.tint(.files))

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Image(systemName: "folder").font(.system(size: 9)) }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                        .help("Reveal in Finder")
                }
            }
        }
    }

    // MARK: - Preview

    /// An in-panel preview rather than QuickLook. `QLPreviewPanel` wants a
    /// controller on the responder chain of a key window, and this app's panel
    /// is deliberately non-activating -- wiring QuickLook into it would mean
    /// stealing focus from whatever the user is actually doing, to look at a
    /// thumbnail.
    private func previewSheet(_ result: FileConverter.Result, theme: Theme) -> some View {
        VStack(spacing: 8) {
            if let url = result.outputURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                NBEmptyState(symbol: "doc", title: "No preview available",
                             subtitle: "PDFs open in Preview — use Reveal.")
                    .frame(height: 160)
            }
            Text(result.outputURL?.lastPathComponent ?? result.sourceName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primaryText)
            HStack(spacing: 6) {
                if let url = result.outputURL {
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                    ShareButton(url: url, tint: theme.tint(.files))
                }
                Button("Close") { previewing = nil }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), filled: true, compact: true))
            }
        }
        .padding(14)
        .background(theme.panelBackground)
    }

    // MARK: - Actions

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        let chose = NotchPanelController.shared.runningModal { panel.runModal() }
        guard chose == .OK else { return }
        queue.append(contentsOf: panel.urls.filter { !queue.contains($0) })
        results = []
    }

    private func convert() {
        isConverting = true
        results = []
        FileConverter.convert(urls: queue, to: target, quality: quality,
                              maxPixels: size.maxPixels) { result in
            results.append(result)
        } completion: {
            isConverting = false
            queue = []
            let succeeded = results.filter { $0.error == nil }.count
            NotchArbiter.shared.flash("Converted \(succeeded)", symbol: "checkmark.circle.fill",
                                      module: .files,
                                      detail: size.maxPixels == nil
                                        ? target.name : "\(target.name) · \(size.name)")
        }
    }
}

/// Share, via the system's own sharing sheet.
///
/// SwiftUI's `ShareLink` renders a stock AppKit control that looks wrong inside
/// the drawn panel, so this hosts `NSSharingServicePicker` directly and hangs it
/// off an invisible anchor view. That also means it offers exactly the services
/// the user has configured -- AirDrop, Messages, Mail, whatever Shortcuts they
/// have added -- rather than a fixed list we would have to maintain.
struct ShareButton: View {
    let url: URL
    var tint: Color

    var body: some View {
        Button {
            let picker = NSSharingServicePicker(items: [url])
            // The picker needs a real on-screen view to attach to. Using the
            // panel's content view keeps it positioned over the notch panel
            // instead of at the screen origin.
            guard let host = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
            picker.show(relativeTo: .zero, of: host, preferredEdge: .minY)
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 9))
        }
        .buttonStyle(NBButtonStyle(tint: tint, compact: true))
        .help("Share")
    }
}

import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Disk Map: where the space went, and a safe way to get some of it back.
///
/// ## Three panels, one question
/// Left is the fixed context -- how full the disk is, and the categories that
/// are usually reclaimable. Middle is the browser: the current folder's
/// children, biggest first, as a list or a treemap. Right is what you selected
/// and what you can do about it.
///
/// ## The safety position
/// Nothing here deletes. Everything goes to the Bin via `trashItem`, which is
/// recoverable and which the Finder shows. An app that walks someone's home
/// directory and offers a Delete button had better be right every time;
/// offering Move to Bin instead means it only has to be useful.
struct DiskMapTabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case list = "List", map = "Map", largest = "Largest"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .list:    return "list.bullet"
            case .map:     return "square.grid.3x3.fill"
            case .largest: return "arrow.up.right.square"
            }
        }
    }

    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var model = DiskMapModel()
    @AppStorage("diskmap.mode") private var mode: Mode = .list

    var body: some View {
        let theme = themes.theme
        HStack(spacing: 0) {
            sidebar(theme)
                .frame(width: 196)

            Divider().overlay(theme.panelStroke)

            VStack(spacing: 0) {
                breadcrumbs(theme)
                Divider().overlay(theme.panelStroke)
                if model.directoryUnreadable {
                    permissionBanner(theme, folder: model.directory.lastPathComponent)
                }

                Group {
                    switch mode {
                    case .list:    entryList(theme)
                    case .map:     treemap(theme)
                    case .largest: largestFiles(theme)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let selected = model.selected {
                Divider().overlay(theme.panelStroke)
                inspector(selected, theme)
                    .frame(width: 208)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.sheet, value: model.selected)
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }

    // MARK: - Sidebar

    private func sidebar(_ theme: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let volume = model.storage.bootVolume {
                    NBCard(tint: .files, padding: 10) {
                        VStack(alignment: .leading, spacing: 7) {
                            NBSectionHeader(title: volume.name)
                            HStack(spacing: 10) {
                                ZStack {
                                    NBRing(progress: volume.usedFraction,
                                           tint: gaugeTint(volume.usedFraction, theme),
                                           lineWidth: 6, glow: theme.glowRadius(5))
                                    VStack(spacing: 0) {
                                        Text("\(Int(volume.usedFraction * 100))%")
                                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                                            .foregroundStyle(theme.primaryText)
                                        Text("used").font(.system(size: 7))
                                            .foregroundStyle(theme.secondaryText)
                                    }
                                }
                                .frame(width: 56, height: 56)

                                VStack(alignment: .leading, spacing: 3) {
                                    figure("Total", StorageService.format(volume.total), theme.secondaryText, theme)
                                    figure("Used", StorageService.format(volume.used), .orange, theme)
                                    figure("Free", StorageService.format(volume.available), .green, theme)
                                }
                            }
                        }
                    }
                }

                NBSectionHeader(title: "Go to")
                FlowRow(spacing: 4) {
                    ForEach(DiskMapModel.shortcuts()) { shortcut in
                        Button {
                            model.open(shortcut.url)
                        } label: {
                            Label(shortcut.name, systemImage: shortcut.symbol)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .buttonStyle(NBButtonStyle(
                            tint: theme.tint(.files),
                            filled: model.directory == shortcut.url, compact: true))
                    }
                }

                NBSectionHeader(title: "Quick wins",
                                trailing: model.categoryTotal > 0
                                    ? StorageService.format(model.categoryTotal) : nil)
                ForEach(model.categories) { category in
                    categoryRow(category, theme)
                }

                if !model.kindBreakdown.isEmpty {
                    NBSectionHeader(title: "In this folder")
                    kindBar(theme)
                    ForEach(model.kindBreakdown, id: \.kind) { entry in
                        HStack(spacing: 6) {
                            Circle().fill(entry.kind.color).frame(width: 6, height: 6)
                            Text(entry.kind.displayName)
                                .font(.system(size: 10)).foregroundStyle(theme.primaryText)
                            Spacer()
                            Text(StorageService.format(entry.bytes))
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func figure(_ label: String, _ value: String, _ tint: Color, _ theme: Theme) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                .frame(width: 30, alignment: .leading)
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(tint)
        }
    }

    private func gaugeTint(_ fraction: Double, _ theme: Theme) -> Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.8 { return .orange }
        return theme.tint(.files)
    }

    private func categoryRow(_ category: CleanupCategory, _ theme: Theme) -> some View {
        let size = model.categorySizes[category.id]
        return Button {
            model.open(category.url)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: category.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tint(.files))
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 0) {
                    Text(category.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.primaryText).lineLimit(1)
                    if let size {
                        Text(StorageService.format(size))
                            .font(.system(size: 9)).monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        Text("measuring…").font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText.opacity(0.7))
                    }
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(category.consequence)
    }

    private func kindBar(_ theme: Theme) -> some View {
        let total = max(1, model.kindBreakdown.reduce(0) { $0 + $1.bytes })
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(model.kindBreakdown, id: \.kind) { entry in
                    Rectangle()
                        .fill(entry.kind.color)
                        .frame(width: max(1, geo.size.width * CGFloat(Double(entry.bytes) / Double(total))))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
    }

    // MARK: - Breadcrumbs

    private func breadcrumbs(_ theme: Theme) -> some View {
        HStack(spacing: 5) {
            Button {
                model.goUp()
            } label: { Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                .disabled(!model.canGoUp)
                .help("Up one folder")

            Button {
                model.open(FileManager.default.homeDirectoryForCurrentUser)
            } label: { Image(systemName: "house").font(.system(size: 9)) }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                .help("Home")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(model.breadcrumbs, id: \.path) { crumb in
                        Button {
                            model.open(crumb)
                        } label: {
                            Text(DiskMapModel.crumbName(crumb))
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .foregroundStyle(crumb == model.directory ? theme.primaryText : theme.secondaryText)
                        if crumb != model.breadcrumbs.last {
                            Text("/").font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.5))
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if model.isScanning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("scanning").font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
            } else {
                Text("\(model.entries.count) items · \(StorageService.format(model.scannedBytes))"
                     + (model.freshnessNote.isEmpty ? "" : " · \(model.freshnessNote)"))
                    .font(.system(size: 9)).monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .help("Results are cached per folder and reused until the folder changes. Rescan forces a fresh walk.")
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 108)
            .onChange(of: mode) { _, new in
                if new == .largest && model.largestFiles.isEmpty { model.findLargestFiles() }
            }

            Button {
                model.rescan()
            } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9)) }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                .help("Rescan this folder")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // MARK: - List

    private func entryList(_ theme: Theme) -> some View {
        let peak = max(1, model.entries.first?.bytes ?? 1)
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.entries) { entry in
                    let isSelected = model.selected?.id == entry.id
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                            .resizable().frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(theme.primaryText).lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.fieldBackground)
                                    Capsule()
                                        .fill(FileKind.of(entry.url).color.opacity(entry.isDirectory ? 0.8 : 0.55))
                                        .frame(width: max(2, geo.size.width * CGFloat(Double(entry.bytes) / Double(peak))))
                                }
                            }
                            .frame(height: 4)
                        }

                        if entry.isUnreadable {
                            Label("no access", systemImage: "lock.fill")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .frame(width: 66, alignment: .trailing)
                                .help("macOS blocks this folder until you grant permission in Privacy & Security")
                        } else {
                            Text(StorageService.format(entry.bytes))
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 66, alignment: .trailing)
                        }

                        if entry.isDrillable {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(theme.secondaryText)
                        } else {
                            Color.clear.frame(width: 7)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? theme.tint(.files).opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                    .pointerCursor()
                    .onTapGesture { model.select(entry) }
                    .onTapGesture(count: 2) { model.drill(entry) }
                    .contextMenu { contextMenu(for: entry) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .overlay {
            if model.entries.isEmpty && !model.isScanning {
                NBEmptyState(symbol: "folder", title: "Nothing here",
                             subtitle: "This folder is empty, or its contents are not readable.")
            }
        }
    }

    // MARK: - Permissions

    /// Shown instead of a silent empty folder.
    ///
    /// The rename changed the bundle identifier, and TCC keys folder grants to
    /// the identifier -- so every permission the old name held was dropped.
    /// There is no API to re-request them quietly; an app can open the right
    /// settings pane and explain, and that is all.
    private func permissionBanner(_ theme: Theme, folder: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS will not let NotchScotch read \(folder)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text("Documents, Desktop and Downloads need explicit permission. Grant it and reopen this folder — nothing here is empty, we just cannot see it.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Files & Folders") { model.openPrivacySettings() }
                .buttonStyle(NBButtonStyle(tint: .orange, filled: true, compact: true))
            Button("Full Disk Access") { model.openFullDiskAccessSettings() }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                .help("Grants everything at once, including ~/Library — the folder most disk space actually hides in")
        }
        .padding(9)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.panelStroke).frame(height: 0.5)
        }
    }

    // MARK: - Largest files

    /// The question a disk tool is actually for: not which folder is big -- you
    /// usually know -- but which *file* is, which is almost never where you
    /// would look.
    private func largestFiles(_ theme: Theme) -> some View {
        Group {
            if model.isFindingLargest && model.largestFiles.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Walking \(model.directory.lastPathComponent)…")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    Text("This one is a full recursive scan, so it is the slow one.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.largestFiles.isEmpty {
                NBEmptyState(symbol: "arrow.up.right.square",
                             title: "Nothing found",
                             subtitle: "No readable files under this folder.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.largestFiles.enumerated()), id: \.element.id) { index, entry in
                            largestRow(index: index, entry: entry, theme: theme)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
        }
    }

    private func largestRow(index: Int, entry: DiskEntry, theme: Theme) -> some View {
        let isSelected = model.selected?.id == entry.id
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .frame(width: 18, alignment: .trailing)
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable().frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText).lineLimit(1)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(StorageService.format(entry.bytes))
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? theme.tint(.files).opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .pointerCursor()
        .onTapGesture { model.select(entry) }
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        .contextMenu { contextMenu(for: entry) }
    }

    // MARK: - Treemap

    private func treemap(_ theme: Theme) -> some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6)
            let tiles = Treemap.layout(model.treemapEntries, in: bounds) { Double($0.bytes) }

            ZStack(alignment: .topLeading) {
                // A light ground behind the tiles. Pale tiles on a black panel
                // read as holes punched in it; on a light ground they read as
                // pieces of one surface, which is what a treemap is.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.16))
                    .frame(width: geo.size.width - 4, height: geo.size.height - 4)
                    .offset(x: 2, y: 2)

                ForEach(tiles.indices, id: \.self) { index in
                    let tile = tiles[index]
                    tileView(tile, theme: theme)
                }
            }
            .overlay(alignment: .bottom) {
                if model.aggregatedCount > 0 {
                    Text("\(model.aggregatedCount) smaller items grouped as “Everything else”")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.bottom, 2)
                }
            }
        }
    }

    private func tileView(_ tile: Treemap.Tile<DiskEntry>, theme: Theme) -> some View {
        let entry = tile.item
        let isSelected = model.selected?.id == entry.id
        let base = FileKind.of(entry.url).tileColor
        // Folders get the full pastel; files sit a shade back, so the structure
        // of the folder is readable before any label is.
        let fill = entry.isDirectory ? base : base.opacity(0.78)
        // Labels need two lines to be worth printing, and a name clipped to
        // "Applica…" beside another clipped to "Applic…" tells you nothing.
        let showsLabel = tile.rect.width > 46 && tile.rect.height > 30
        let showsSize = tile.rect.width > 60 && tile.rect.height > 42

        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isSelected ? Color.black : Color.black.opacity(0.28),
                            lineWidth: isSelected ? 2 : 0.75)
            )
            .overlay(alignment: .topLeading) {
                if showsLabel {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.88))
                            .lineLimit(showsSize ? 2 : 1)
                        if showsSize {
                            Text(StorageService.format(entry.bytes))
                                .font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Color.black.opacity(0.62))
                        }
                    }
                    .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if entry.isDrillable && tile.rect.width > 34 && tile.rect.height > 34 {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.black.opacity(0.32))
                        .padding(3)
                }
            }
            .frame(width: max(1, tile.rect.width), height: max(1, tile.rect.height))
            .offset(x: tile.rect.minX, y: tile.rect.minY)
            .pointerCursor()
            .onTapGesture { model.select(entry) }
            .onTapGesture(count: 2) { model.drill(entry) }
            .help("\(entry.name) — \(StorageService.format(entry.bytes))")
            .contextMenu { contextMenu(for: entry) }
    }

    // MARK: - Inspector

    private func inspector(_ entry: DiskEntry, _ theme: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                        .resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.primaryText).lineLimit(2)
                        Text(entry.isBundle ? "Bundle" : (entry.isDirectory ? "Folder" : "File"))
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    }
                }

                Text(StorageService.format(entry.bytes))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                if model.scannedBytes > 0 {
                    Text(String(format: "%.1f%% of this folder",
                                Double(entry.bytes) / Double(model.scannedBytes) * 100))
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }

                if entry.isDirectory {
                    Text("\(entry.items) file\(entry.items == 1 ? "" : "s") inside")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }

                Text(entry.url.deletingLastPathComponent().path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(3).truncationMode(.head)

                Divider().overlay(theme.panelStroke)

                if entry.isDrillable {
                    Button {
                        model.drill(entry)
                    } label: {
                        Label("Look inside", systemImage: "arrow.right.circle")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files)))
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText))

                Button {
                    model.copyPath(entry)
                } label: {
                    Label("Copy path", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText))

                // Two-step, and it says what it will do. This is someone's home
                // directory; a single click that moves 30GB out of it needs a
                // sentence in between.
                if model.confirmingTrash?.id == entry.id {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Move \(entry.name) to the Bin? \(StorageService.format(entry.bytes)) comes back if you put it back.")
                            .font(.system(size: 10)).foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Button("Move to Bin") { model.trashSelected() }
                                .buttonStyle(NBButtonStyle(tint: .red, filled: true, compact: true))
                            Button("Cancel") { model.confirmingTrash = nil }
                                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                } else {
                    Button {
                        model.confirmingTrash = entry
                    } label: {
                        Label("Move to Bin", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(NBButtonStyle(tint: .red))
                }

                if let error = model.lastError {
                    Text(error).font(.system(size: 9)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Nothing here deletes. Items go to the Bin, where Finder can put them back.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: DiskEntry) -> some View {
        if entry.isDrillable {
            Button("Look inside") { model.drill(entry) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        Button("Copy path") { model.copyPath(entry) }
        Divider()
        Button("Move to Bin", role: .destructive) {
            model.select(entry)
            model.confirmingTrash = entry
        }
    }
}

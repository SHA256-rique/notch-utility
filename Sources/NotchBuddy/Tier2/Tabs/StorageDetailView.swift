import SwiftUI
import AppKit

/// Storage: how much room is left, and the Bin.
///
/// Opened from the Disk ring on the System tile, as a detail tab. It is not a
/// permanent dock tab because checking free space is something you do when
/// something has gone wrong, not every day -- and it is not a Home tile because
/// the System tile already shows the one number that belongs on a grid.
struct StorageDetailView: View {
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var service = StorageService()
    @State private var confirmingEmpty = false

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let boot = service.bootVolume {
                    headline(boot, theme)
                }

                binCard(theme)

                if service.volumes.count > 1 {
                    NBSectionHeader(title: "Other volumes")
                    ForEach(service.volumes.filter { !$0.isRoot }) { volume in
                        volumeRow(volume, theme)
                    }
                }

                if let error = service.lastError {
                    Text(error)
                        .font(.system(size: 9)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Free space is the figure Finder shows — it counts purgeable space the system will reclaim on demand, rather than the stricter number that understates what you can actually use.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .onAppear { service.activate() }
        .onDisappear { service.deactivate() }
    }

    // MARK: - Boot volume

    private func headline(_ volume: StorageService.Volume, _ theme: Theme) -> some View {
        NBCard(tint: .files) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        NBSectionHeader(title: volume.name)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(StorageService.format(volume.available))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .foregroundStyle(tint(for: volume, theme))
                            Text("available")
                                .font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(StorageService.format(volume.used)) used")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text("of \(StorageService.format(volume.total))")
                            .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    }
                }

                capacityBar(volume, theme, height: 12)

                HStack(spacing: 10) {
                    Text("\(Int(volume.usedFraction * 100))% full")
                        .font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                    if volume.purgeable > 0 {
                        Label("\(StorageService.format(volume.purgeable)) purgeable",
                              systemImage: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                            .help("Snapshots and cached files the system will free up automatically when it needs the room.")
                    }
                    Spacer()
                    Button("Storage settings") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.settings.Storage")!)
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.files), compact: true))
                }

                if volume.usedFraction > 0.9 {
                    // Worth saying out loud: below about 10% free, macOS starts
                    // behaving badly in ways that do not obviously point at the
                    // disk -- slow writes, failed updates, apps refusing to save.
                    Label("Under 10% free. macOS gets unreliable below this — updates fail and writes slow down.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func capacityBar(_ volume: StorageService.Volume, _ theme: Theme,
                             height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(tint(for: volume, theme))
                    .frame(width: max(3, geo.size.width * CGFloat(volume.usedFraction)))
                    .themeGlow(tint(for: volume, theme), radius: theme.glowRadius(5))
                // Purgeable rides on the end of the used block, hatched lighter,
                // because it is neither really used nor really free.
                if volume.purgeable > 0, volume.total > 0 {
                    let purgeableWidth = geo.size.width * CGFloat(Double(volume.purgeable) / Double(volume.total))
                    Capsule()
                        .fill(tint(for: volume, theme).opacity(0.35))
                        .frame(width: max(2, purgeableWidth))
                        .offset(x: max(3, geo.size.width * CGFloat(volume.usedFraction)) - purgeableWidth)
                }
            }
            .animation(Motion.dataTick, value: volume.usedFraction)
        }
        .frame(height: height)
    }

    private func tint(for volume: StorageService.Volume, _ theme: Theme) -> Color {
        if volume.usedFraction > 0.9 { return .red }
        if volume.usedFraction > 0.8 { return .orange }
        return theme.tint(.files)
    }

    // MARK: - Bin

    private func binCard(_ theme: Theme) -> some View {
        NBCard(tint: .files) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: service.bin.isEmpty ? "trash" : "trash.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(service.bin.isEmpty ? theme.secondaryText : theme.tint(.files))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        NBSectionHeader(title: "Bin")
                        if service.bin.isMeasuring {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Adding up…")
                                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                            }
                        } else if service.bin.isEmpty {
                            Text("Empty.")
                                .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(StorageService.format(service.bin.bytes))
                                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                                    .foregroundStyle(theme.primaryText)
                                Text("in \(service.bin.itemCount) item\(service.bin.itemCount == 1 ? "" : "s")")
                                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                            }
                        }
                    }

                    Spacer()

                    Button("Open") { service.openBin() }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                        .disabled(service.bin.isEmpty)

                    Button(confirmingEmpty ? "Cancel" : "Empty Bin") {
                        withAnimation(Motion.sheet) { confirmingEmpty.toggle() }
                    }
                    .buttonStyle(NBButtonStyle(tint: confirmingEmpty ? theme.secondaryText : .red,
                                               compact: true))
                    .disabled(service.bin.isEmpty && !confirmingEmpty)
                }

                // A two-step confirm rather than a system alert. An alert from a
                // non-activating panel has to steal focus to appear, which is
                // the one thing this app promises not to do — and this is a
                // permanent delete, so it cannot be a single click either.
                if confirmingEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.red)
                        Text("Permanently delete \(service.bin.itemCount) item\(service.bin.itemCount == 1 ? "" : "s"), freeing \(StorageService.format(service.bin.bytes))? This cannot be undone.")
                            .font(.system(size: 10)).foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Delete") {
                            service.emptyBin { _ in }
                            withAnimation(Motion.sheet) { confirmingEmpty = false }
                        }
                        .buttonStyle(NBButtonStyle(tint: .red, filled: true, compact: true))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
        }
    }

    // MARK: - Other volumes

    private func volumeRow(_ volume: StorageService.Volume, _ theme: Theme) -> some View {
        NBCard(tint: .files, padding: 9) {
            HStack(spacing: 10) {
                Image(systemName: volume.isRemovable ? "externaldrive" : "internaldrive")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.tint(.files))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(volume.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText).lineLimit(1)
                        Spacer()
                        Text("\(StorageService.format(volume.available)) free of \(StorageService.format(volume.total))")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    }
                    capacityBar(volume, theme, height: 6)
                }
            }
        }
        .contentShape(Rectangle())
        .pointerCursor()
        .onTapGesture { NSWorkspace.shared.open(volume.url) }
        .help("Open \(volume.name) in Finder")
    }
}

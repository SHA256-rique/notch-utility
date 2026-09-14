import SwiftUI
import AppKit

/// Home: the customisable small-widget grid.
///
/// Each widget owns its own activate/deactivate in `.onAppear`/`.onDisappear`.
/// Because `ExpandedPanelView` builds only the selected tab, leaving Home
/// genuinely destroys these views and therefore genuinely releases their
/// resources -- the stats consumer, the audio listener, the metric's hub slot.
struct HomeTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings
    @State private var isEditing = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 0) {
            HStack {
                NBSectionHeader(title: "Home")
                Button(isEditing ? "Done" : "Edit widgets") {
                    withAnimation(Motion.sheet) { isEditing.toggle() }
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.home), compact: true))
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                if isEditing {
                    widgetPicker(theme)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(settings.data.homeWidgets) { kind in
                        widget(kind)
                            .gridCellColumns(kind.isWide ? 2 : 1)
                            .overlay(alignment: .topTrailing) {
                                if isEditing { removeBadge(kind, theme: theme) }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .animation(Motion.sheet, value: settings.data.homeWidgets)
            }
        }
    }

    @ViewBuilder
    private func widget(_ kind: HomeWidgetKind) -> some View {
        switch kind {
        case .systemRings:  SystemRingsWidget()
        case .soundLight:   SoundLightWidget()
        case .screenTime:   ScreenTimeWidget()
        case .weather:      WeatherWidget()
        case .launch:       LaunchWidget()
        case .customMetric: CustomMetricWidget()
        }
    }

    private func removeBadge(_ kind: HomeWidgetKind, theme: Theme) -> some View {
        Button {
            settings.data.homeWidgets.removeAll { $0 == kind }
        } label: {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.red, .white)
        }
        .buttonStyle(.plain)
        .offset(x: 5, y: -5)
    }

    private func widgetPicker(_ theme: Theme) -> some View {
        let available = HomeWidgetKind.allCases.filter { !settings.data.homeWidgets.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            NBSectionHeader(title: "Add a widget")
            if available.isEmpty {
                Text("Every widget is already on your grid.")
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(available) { kind in
                        Button {
                            settings.data.homeWidgets.append(kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbol)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.home), compact: true))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - System rings

struct SystemRingsWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .system) {
            VStack(alignment: .leading, spacing: 8) {
                NBSectionHeader(title: "System")
                HStack(spacing: 10) {
                    ring("CPU", stats.snapshot.cpuPercent, theme.tint(.system), theme)
                    ring("RAM", stats.snapshot.memPercent, theme.tint(.home), theme)
                    ring("Disk", stats.snapshot.diskPercent, theme.tint(.files), theme)
                }
                Text("\(SystemStats.formatBytes(stats.snapshot.memUsedBytes)) of \(SystemStats.formatBytes(stats.snapshot.memTotalBytes))")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            }
        }
        // The full lifecycle contract in two lines. This is the pattern every
        // resource-holding widget in the app follows.
        .onAppear { SystemStats.shared.addConsumer() }
        .onDisappear { SystemStats.shared.removeConsumer() }
    }

    private func ring(_ label: String, _ percent: Double, _ tint: Color, _ theme: Theme) -> some View {
        VStack(spacing: 3) {
            ZStack {
                NBRing(progress: percent / 100, tint: tint, lineWidth: 4, glow: theme.glowRadius(4))
                Text("\(Int(percent))")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }
            .frame(width: 40, height: 40)
            Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(theme.secondaryText)
        }
    }
}

// MARK: - Sound & Light

struct SoundLightWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var controller = SoundLightController.shared

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .media) {
            VStack(alignment: .leading, spacing: 8) {
                NBSectionHeader(title: "Sound & Light")

                sliderRow(symbol: controller.isMuted || controller.volume < 0.01
                            ? "speaker.slash.fill"
                            : (controller.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"),
                          value: Binding(get: { controller.volume },
                                         set: { controller.volume = $0; controller.setVolume($0) }),
                          tint: theme.tint(.media),
                          theme: theme)
                    .onTapGesture(count: 2) { controller.setMuted(!controller.isMuted) }

                if controller.brightnessAvailable {
                    sliderRow(symbol: controller.brightness < 0.4 ? "sun.min.fill" : "sun.max.fill",
                              value: Binding(get: { controller.brightness },
                                             set: { controller.brightness = $0; controller.setBrightness($0) }),
                              tint: theme.tint(.notes),
                              theme: theme)
                } else {
                    // Honest about the limitation instead of showing a dead control.
                    Text("Brightness control unavailable on this display")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .onAppear { controller.activate() }
        .onDisappear { controller.deactivate() }
    }

    /// A HUD-replacement-style slider: the fill itself is the control, the way
    /// macOS's own volume HUD reads, rather than a stock track-and-knob.
    private func sliderRow(symbol: String, value: Binding<Float>, tint: Color, theme: Theme) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * CGFloat(value.wrappedValue)))
                        .themeGlow(tint, radius: theme.glowRadius(4))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let ratio = Float(max(0, min(1, drag.location.x / geo.size.width)))
                            withAnimation(Motion.interactive) { value.wrappedValue = ratio }
                        }
                )
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Screen Time

struct ScreenTimeWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var tracker = AppUsageTracker.shared
    @State private var showBreakdown = false

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .home) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    NBSectionHeader(title: "Screen Time")
                    Button(showBreakdown ? "Summary" : "Details") {
                        withAnimation(Motion.sheet) { showBreakdown.toggle() }
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.home), compact: true))
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppUsageTracker.humanDuration(tracker.today.total))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    if let change = tracker.percentChangeVsAverage {
                        Label(String(format: "%+.0f%%", change),
                              systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(change >= 0 ? Color.orange : Color.green)
                    }
                    Spacer()
                    if let top = tracker.mostUsedToday {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(top.name).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.primaryText).lineLimit(1)
                            Text(AppUsageTracker.humanDuration(top.seconds))
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                    }
                }

                if showBreakdown {
                    weekChart(theme)
                    VStack(spacing: 3) {
                        ForEach(tracker.topAppsToday.prefix(5), id: \.bundle) { app in
                            HStack(spacing: 6) {
                                Text(app.name).font(.system(size: 10)).lineLimit(1)
                                    .foregroundStyle(theme.primaryText)
                                Spacer(minLength: 6)
                                GeometryReader { geo in
                                    Capsule().fill(theme.tint(.home).opacity(0.55))
                                        .frame(width: geo.size.width * CGFloat(share(app.seconds)))
                                }
                                .frame(width: 60, height: 5)
                                Text(AppUsageTracker.humanDuration(app.seconds))
                                    .font(.system(size: 9)).monospacedDigit()
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                } else {
                    sparkline(theme)
                }
            }
        }
        .onAppear { tracker.refreshNow() }
    }

    private func share(_ seconds: Double) -> Double {
        let top = tracker.topAppsToday.first?.seconds ?? 1
        return top > 0 ? seconds / top : 0
    }

    private func sparkline(_ theme: Theme) -> some View {
        let days = tracker.last7Days
        let peak = max(1, days.map(\.total).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                Capsule()
                    .fill(index == days.count - 1 ? theme.tint(.home) : theme.tint(.home).opacity(0.35))
                    .frame(height: max(2, 22 * CGFloat(day.total / peak)))
            }
        }
        .frame(height: 22)
    }

    private func weekChart(_ theme: Theme) -> some View {
        let days = tracker.last7Days
        let peak = max(1, days.map(\.total).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == days.count - 1 ? theme.tint(.home) : theme.tint(.home).opacity(0.4))
                        .frame(height: max(2, 34 * CGFloat(day.total / peak)))
                    Text(String(day.date.suffix(2)))
                        .font(.system(size: 7)).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .frame(height: 46)
    }
}

// MARK: - Weather

struct WeatherWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var service = WeatherService.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .calendar) {
            VStack(alignment: .leading, spacing: 6) {
                NBSectionHeader(title: "Weather")
                switch service.status {
                case .ready(let reading):
                    HStack(spacing: 10) {
                        Image(systemName: WeatherService.symbol(for: reading.code, isDay: reading.isDay))
                            .font(.system(size: 24))
                            .foregroundStyle(theme.tint(.calendar))
                            .themeGlow(theme.tint(.calendar), radius: theme.glowRadius(6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Int(reading.temperature.rounded()))°")
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text(WeatherService.describe(reading.code))
                                .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("H \(Int(reading.high.rounded()))°  L \(Int(reading.low.rounded()))°")
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                            Text(reading.place).font(.system(size: 9))
                                .foregroundStyle(theme.secondaryText).lineLimit(1)
                        }
                    }
                case .loading, .locating:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    }
                case .needsLocation, .idle:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set a location to see weather.")
                            .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        Button("Use my location") { service.requestLocation() }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        Button("Retry") { service.refreshIfStale() }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.calendar), compact: true))
                    }
                }
            }
        }
        .onAppear { service.refreshIfStale() }
        .onDisappear { service.cancel() }
    }
}

// MARK: - Launch

struct LaunchWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .files) {
            VStack(alignment: .leading, spacing: 8) {
                NBSectionHeader(title: "Launch")
                if settings.data.launchShortcuts.isEmpty {
                    Text("Add apps you open often.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(settings.data.launchShortcuts, id: \.self) { path in
                        Button {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            NotchPanelController.shared.collapse()
                        } label: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                settings.data.launchShortcuts.removeAll { $0 == path }
                            }
                        }
                    }
                    Button { addShortcut() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                            .foregroundStyle(theme.secondaryText)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func addShortcut() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        // The panel needs a real activation or it opens behind everything, since
        // our panel is non-activating by design.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.data.launchShortcuts.contains(url.path) {
            settings.data.launchShortcuts.append(url.path)
        }
    }
}

// MARK: - Custom metric

struct CustomMetricWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @StateObject private var fetcher = MetricFetcher(
        config: Settings.shared.data.customMetricConfig
            ?? CustomTabConfig(kind: .metric, title: "Metric", symbol: "chart.bar"))

    var body: some View {
        let theme = themes.theme
        let config = settings.data.customMetricConfig
        NBCard(tint: .custom) {
            VStack(alignment: .leading, spacing: 6) {
                NBSectionHeader(title: config?.title ?? "Custom Metric")
                if config == nil || (config?.url.isEmpty ?? true) {
                    Text("Point this at any JSON endpoint in Settings → Custom metric.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                } else {
                    switch fetcher.state {
                    case .value(let text):
                        Text(text)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText).lineLimit(1).minimumScaleFactor(0.5)
                        if let updated = fetcher.lastUpdated {
                            Text(updated.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                    case .loading, .idle:
                        ProgressView().controlSize(.small)
                    case .failed(let message):
                        Text(message).font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText).lineLimit(2)
                    }
                }
            }
        }
        .onAppear { if settings.data.customMetricConfig?.url.isEmpty == false { fetcher.activate() } }
        .onDisappear { fetcher.deactivate() }
    }
}

/// Minimal flow layout for chip rows. SwiftUI has no built-in wrapping HStack
/// before macOS 13's Layout protocol, and this is small enough that pulling in a
/// dependency for it would be absurd.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: spacing) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

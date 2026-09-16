import SwiftUI
import AppKit

// MARK: - Revenue

/// Revenue: total over the last 30 days, change against the previous 30, and
/// the number of distinct paying customers. Tap for the detail view.
struct RevenueWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var controller: NotchPanelController
    @StateObject private var client = StripeClient()

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .api) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    NBSectionHeader(title: "Revenue")
                    if case .ready = client.state {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                switch client.state {
                case .needsKey:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect Stripe to see revenue.")
                            .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        Button("Open Settings") {
                            NotchPanelController.shared.openTab(.builtin(.settings))
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.api), compact: true))
                    }

                case .loading, .idle:
                    ProgressView().controlSize(.small)

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message).font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText).lineLimit(2)
                        Button("Retry") { client.refresh() }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.api), compact: true))
                    }

                case .ready(let summary):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(StripeClient.compact(summary.total,
                                                  symbol: settings.data.stripe.currencySymbol))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        NBChangeBadge(change: summary.percentChange)
                        Spacer()
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 9))
                        Text("\(summary.payingCustomers) paying")
                        Text("· last 30 days")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondaryText)

                    NBSparkBars(values: summary.daily, tint: theme.tint(.api), height: 20)
                }
            }
        }
        .contentShape(Rectangle())
        .pointerCursor(isReady)
        .onTapGesture { if isReady { controller.openDetail(.revenue) } }
        .onAppear { client.activate() }
        .onDisappear { client.deactivate() }
    }

    private var isReady: Bool {
        if case .ready = client.state { return true }
        return false
    }
}

struct RevenueDetailView: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings
    @StateObject private var client = StripeClient()

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch client.state {
                case .ready(let summary):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(StripeClient.full(summary.total, currencyCode: summary.currencyCode))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text("net of refunds, last 30 days")
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                        NBChangeBadge(change: summary.percentChange)
                        Spacer()
                        if let updated = client.lastUpdated {
                            Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                    }

                    HStack(spacing: 8) {
                        stat("Paying customers", "\(summary.payingCustomers)", theme)
                        stat("Charges", "\(summary.chargeCount)", theme)
                        stat("Previous 30d",
                             StripeClient.full(summary.previousTotal, currencyCode: summary.currencyCode),
                             theme)
                    }

                    NBCard(tint: .api) {
                        VStack(alignment: .leading, spacing: 8) {
                            NBSectionHeader(title: "Daily", trailing: "\(StripeClient.windowDays) days")
                            NBSparkBars(values: summary.daily, tint: theme.tint(.api),
                                        height: 90, highlightLast: false, spacing: 3)
                            HStack {
                                Text("\(StripeClient.windowDays) days ago")
                                Spacer()
                                Text("today")
                            }
                            .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                        }
                    }

                    Text("Figures come straight from the Stripe Charges API using the key in your Keychain. Nothing is cached off this Mac and nothing is sent anywhere else.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)

                case .needsKey:
                    NBEmptyState(symbol: "key", title: "No Stripe key",
                                 subtitle: "Add a restricted Stripe API key in Settings → Revenue. A read-only key scoped to charges is all this needs.")
                case .failed(let message):
                    NBEmptyState(symbol: "exclamationmark.triangle", title: "Could not load", subtitle: message)
                case .loading, .idle:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(12)
        }
        .onAppear { client.activate() }
        .onDisappear { client.deactivate() }
    }

    private func stat(_ label: String, _ value: String, _ theme: Theme) -> some View {
        NBCard(tint: .api, padding: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText).lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            }
        }
    }
}

// MARK: - Visitors

/// Visitors: live count, percent change, 30-day sparkline. Not on the default
/// grid -- it appears in "+ Add Widget" and only joins the grid once added.
struct VisitorsWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var service = VisitorsService()

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .docker) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    NBSectionHeader(title: "Visitors")
                    if case .ready = service.state {
                        // A live dot, because "live count" should look live.
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                            .themeGlow(.green, radius: theme.glowRadius(4))
                    }
                }

                switch service.state {
                case .unconfigured:
                    Text("Point this at your analytics in Settings → Visitors. Plausible, Umami and GoatCounter have presets.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)

                case .loading, .idle:
                    ProgressView().controlSize(.small)

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message).font(.system(size: 9))
                            .foregroundStyle(theme.secondaryText).lineLimit(2)
                        Button("Retry") { service.refresh() }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.docker), compact: true))
                    }

                case .ready(let reading):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(VisitorsService.compact(reading.current))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        NBChangeBadge(change: reading.percentChange)
                        Spacer()
                        if let updated = service.lastUpdated {
                            Text(updated.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                    }
                    if reading.series.isEmpty {
                        Text("No daily series at the configured path")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    } else {
                        NBSparkBars(values: reading.series, tint: theme.tint(.docker), height: 30)
                        Text("last \(reading.series.count) days")
                            .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .onAppear { service.activate() }
        .onDisappear { service.deactivate() }
    }
}

// MARK: - Claude usage

struct ClaudeUsageWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var controller: NotchPanelController
    @StateObject private var reader = ClaudeUsageReader()

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .ai) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    NBSectionHeader(title: "Claude Usage")
                    if case .ready = reader.state {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                switch reader.state {
                case .unavailable(let message):
                    Text(message).font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText).lineLimit(3)

                case .loading, .idle:
                    ProgressView().controlSize(.small)

                case .ready(let summary):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ClaudeUsageReader.compactTokens(summary.today.billableTokens))
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text("tokens today")
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                        Spacer()
                        streakBadge(summary.streakDays, theme)
                        weekChart(summary, theme)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .pointerCursor(isReady)
        .onTapGesture { if isReady { controller.openDetail(.claudeUsage) } }
        .onAppear { reader.activate() }
        .onDisappear { reader.deactivate() }
    }

    private var isReady: Bool {
        if case .ready = reader.state { return true }
        return false
    }

    private func streakBadge(_ days: Int, _ theme: Theme) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill").font(.system(size: 10))
                Text("\(days)").font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(days > 0 ? Color.orange : theme.secondaryText)
            Text("day streak").font(.system(size: 8)).foregroundStyle(theme.secondaryText)
        }
    }

    private func weekChart(_ summary: ClaudeUsageReader.Summary, _ theme: Theme) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(summary.week) { day in
                VStack(spacing: 2) {
                    let peak = max(1, summary.week.map(\.billableTokens).max() ?? 1)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(day.day == summary.today.day
                              ? theme.tint(.ai) : theme.tint(.ai).opacity(0.4))
                        .frame(width: 7,
                               height: max(2, 30 * CGFloat(Double(day.billableTokens) / Double(peak))))
                    Text(ClaudeUsageReader.weekdayInitial(for: day.day))
                        .font(.system(size: 7)).foregroundStyle(theme.secondaryText)
                }
            }
        }
    }
}

struct ClaudeUsageDetailView: View {
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var reader = ClaudeUsageReader()

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch reader.state {
                case .ready(let summary):
                    HStack(spacing: 8) {
                        stat("Today", ClaudeUsageReader.compactTokens(summary.today.billableTokens), theme)
                        stat("Streak", "\(summary.streakDays)d", theme)
                        stat("30 days", ClaudeUsageReader.compactTokens(summary.totalTokens30d), theme)
                        stat("Messages today", "\(summary.today.messages)", theme)
                    }

                    NBCard(tint: .ai) {
                        VStack(alignment: .leading, spacing: 8) {
                            NBSectionHeader(title: "This week")
                            HStack(alignment: .bottom, spacing: 8) {
                                ForEach(summary.week) { day in
                                    let peak = max(1, summary.week.map(\.billableTokens).max() ?? 1)
                                    VStack(spacing: 3) {
                                        Text(ClaudeUsageReader.compactTokens(day.billableTokens))
                                            .font(.system(size: 8)).monospacedDigit()
                                            .foregroundStyle(theme.secondaryText)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(day.day == summary.today.day
                                                  ? theme.tint(.ai) : theme.tint(.ai).opacity(0.4))
                                            .frame(height: max(3, 80 * CGFloat(Double(day.billableTokens) / Double(peak))))
                                        Text(ClaudeUsageReader.weekdayInitial(for: day.day))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(theme.secondaryText)
                                    }
                                }
                            }
                        }
                    }

                    NBCard(tint: .ai) {
                        VStack(alignment: .leading, spacing: 5) {
                            NBSectionHeader(title: "Today's breakdown")
                            breakdown("Fresh input", summary.today.inputTokens, theme)
                            breakdown("Output", summary.today.outputTokens, theme)
                            breakdown("Cache writes", summary.today.cacheWriteTokens, theme)
                            breakdown("Cache reads", summary.today.cacheReadTokens, theme)
                            Text("Cache reads are excluded from the headline figure — they are real tokens but they are cheap and large enough to hide everything else.")
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                                .padding(.top, 2)
                        }
                    }

                    if let busiest = summary.busiestDay, busiest.billableTokens > 0 {
                        Text("Busiest day in the last 30: \(busiest.day) — \(ClaudeUsageReader.compactTokens(busiest.billableTokens)) tokens.")
                            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    }

                    Text("Read from your local Claude Code transcripts in ~/.claude/projects. No API call, no account link.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)

                case .unavailable(let message):
                    NBEmptyState(symbol: "folder.badge.questionmark",
                                 title: "No transcripts", subtitle: message)
                case .loading, .idle:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(12)
        }
        .onAppear { reader.activate() }
        .onDisappear { reader.deactivate() }
    }

    private func stat(_ label: String, _ value: String, _ theme: Theme) -> some View {
        NBCard(tint: .ai, padding: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText).lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func breakdown(_ label: String, _ value: Int, _ theme: Theme) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundStyle(theme.primaryText)
            Spacer()
            Text(ClaudeUsageReader.compactTokens(value))
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(theme.secondaryText)
        }
    }
}

// MARK: - Now Playing

/// The Home-grid counterpart to the pill's Now Playing claim.
///
/// It does **not** call `start()`/`stop()` on the monitor. `NowPlayingMonitor`
/// is a Tier-1 subsystem owned by the app delegate and needed by the collapsed
/// pill; a Tier-2 tile stopping it on `onDisappear` would silently kill the
/// pill's media display. Observation is free -- it is the polling that costs,
/// and this monitor is notification-driven.
struct NowPlayingWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var monitor = NowPlayingMonitor.shared

    var body: some View {
        let theme = themes.theme
        NBCard(tint: .media) {
            VStack(alignment: .leading, spacing: 7) {
                NBSectionHeader(title: "Now Playing")

                if monitor.isEntitlementBlocked {
                    Text("macOS restricts the Now Playing API to signed apps on this system. The pill and this tile stay empty rather than guessing.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                } else if let track = monitor.track, !track.title.isEmpty {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.tint(.media).opacity(0.18))
                            Image(systemName: track.isPlaying ? "waveform" : "pause.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.tint(.media))
                                .themeGlow(theme.tint(.media), radius: theme.glowRadius(5))
                        }
                        .frame(width: 38, height: 38)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.primaryText).lineLimit(1)
                            Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                                .font(.system(size: 10))
                                .foregroundStyle(theme.secondaryText).lineLimit(1)
                            if track.duration > 0 {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.12))
                                        Capsule().fill(theme.tint(.media))
                                            .frame(width: max(2, geo.size.width * CGFloat(track.progress)))
                                    }
                                }
                                .frame(height: 3)
                                .animation(Motion.dataTick, value: track.progress)
                            }
                        }
                        Spacer(minLength: 0)
                        if !track.appName.isEmpty {
                            Text(track.appName)
                                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                        }
                    }
                } else {
                    // The app's rule: render nothing when there is nothing to
                    // say. No empty scrubber, no "—" placeholder.
                    Text("Nothing playing")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
            }
        }
    }
}

// MARK: - Quick timer

/// The Home-grid timer, as a circular dial rather than a numeric countdown.
///
/// The dial is the same `NBRing` the system stats and pomodoro use, so the three
/// round gauges on the grid are visibly one family. Dragging around the ring
/// sets the duration; the same ring then becomes the progress indicator while it
/// runs, which is why the control and the readout are the same object.
struct QuickTimerWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var engine = TimeEngine.shared
    @State private var dialMinutes: Double = 10
    /// Tracks a drag across the 12 o'clock boundary so a slow sweep past the top
    /// does not snap from 59 minutes back to 1.
    @State private var lastAngle: Double?

    /// The timer this tile owns, if it is still running. The tile deliberately
    /// drives one timer rather than the whole list -- the Time tab is where
    /// several at once belong.
    private var mine: NBTimer? {
        engine.timers.first { $0.label == Self.label }
    }

    private static let label = "Quick timer"
    private static let maxMinutes: Double = 60

    var body: some View {
        let theme = themes.theme
        let running = mine
        NBCard(tint: .time) {
            VStack(spacing: 7) {
                HStack {
                    NBSectionHeader(title: "Quick Timer")
                }
                ZStack {
                    // Minute ticks, so the dial reads as a dial and not as a
                    // progress bar that happens to be bent into a circle.
                    ForEach(0..<12, id: \.self) { index in
                        Capsule()
                            .fill(theme.secondaryText.opacity(index % 3 == 0 ? 0.55 : 0.25))
                            .frame(width: 1.5, height: index % 3 == 0 ? 5 : 3)
                            .offset(y: -32)
                            .rotationEffect(.degrees(Double(index) / 12 * 360))
                    }

                    NBRing(progress: running.map(\.progress) ?? (dialMinutes / Self.maxMinutes),
                           tint: running == nil ? theme.tint(.time) : theme.tint(.time).opacity(0.9),
                           lineWidth: 5,
                           glow: theme.glowRadius(6))
                        .frame(width: 58, height: 58)

                    VStack(spacing: 0) {
                        Text(running.map { TimeEngine.format($0.remaining) }
                             ?? "\(Int(dialMinutes))")
                            .font(.system(size: running == nil ? 20 : 15,
                                          weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.primaryText)
                        Text(running == nil ? "min" : (running!.isPaused ? "paused" : "left"))
                            .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                    }
                }
                .frame(width: 74, height: 74)
                .contentShape(Circle())
                .gesture(running == nil ? dialGesture : nil)

                HStack(spacing: 5) {
                    if let running {
                        Button {
                            engine.togglePause(running.id)
                        } label: {
                            Image(systemName: running.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))

                        Button("+1m") { engine.addMinute(running.id) }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))

                        Button {
                            engine.removeTimer(running.id)
                        } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                    } else {
                        ForEach([5, 10, 25], id: \.self) { preset in
                            Button("\(preset)") {
                                withAnimation(Motion.interactive) { dialMinutes = Double(preset) }
                            }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.time), compact: true))
                        }
                        Button("Start") {
                            engine.addTimer(label: Self.label, duration: dialMinutes * 60)
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.time), filled: true, compact: true))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { engine.addRedrawConsumer() }
        .onDisappear { engine.removeRedrawConsumer() }
    }

    /// Angle-based dial drag. `atan2` gives the bearing from the centre; the
    /// running delta is accumulated so a sweep past 12 o'clock keeps counting up
    /// instead of wrapping, which is the difference between a dial that feels
    /// like a physical knob and one that fights you.
    private var dialGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let centre = CGPoint(x: 37, y: 37)
                let dx = value.location.x - centre.x
                let dy = value.location.y - centre.y
                guard dx * dx + dy * dy > 64 else { return }   // ignore the dead zone at the hub
                var angle = atan2(dx, -dy) * 180 / .pi
                if angle < 0 { angle += 360 }

                if let previous = lastAngle {
                    var delta = angle - previous
                    if delta > 180 { delta -= 360 }
                    if delta < -180 { delta += 360 }
                    let minutes = dialMinutes + delta / 360 * Self.maxMinutes
                    withAnimation(Motion.interactive) {
                        dialMinutes = min(Self.maxMinutes, max(1, minutes.rounded()))
                    }
                }
                lastAngle = angle
            }
            .onEnded { _ in lastAngle = nil }
    }
}

// MARK: - Word of the day

struct DailyWordWidget: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var service = DailyWordService.shared
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var controller: NotchPanelController

    var body: some View {
        let theme = themes.theme
        let words = service.todaysWords
        NBCard(tint: .notes) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    NBSectionHeader(title: "Word of the Day")
                    if !words.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                if let word = words.first {
                    HStack(spacing: 5) {
                        Text(word.language.code)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(theme.tint(.notes).opacity(0.2)))
                            .foregroundStyle(theme.tint(.notes))
                        Text(word.partOfSpeech)
                            .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                        Spacer()
                        if words.count > 1 {
                            Text("+\(words.count - 1) more")
                                .font(.system(size: 8)).foregroundStyle(theme.secondaryText)
                        }
                    }
                    Text(word.term)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(word.meaning)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                } else {
                    Text("Pick a language in Settings → Word of the day.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .contentShape(Rectangle())
        .pointerCursor(!words.isEmpty)
        .onTapGesture { if !words.isEmpty { controller.openDetail(.dailyWord) } }
        .onAppear { service.activate() }
        .onDisappear { service.deactivate() }
    }
}

struct DailyWordDetailView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var service = DailyWordService.shared
    @State private var query = ""
    @State private var languageFilter: WordLanguage?
    @State private var expanded: Set<String> = []

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Label("\(service.streak) day streak", systemImage: "flame.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(service.streak > 0 ? Color.orange : theme.secondaryText)
                    Label("\(service.learnedCount) learned", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tint(.notes))
                    Label("\(service.glossaryCount) seen", systemImage: "books.vertical.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                    if !service.isShowingToday {
                        Button("Back to today") { service.backToToday() }
                            .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), compact: true))
                    }
                    Button {
                        service.previousWord()
                    } label: { Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                    Button {
                        service.nextWord()
                    } label: {
                        Label("Next word", systemImage: "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.notes), compact: true))
                }

                ForEach(service.todaysWords) { word in
                    card(word, theme)
                }

                if service.todaysWords.isEmpty {
                    NBEmptyState(symbol: "character.book.closed",
                                 title: "No languages selected",
                                 subtitle: "Choose one or more in Settings → Widgets → Word of the day.")
                }

                glossary(theme)
            }
            .padding(12)
        }
        .onAppear { service.recordToday() }
    }

    // MARK: - Glossary

    /// Everything the app has ever shown, newest first.
    ///
    /// Entries are filed on display rather than on an explicit save, because a
    /// glossary containing only the words someone remembered to press a button
    /// on is a worse record of what they have seen than no glossary at all.
    private func glossary(_ theme: Theme) -> some View {
        let words = service.glossary(matching: query, language: languageFilter)
        return VStack(alignment: .leading, spacing: 7) {
            Divider().overlay(theme.panelStroke).padding(.vertical, 2)

            HStack(spacing: 6) {
                NBSectionHeader(title: "Glossary", trailing: "\(words.count)")
                NBTextField(placeholder: "Search words or meanings…", text: $query)
                    .frame(maxWidth: 240)
            }

            let languages = service.enabledLanguages.isEmpty
                ? WordLanguage.allCases.filter { language in
                    service.seen.values.contains { $0.language == language.rawValue } }
                : service.enabledLanguages
            if languages.count > 1 {
                FlowRow(spacing: 5) {
                    Button("All") { languageFilter = nil }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.notes),
                                                   filled: languageFilter == nil, compact: true))
                    ForEach(languages) { language in
                        Button(language.displayName) {
                            languageFilter = languageFilter == language ? nil : language
                        }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.notes),
                                                   filled: languageFilter == language, compact: true))
                    }
                }
            }

            if words.isEmpty {
                Text(query.isEmpty
                     ? "Words you have been shown collect here automatically."
                     : "No matches.")
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }

            ForEach(words) { word in
                glossaryRow(word, theme)
            }
        }
    }

    private func glossaryRow(_ word: DailyWordService.SeenWord, _ theme: Theme) -> some View {
        let isOpen = expanded.contains(word.id)
        let full = service.entry(for: word)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(word.languageValue?.code ?? "??")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(theme.tint(.notes).opacity(0.2)))
                    .foregroundStyle(theme.tint(.notes))

                Text(word.term)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                Text(word.meaning)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if word.isLearned {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 9)).foregroundStyle(theme.tint(.notes))
                }
                Text(word.firstSeen.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 8)).foregroundStyle(theme.secondaryText.opacity(0.8))

                if let full {
                    Button {
                        service.speak(full)
                    } label: { Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)) }
                        .buttonStyle(.plain).pointerCursor()
                        .foregroundStyle(theme.secondaryText)
                }
            }

            if isOpen, let full {
                VStack(alignment: .leading, spacing: 2) {
                    Text(full.example)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                    Text(full.exampleTranslation)
                        .font(.system(size: 9))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.tint(.notes).opacity(0.4)).frame(width: 2)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
        .contentShape(Rectangle())
        .pointerCursor(full != nil)
        .onTapGesture {
            guard full != nil else { return }
            withAnimation(Motion.tabSwitch) {
                if isOpen { expanded.remove(word.id) } else { expanded.insert(word.id) }
            }
        }
    }

    private func card(_ word: WordEntry, _ theme: Theme) -> some View {
        NBCard(tint: .notes) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(word.language.displayName.uppercased())
                        .font(.system(size: 8, weight: .bold)).tracking(0.6)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(theme.tint(.notes).opacity(0.2)))
                        .foregroundStyle(theme.tint(.notes))
                    Spacer()
                    Button {
                        service.speak(word)
                    } label: { Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)) }
                        .buttonStyle(NBButtonStyle(tint: theme.tint(.media), compact: true))
                        .help("Hear it")
                    Button {
                        copy(word)
                    } label: { Image(systemName: "doc.on.doc").font(.system(size: 9)) }
                        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                        .help("Copy to clipboard")
                    Button {
                        service.toggleLearned(word)
                    } label: {
                        Image(systemName: service.isLearned(word) ? "checkmark.seal.fill" : "seal")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(NBButtonStyle(tint: service.isLearned(word) ? theme.tint(.notes) : theme.secondaryText,
                                               filled: service.isLearned(word), compact: true))
                    .help(service.isLearned(word) ? "Marked as learned" : "Mark as learned")
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(word.term)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    if !word.pronunciation.isEmpty {
                        Text(word.pronunciation)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Text(word.partOfSpeech)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }

                Text(word.meaning)
                    .font(.system(size: 12)).foregroundStyle(theme.primaryText)

                if Settings.shared.data.dailyWord.showExample {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(word.example)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text(word.exampleTranslation)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Capsule().fill(theme.tint(.notes).opacity(0.5)).frame(width: 2)
                    }
                }
            }
        }
    }

    private func copy(_ word: WordEntry) {
        ClipboardWatcher.shared.suppressNextChange()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(word.term) — \(word.meaning)", forType: .string)
        NotchArbiter.shared.flash("Copied", symbol: "doc.on.doc.fill",
                                  module: .notes, detail: word.term)
    }
}

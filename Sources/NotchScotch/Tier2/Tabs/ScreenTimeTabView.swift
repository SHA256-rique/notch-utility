import SwiftUI
import AppKit

/// Screen Time: today's total with its change and most-used app, the last seven
/// days as a bar chart with a daily average line, and the per-app breakdown.
///
/// This was previously folded into the Home tile behind a "Details" toggle. That
/// was the wrong home for it: a tile that can expand into a full report is no
/// longer a tile, and the grid had to reflow around it every time. The tile now
/// does the glance and this tab does the report -- which is the two-tier rule
/// applied one level down.
///
/// Everything here reads `AppUsageTracker`, which is event-driven off
/// `NSWorkspace.didActivateApplicationNotification`. There is no poll behind
/// this view at all; `refreshNow()` on appear exists only to close the segment
/// for the app that is in the foreground right now, so the total on screen
/// includes the seconds you are spending reading it.
struct ScreenTimeTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var tracker = AppUsageTracker.shared

    var body: some View {
        let theme = themes.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                headline(theme)
                weekChart(theme)
                breakdown(theme)

                Text("Tracked locally by watching which app is frontmost. Nothing about your usage leaves this Mac, and the tracker pauses while the screen is locked or the Mac is asleep.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            }
            .padding(12)
        }
        .onAppear { tracker.refreshNow() }
    }

    // MARK: - Today

    private func headline(_ theme: Theme) -> some View {
        NBCard(tint: .home) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    NBSectionHeader(title: "Today")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(AppUsageTracker.humanDuration(tracker.today.total))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        // Up is bad for screen time, so the badge's colours are
                        // inverted relative to revenue and visitors.
                        NBChangeBadge(change: tracker.percentChangeVsAverage, inverted: true)
                    }
                    Text("versus your six-day average")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }

                Spacer()

                if let top = tracker.mostUsedToday {
                    VStack(alignment: .trailing, spacing: 3) {
                        NBSectionHeader(title: "Most used")
                        Text(top.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.primaryText).lineLimit(1)
                        Text(AppUsageTracker.humanDuration(top.seconds))
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(theme.tint(.home))
                    }
                }
            }
        }
    }

    // MARK: - Week

    private func weekChart(_ theme: Theme) -> some View {
        let days = tracker.last7Days
        let peak = max(1, days.map(\.total).max() ?? 1)
        // Average across days that actually have data. Including a run of empty
        // days -- a fresh install, a week away -- would drag the line to the
        // floor and make every real bar tower over a meaningless reference.
        let counted = days.filter { $0.total > 0 }
        let average = counted.isEmpty ? 0 : counted.reduce(0) { $0 + $1.total } / Double(counted.count)
        let chartHeight: CGFloat = 96

        return NBCard(tint: .home) {
            VStack(alignment: .leading, spacing: 8) {
                NBSectionHeader(title: "Last 7 days",
                                trailing: "avg \(AppUsageTracker.humanDuration(average))")

                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                            VStack(spacing: 3) {
                                Text(AppUsageTracker.humanDuration(day.total))
                                    .font(.system(size: 8)).monospacedDigit()
                                    .foregroundStyle(theme.secondaryText)
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(index == days.count - 1
                                          ? theme.tint(.home) : theme.tint(.home).opacity(0.4))
                                    .frame(height: max(2, chartHeight * CGFloat(day.total / peak)))
                                Text(Self.weekdayInitial(day.date))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(index == days.count - 1
                                                     ? theme.primaryText : theme.secondaryText)
                            }
                        }
                    }

                    // The average line sits above the bars, offset up by the
                    // weekday label row so it lands in the bars' own coordinate
                    // space rather than floating over the axis.
                    if average > 0 {
                        Rectangle()
                            .fill(theme.tint(.time).opacity(0.7))
                            .frame(height: 1)
                            .overlay(alignment: .trailing) {
                                Text("avg")
                                    .font(.system(size: 7, weight: .semibold))
                                    .foregroundStyle(theme.tint(.time))
                                    .offset(y: -6)
                            }
                            .offset(y: -(14 + chartHeight * CGFloat(average / peak)))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: chartHeight + 28, alignment: .bottom)
            }
        }
    }

    // MARK: - Per app

    private func breakdown(_ theme: Theme) -> some View {
        let apps = tracker.topAppsToday
        let peak = max(1, apps.first?.seconds ?? 1)
        return NBCard(tint: .home) {
            VStack(alignment: .leading, spacing: 6) {
                NBSectionHeader(title: "By app", trailing: "today")
                if apps.isEmpty {
                    Text("Nothing recorded yet today.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
                ForEach(apps, id: \.bundle) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: app.bundle))
                            .resizable().frame(width: 16, height: 16)
                        Text(app.name)
                            .font(.system(size: 11)).lineLimit(1)
                            .foregroundStyle(theme.primaryText)
                            .frame(width: 120, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                Capsule()
                                    .fill(theme.tint(.home).opacity(0.65))
                                    .frame(width: max(3, geo.size.width * CGFloat(app.seconds / peak)))
                            }
                        }
                        .frame(height: 7)
                        Text(AppUsageTracker.humanDuration(app.seconds))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Icons are looked up by bundle id and cached, because `NSWorkspace`'s
    /// lookup hits the Launch Services database and this list redraws on every
    /// tick while the tab is open.
    private static var iconCache: [String: NSImage] = [:]

    private static func icon(for bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[bundleID] = image
        return image
    }

    private static func weekdayInitial(_ dayKey: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: dayKey) else { return "" }
        let out = DateFormatter()
        out.dateFormat = "EEE"
        return out.string(from: date)
    }
}

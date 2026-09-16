import SwiftUI

/// Tier 2. The expanded surface: a header, a tab bar, and exactly one tab body.
///
/// ## The teardown guarantee, made structural
/// Only the selected tab's view is ever constructed. There is no `ZStack` of all
/// twelve tabs with opacity 0, and no `TabView` (which keeps every page alive).
/// A `switch` inside a `Group` means SwiftUI destroys the previous tab's view
/// tree on switch, which fires its `.onDisappear` -- and that is where each tab
/// unregisters from the polling hub, closes its sockets and drops its buffers.
///
/// This is why "teardown on close" is not a discipline the authors have to
/// remember: the view lifecycle enforces it. A tab that forgets to clean up in
/// `onDisappear` is the only way to leak, and there is exactly one place per tab
/// to check.
struct ExpandedPanelView: View {
    @EnvironmentObject private var controller: NotchPanelController
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var arbiter: NotchArbiter
    @EnvironmentObject private var settings: Settings

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 0) {
            header(theme)
            Divider().overlay(theme.panelStroke)
            HStack(spacing: 0) {
                tabBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The word rail runs down the side of every tab rather than
                // living on Home, because a word you have to go looking for is
                // not a word a day.
                if settings.data.wordRailEnabled {
                    WordRailView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.sheet, value: settings.data.wordRailExpanded)

            // The dock lives at the bottom now. See TabDockView for why: the
            // top of this panel is behind the camera housing, and macOS lets
            // nobody draw there.
            TabDockView()
        }
        .background(
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(theme.panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                        .stroke(theme.panelStroke, lineWidth: 1)
                )
                .themeGlow(theme.accent, radius: theme.glowRadius(14))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Header

    /// The top strip, laid out **around** the camera housing rather than across
    /// it: the title on the left shoulder, pin and close on the right, and a
    /// reserved gap in the middle that nothing is allowed into.
    ///
    /// The gap is not cosmetic. On a notched MacBook the panel's top edge is at
    /// the very top of the screen, so its horizontal centre is behind hardware.
    /// Anything placed there is not dimmed or clipped -- it is simply not on the
    /// screen, and the user has no way to know it exists.
    private func header(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            Text(activeTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)

            // Persistent claims stay reachable while a tab is open -- the brief
            // requires that every active persistent item is visible on expand,
            // not just the one winning the pill.
            ForEach(arbiter.allPersistent.prefix(2)) { claim in
                HStack(spacing: 3) {
                    Image(systemName: claim.symbol).font(.system(size: 8, weight: .bold))
                    Text(claim.text).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(theme.tint(claim.module))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(theme.tint(claim.module).opacity(0.15)))
                .pointerCursor()
                .onTapGesture { controller.openTab(.builtin(.time)) }
                .help(claim.detail ?? claim.text)
            }

            // The reserved centre. `notchGap` is measured, not guessed, so it
            // is correct on a 14", a 16" and an external display alike.
            Spacer(minLength: 8)
            Color.clear.frame(width: notchGap, height: 1)
            Spacer(minLength: 8)

            Button {
                controller.togglePin()
            } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(controller.isPinned ? theme.accent : theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(controller.isPinned ? "Unpin (panel will auto-collapse)" : "Pin open")

            Button {
                controller.collapse()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Collapse")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Width to keep clear in the middle of the header. Zero when the panel is
    /// not hanging off a physical notch, because then there is nothing to avoid
    /// and a hole in the middle of the strip would just be a hole.
    private var notchGap: CGFloat {
        let layout = ScreenGeometry.current()
        guard layout.hasPhysicalNotch, controller.presentation == .notch else { return 0 }
        // A little wider than the cutout: the housing has a rounded skirt, and
        // text that ends exactly at its edge still reads as cut off.
        return layout.notchRect.width + 16
    }

    private var activeTitle: String {
        switch controller.activeTab {
        case .builtin(let id):    return id.title
        case .detail(let detail): return detail.title
        case .custom(let uuid):
            return settings.data.customTabs.first { $0.id == uuid }?.title ?? "Tab"
        case .none:               return "Home"
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var tabBody: some View {
        Group {
            switch controller.activeTab {
            case .builtin(let id):
                builtinTab(id)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .id(id)          // forces teardown/rebuild across switches
            case .custom(let uuid):
                if let config = settings.data.customTabs.first(where: { $0.id == uuid }) {
                    CustomTabView(config: config)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                        .id(uuid)
                } else {
                    NBEmptyState(symbol: "questionmark.square.dashed",
                                 title: "Tab no longer configured")
                }
            case .detail(let detail):
                detailTab(detail)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .id(detail)
            case .none:
                HomeTabView()
                    .transition(.opacity)
            }
        }
        .animation(Motion.tabSwitch, value: controller.activeTab)
    }

    @ViewBuilder
    private func builtinTab(_ id: TabID) -> some View {
        switch id {
        case .home:     HomeTabView()
        case .time:     TimeTabView()
        case .snippets: SnippetsTabView()
        case .notes:    NotesTabView()
        case .calendar: CalendarTabView()
        case .files:    FilesTabView()
        case .diskMap:  DiskMapTabView()
        case .api:      APITesterTabView()
        case .terminal: TerminalTabView()
        case .ai:       AIChatTabView()
        case .message:  MessageTabView()
        case .teleprompter: TeleprompterTabView()
        case .settings: SettingsTabView()
        }
    }

    /// Detail bodies get the same treatment as built-ins: exactly one is ever
    /// constructed, and `.id(detail)` on the branch above forces a full teardown
    /// when the user switches away. Closing a detail destroys it outright.
    @ViewBuilder
    private func detailTab(_ detail: DetailTab) -> some View {
        switch detail {
        case .screenTime:  ScreenTimeTabView()
        case .revenue:     RevenueDetailView()
        case .claudeUsage: ClaudeUsageDetailView()
        case .dailyWord:   DailyWordDetailView()
        case .storage:     StorageDetailView()
        }
    }
}

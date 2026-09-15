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
            tabBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func header(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            TabBarView()
            Spacer(minLength: 4)

            // Persistent claims stay reachable while a tab is open -- the brief
            // requires that every active persistent item is visible on expand,
            // not just the one winning the pill.
            ForEach(arbiter.allPersistent.prefix(3)) { claim in
                HStack(spacing: 3) {
                    Image(systemName: claim.symbol).font(.system(size: 8, weight: .bold))
                    Text(claim.text).font(.system(size: 9, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(theme.tint(claim.module))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(theme.tint(claim.module).opacity(0.15)))
                .onTapGesture { controller.openTab(.builtin(.time)) }
                .help(claim.detail ?? claim.text)
            }

            Button {
                controller.togglePin()
            } label: {
                Image(systemName: controller.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(controller.isPinned ? theme.accent : theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help(controller.isPinned ? "Unpin (panel will auto-collapse)" : "Pin open")

            Button {
                controller.collapse()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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
        case .screenTime: ScreenTimeTabView()
        case .snippets: SnippetsTabView()
        case .notes:    NotesTabView()
        case .calendar: CalendarTabView()
        case .files:    FilesTabView()
        case .api:      APITesterTabView()
        case .docker:   DockerTabView()
        case .terminal: TerminalTabView()
        case .ai:       AIChatTabView()
        case .message:  MessageTabView()
        case .settings: SettingsTabView()
        }
    }
}

/// Horizontally scrolling icon strip. Built-ins first, then user-configured
/// custom tabs, in the order stored in settings.
struct TabBarView: View {
    @EnvironmentObject private var controller: NotchPanelController
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var settings: Settings

    var body: some View {
        let theme = themes.theme
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(orderedBuiltins, id: \.self) { id in
                    tabButton(symbol: id.symbol,
                              title: id.title,
                              tint: theme.tint(id.tint),
                              isActive: controller.activeTab == .builtin(id)) {
                        controller.openTab(.builtin(id))
                    }
                }
                ForEach(settings.data.customTabs) { config in
                    tabButton(symbol: config.symbol.isEmpty ? config.kind.symbol : config.symbol,
                              title: config.title,
                              tint: theme.tint(.custom),
                              isActive: controller.activeTab == .custom(config.id)) {
                        controller.openTab(.custom(config.id))
                    }
                }
            }
        }
    }

    private var orderedBuiltins: [TabID] {
        settings.data.enabledTabs.compactMap(TabID.init(rawValue:))
    }

    private func tabButton(symbol: String, title: String, tint: Color,
                           isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 22)
                .foregroundStyle(isActive ? tint : themes.theme.secondaryText)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? tint.opacity(0.18) : .clear)
                )
                .themeGlow(tint, radius: isActive ? themes.theme.glowRadius(5) : 0)
        }
        .buttonStyle(.plain)
        .help(title)
        .animation(Motion.tabSwitch, value: isActive)
    }
}

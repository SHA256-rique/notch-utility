import AppKit
import SwiftUI
import Combine

/// Owns the single NSPanel, the collapsed/expanded state machine, and -- most
/// importantly -- it is the **only** caller of `WidgetPollingHub.setActive`.
///
/// Centralising that call is what makes the power guarantee auditable: there is
/// exactly one place in the codebase where background work can be switched on,
/// and it is driven purely by "is the user actually looking at this".
@MainActor
final class NotchPanelController: NSObject, ObservableObject {
    static let shared = NotchPanelController()

    // MARK: - Published state (read by the SwiftUI tree)

    enum PanelState: Equatable { case collapsed, expanded }

    @Published private(set) var state: PanelState = .collapsed
    @Published private(set) var isPinned = false
    @Published var activeTab: ActiveTab? = nil
    /// Detail tabs currently open, in the order they were opened.
    ///
    /// Not persisted, on purpose. A relaunch starts with none open, because none
    /// of these is where the user left off working -- restoring a storage report
    /// from three days ago would be clutter presented as continuity.
    @Published private(set) var openDetails: [DetailTab] = []
    @Published private(set) var isHovering = false

    // MARK: - Geometry

    /// Resting pill: just wider than the physical notch so its rounded corners
    /// read as part of the hardware rather than a separate floating chip.
    ///
    /// A toast-style transient hangs *below* the pill, so the window has to grow
    /// to make room for it -- the pill itself keeps its own height, enforced in
    /// `CollapsedPillView`, or the notch would visibly swell every time
    /// something was copied. The extra width is generous because a toast is
    /// sized to its text and a clipped toast is worse than a wide window that
    /// is mostly transparent and click-through anyway.
    private var collapsedSize: CGSize {
        let notchWidth = layout.hasPhysicalNotch ? layout.notchRect.width : 200
        let pillHeight = max(layout.notchRect.height, 32) + (arbiter.hasUrgentContent ? 6 : 0)
        let toasting = arbiter.transient != nil && Settings.shared.data.transientStyle == .toast
        return CGSize(width: notchWidth + (arbiter.hasUrgentContent ? 260 : 24)
                             + (toasting ? 120 : 0),
                      height: pillHeight + (toasting ? 44 : 0))
    }
    /// Fallback for a tab that has not declared a size, and for the moment
    /// between expanding and a tab being selected.
    private static let defaultExpandedSize = CGSize(width: 680, height: 440)

    /// The size the current tab asked for, clamped to the screen.
    ///
    /// Clamping matters: a 1280x800 MacBook Air with the menu bar visible has
    /// about 770pt of usable height, and the Terminal tab asks for 510 -- fine,
    /// but a future tab asking for 900 would push the panel off the bottom of
    /// the display with no way to reach the close button.
    private var expandedSize: CGSize {
        let wanted: CGSize
        switch activeTab {
        case .builtin(let id):    wanted = id.preferredSize
        case .detail(let detail): wanted = detail.preferredSize
        case .custom, .none:      wanted = Self.defaultExpandedSize
        }
        let usable = layout.screen.visibleFrame
        return CGSize(width: min(wanted.width, usable.width - 32),
                      height: min(wanted.height, usable.height - 12))
    }

    // MARK: - Internals

    private var panel: NotchPanel!
    private var layout: ScreenGeometry.Layout
    private let arbiter = NotchArbiter.shared
    private var cancellables = Set<AnyCancellable>()
    private var hoverExpandWork: DispatchWorkItem?
    private var hoverCollapseWork: DispatchWorkItem?

    private override init() {
        self.layout = ScreenGeometry.current()
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        let frame = ScreenGeometry.panelFrame(for: collapsedSize, layout: layout)
        panel = NotchPanel(contentRect: frame)

        let root = NotchRootView()
            .environmentObject(self)
            .environmentObject(arbiter)
            .environmentObject(ThemeManager.shared)
            .environmentObject(Settings.shared)

        let hosting = NSHostingView(rootView: root)
        // The hosting view must not clip: the expanded panel draws a shadow and
        // the pill draws a glow that extend past the content bounds.
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setHiddenFromCapture(Settings.shared.data.hideFromScreenRecordingPanel)
        panel.orderFrontRegardless()

        observeScreenChanges()
        observeArbiterForResize()
        Log.panel.info("panel started, notch=\(self.layout.hasPhysicalNotch)")
    }

    // MARK: - Hover

    /// Called from the SwiftUI `onHover` on the pill's tracking area.
    ///
    /// Both directions are debounced. Expanding on the raw event makes the notch
    /// fire every time the cursor crosses the top of the screen on its way to a
    /// menu; collapsing on the raw event makes the panel flicker shut whenever
    /// the cursor grazes the gap between two tab buttons.
    func hoverChanged(_ inside: Bool) {
        isHovering = inside
        guard Settings.shared.data.hoverToExpand else { return }

        hoverExpandWork?.cancel()
        hoverCollapseWork?.cancel()

        if inside {
            guard state == .collapsed else { return }
            let work = DispatchWorkItem { [weak self] in self?.expand() }
            hoverExpandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.data.hoverExpandDelay, execute: work)
        } else {
            guard state == .expanded, !isPinned else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovering, !self.isPinned else { return }
                self.collapse()
            }
            hoverCollapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.data.hoverCollapseDelay, execute: work)
        }
    }

    // MARK: - State transitions

    func expand(selecting tab: ActiveTab? = nil) {
        if let tab { openTab(tab) }
        guard state != .expanded else { return }
        // A transient toast exists to convey something while the panel is shut.
        // Once the full UI is on screen it is just noise in the header.
        arbiter.clearTransient()
        state = .expanded
        applyFrame(expandedSize, animated: true)
        updateHubActivation()
    }

    func collapse() {
        guard state != .collapsed else { return }
        // Teardown first, resize second: a tab's onDisappear must run while the
        // view tree still exists.
        closeActiveTab()
        state = .collapsed
        isPinned = false
        panel.wantsKeyboardFocus = false
        applyFrame(collapsedSize, animated: true)
        updateHubActivation()
    }

    func toggle() {
        state == .collapsed ? expand() : collapse()
    }

    /// Global hotkey target: always ends in the expanded state and pins, so the
    /// user can let go of the keyboard without it snapping shut.
    func forceExpandFromHotKey() {
        if state == .expanded && isPinned {
            collapse()
        } else {
            isPinned = true
            expand(selecting: activeTab ?? .builtin(.home))
        }
    }

    func togglePin() {
        isPinned.toggle()
        // Pinning counts as "attended", so the hub may need to start even though
        // the cursor has left the panel.
        updateHubActivation()
    }

    // MARK: - Tabs

    func openTab(_ tab: ActiveTab) {
        guard activeTab != tab else { return }
        // Closing the previous tab first guarantees its timers/watchers are gone
        // before the next tab registers its own.
        closeActiveTab()
        activeTab = tab
        if case .builtin(let id) = tab, id.needsKeyboardFocus {
            panel.wantsKeyboardFocus = true
        } else {
            panel.wantsKeyboardFocus = false
        }
        // Resize to whatever the new tab wants. Only while expanded: opening a
        // tab from the status-bar menu sets `activeTab` before `expand()` runs,
        // and resizing a collapsed pill to 800x510 would be a brief, very
        // visible flash of an empty window.
        if state == .expanded { applyFrame(expandedSize, animated: true) }
        Log.tabs.debug("open tab \(String(describing: tab), privacy: .public)")
    }

    func closeActiveTab() {
        guard activeTab != nil else { return }
        Log.tabs.debug("close tab \(String(describing: self.activeTab), privacy: .public)")
        activeTab = nil
        panel.wantsKeyboardFocus = false
    }

    // MARK: - Detail tabs

    /// Where to go when the active detail is closed.
    ///
    /// One slot, not a stack. A back-stack would mean closing a detail could
    /// land you somewhere you have no memory of being, three steps ago; the
    /// useful behaviour is "put me back where I opened this from", and that is
    /// one value.
    private var detailReturnTab: ActiveTab?

    /// Opens a detail tab, or focuses it if it is already open.
    ///
    /// Re-opening an already-open detail deliberately does not reset it -- the
    /// dock is showing it, so the user's model is that it is still the same tab.
    func openDetail(_ detail: DetailTab) {
        if !openDetails.contains(detail) {
            openDetails.append(detail)
        }
        // Only remember a return target when coming from something that is not
        // itself a detail; otherwise closing two details in a row would bounce
        // between them.
        if case .detail = activeTab {} else {
            detailReturnTab = activeTab
        }
        openTab(.detail(detail))
    }

    /// Closes a detail tab. If it was the active one, returns to wherever it was
    /// opened from -- or to the next remaining detail, or Home.
    func closeDetail(_ detail: DetailTab) {
        let wasActive = activeTab == .detail(detail)
        openDetails.removeAll { $0 == detail }

        guard wasActive else { return }
        if let returnTab = detailReturnTab, isStillValid(returnTab) {
            detailReturnTab = nil
            openTab(returnTab)
        } else if let next = openDetails.last {
            openTab(.detail(next))
        } else {
            openTab(.builtin(.home))
        }
    }

    func closeAllDetails() {
        if case .detail = activeTab { openTab(.builtin(.home)) }
        openDetails.removeAll()
    }

    /// A remembered return target can go stale -- a custom tab deleted while a
    /// detail was open, or a built-in hidden from the dock.
    private func isStillValid(_ tab: ActiveTab) -> Bool {
        switch tab {
        case .builtin(let id):
            return Settings.shared.data.enabledTabs.contains(id.rawValue)
        case .custom(let uuid):
            return Settings.shared.data.customTabs.contains { $0.id == uuid }
        case .detail(let detail):
            return openDetails.contains(detail)
        }
    }

    // MARK: - The power rule, in one place

    /// The panel counts as "attended" when it is expanded, or pinned open and the
    /// user has allowed pinned-counts-as-attended. With battery saver off, the
    /// user has explicitly opted into stats continuing to update while collapsed.
    private func updateHubActivation() {
        let s = Settings.shared.data
        let attended = (state == .expanded) || (isPinned && s.pinnedCountsAsAttended)
        WidgetPollingHub.shared.setActive(attended || !s.batterySaver)
    }

    /// Re-evaluated when the user flips the battery-saver switch.
    func settingsChanged() {
        updateHubActivation()
        panel?.setHiddenFromCapture(Settings.shared.data.hideFromScreenRecordingPanel)
    }

    // MARK: - Frame animation

    /// The window resize and the SwiftUI spring must agree, or you get the
    /// rubber-banding this app category is known for. The approach: the window
    /// snaps to its new frame with no AppKit animation at all (`animationBehavior
    /// = .none`, `animate: false` on setFrame) and the *content* animates inside
    /// it with a SwiftUI spring. The window is therefore always at least as large
    /// as the content needs, and the visible motion is entirely the spring.
    private func applyFrame(_ size: CGSize, animated: Bool) {
        layout = ScreenGeometry.current()
        let frame = ScreenGeometry.panelFrame(for: size, layout: layout)
        panel.setFrame(frame, display: false, animate: false)
        if let hosting = panel.contentView {
            hosting.frame = CGRect(origin: .zero, size: frame.size)
        }
    }

    /// The pill's resting width depends on whether anything holds the notch, so
    /// a timer starting has to grow the window even though we never left the
    /// collapsed state.
    private func observeArbiterForResize() {
        arbiter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.state == .collapsed else { return }
                self.applyFrame(self.collapsedSize, animated: true)
            }
            .store(in: &cancellables)
    }

    private func observeScreenChanges() {
        // Docking/undocking a display, or a resolution change, moves the notch.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.layout = ScreenGeometry.current()
                self.applyFrame(self.state == .collapsed ? self.collapsedSize : self.expandedSize, animated: false)
                Log.panel.info("screen parameters changed, repositioned")
            }
            .store(in: &cancellables)
    }

    // MARK: - Capture / misc

    var window: NotchPanel? { panel }
}

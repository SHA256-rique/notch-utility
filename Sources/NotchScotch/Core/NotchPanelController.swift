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

    // MARK: - Presentation

    /// Notch or orb, resolved for the display the panel is currently on.
    ///
    /// `auto` is the default and means "notch where there is one, orb where
    /// there is not" -- which is the honest reading of both. The explicit modes
    /// exist because someone may genuinely prefer an orb on their MacBook, or a
    /// menu-bar tab on an external display.
    var presentation: PanelPresentation {
        switch Settings.shared.data.panelPresentation {
        case .auto:  return layout.hasPhysicalNotch ? .notch : .orb
        case .notch: return .notch
        case .orb:   return .orb
        }
    }

    /// A stable per-display key for remembering where the orb was put.
    /// `displayID` rather than the localized name, because two identical
    /// monitors share a name and would fight over one stored position.
    private var screenKey: String {
        let number = layout.screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "display.\($0.uint32Value)" } ?? "display.unknown"
    }

    /// Orb origin in screen coordinates, defaulting to the top-right area --
    /// near the menu bar, where the app used to live, but out of the way of
    /// window controls on the left.
    private var orbOrigin: CGPoint {
        get {
            if let stored = Settings.shared.data.orbPositions[screenKey] {
                return clampOrb(stored)
            }
            let frame = layout.screen.visibleFrame
            return clampOrb(CGPoint(x: frame.maxX - OrbView.diameter - 24,
                                    y: frame.maxY - OrbView.diameter - 12))
        }
        set { Settings.shared.data.orbPositions[screenKey] = clampOrb(newValue) }
    }

    /// Keeps the orb fully on screen. Without this, undocking a monitor or
    /// changing resolution can strand it off the edge with no way to get it
    /// back short of editing the settings file.
    private func clampOrb(_ point: CGPoint) -> CGPoint {
        let frame = layout.screen.visibleFrame
        return CGPoint(
            x: min(max(point.x, frame.minX), frame.maxX - OrbView.diameter),
            y: min(max(point.y, frame.minY), frame.maxY - OrbView.diameter))
    }

    /// Live drag target, so the window can follow the cursor without a settings
    /// write per frame.
    private var orbDragOrigin: CGPoint?

    func moveOrb(by delta: CGSize) {
        guard presentation == .orb, state == .collapsed else { return }
        let current = orbDragOrigin ?? orbOrigin
        // AppKit's y axis points up and the gesture's points down.
        let moved = clampOrb(CGPoint(x: current.x + delta.width,
                                     y: current.y - delta.height))
        orbDragOrigin = moved
        panel.setFrameOrigin(moved)
    }

    /// Re-lays-out after the presentation setting changes. Collapses first: a
    /// pill morphing into an orb mid-expansion has no sensible animation, and
    /// the collapsed state is the one both presentations agree on.
    func presentationChanged() {
        objectWillChange.send()
        if state == .expanded { collapse() } else { applyFrame(collapsedSize, animated: true) }
    }

    /// Puts the orb back in its default corner, for when it has been dragged
    /// somewhere awkward or a display change has left it stranded.
    func resetOrbPosition() {
        Settings.shared.data.orbPositions.removeValue(forKey: screenKey)
        orbDragOrigin = nil
        applyFrame(collapsedSize, animated: true)
    }

    /// Whether the orb is currently being touched -- hovered, dragged, or
    /// otherwise interacted with. Drives the idle fade.
    @Published private(set) var isOrbActive = true
    private var orbIdleWork: DispatchWorkItem?

    /// An orb sits on top of the user's actual work, so it has to get out of
    /// the way when it is not being used. Three seconds of no contact and it
    /// drops to a faint outline; anything at all brings it back instantly.
    ///
    /// It fades rather than disappearing: a control that vanishes completely is
    /// one the user has to remember the location of, which is worse than a
    /// control that is merely quiet.
    static let orbIdleDelay: TimeInterval = 3

    func orbHoverChanged(_ inside: Bool) {
        if inside {
            wakeOrb()
        } else {
            scheduleOrbFade()
        }
    }

    /// Called on any interaction -- hover, drag, a new claim arriving.
    func wakeOrb() {
        orbIdleWork?.cancel()
        orbIdleWork = nil
        if !isOrbActive { isOrbActive = true }
    }

    func scheduleOrbFade() {
        orbIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .collapsed else { return }
            self.isOrbActive = false
        }
        orbIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.orbIdleDelay, execute: work)
    }

    func commitOrbPosition() {
        guard let dragged = orbDragOrigin else { return }
        orbDragOrigin = nil
        orbOrigin = dragged
    }

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
    /// The collapsed **window**, which is deliberately wider than the pill it
    /// draws. The window is the hover target; the shape inside it is sized by
    /// `CollapsedPillView.pillWidth`, and at rest is narrower than the cutout so
    /// nothing is visible. Without the extra window width there would be
    /// nowhere to hover an invisible pill.
    private var collapsedSize: CGSize {
        if presentation == .orb {
            // An orb has no shoulders to put a message on, so a transient hangs
            // below it and the window grows to make room. Without this the
            // 46pt window clips the toast to nothing and the orb silently
            // swallows every confirmation the app makes.
            let toasting = arbiter.transient != nil
            return CGSize(width: OrbView.diameter + (toasting ? 240 : 0),
                          height: OrbView.diameter + (toasting ? 44 : 0))
        }
        let notchWidth = layout.hasPhysicalNotch ? layout.notchRect.width : 200
        let pillHeight = max(layout.hasPhysicalNotch ? layout.notchRect.height : 30, 28)
            + (arbiter.hasUrgentContent ? 8 : 0)
        let toasting = arbiter.transient != nil && Settings.shared.data.transientStyle == .toast
        // +40 at rest is hover slack around an invisible pill, not drawn width.
        return CGSize(width: notchWidth + (arbiter.hasUrgentContent ? 260 : 40)
                             + (toasting ? 120 : 0),
                      height: pillHeight + (toasting ? 44 : 0))
    }
    /// **One size for every tab.**
    ///
    /// Per-tab sizing was tried and reverted, because it broke the thing the
    /// whole panel depends on. The panel auto-collapses when the pointer leaves
    /// it; resizing on a tab switch moves the panel's edges *out from under the
    /// cursor*, so clicking a tab that wanted a smaller panel could leave the
    /// pointer outside the new bounds and shut the app in the same gesture that
    /// opened the tab. A window that closes because you used it is not a
    /// trade-off, it is a bug.
    ///
    /// It also looked wrong in a way that is obvious in motion and invisible in
    /// a screenshot: every tab click heaved the whole surface.
    ///
    /// So the size is fixed, and chosen for the most demanding tab rather than
    /// the average one -- Disk Map's three panels and the terminal's four-way
    /// split. Tabs with less to show have whitespace, which costs nothing.
    private static let fixedExpandedSize = CGSize(width: 880, height: 520)

    /// The fixed size, clamped to the screen.
    ///
    /// Clamping still matters: a 1280x800 Air has about 770pt of usable height,
    /// and an unclamped panel would push its own close button off the bottom of
    /// the display.
    private var expandedSize: CGSize {
        let usable = layout.screen.visibleFrame
        return CGSize(width: min(Self.fixedExpandedSize.width, usable.width - 32),
                      height: min(Self.fixedExpandedSize.height, usable.height - 12))
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
        wakeOrb()
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
        // Closing the panel starts the idle clock: the orb should settle back
        // out of the way on its own rather than waiting to be hovered again.
        if presentation == .orb { scheduleOrbFade() }
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
        let frame = presentation == .orb
            ? orbAnchoredFrame(for: size)
            : ScreenGeometry.panelFrame(for: size, layout: layout)
        panel.setFrame(frame, display: false, animate: false)
        if let hosting = panel.contentView {
            hosting.frame = CGRect(origin: .zero, size: frame.size)
        }
    }

    /// Where the panel sits in orb mode.
    ///
    /// Collapsed, it is exactly the orb at its stored position. Expanded, it
    /// hangs from the orb -- below it if there is room, above it if there is
    /// not -- and is clamped to the screen so it can never open half off the
    /// edge just because the user parked the orb in a corner.
    private func orbAnchoredFrame(for size: CGSize) -> CGRect {
        let origin = orbDragOrigin ?? orbOrigin
        // Collapsed, including the taller shape used while a toast is showing.
        // The orb must stay put at `origin` while the window grows downward,
        // so the window's bottom edge moves and its top edge does not.
        if size.width <= OrbView.diameter + 240 && size.height <= OrbView.diameter + 44 {
            return CGRect(x: origin.x,
                          y: origin.y - (size.height - OrbView.diameter),
                          width: size.width, height: size.height)
        }
        let visible = layout.screen.visibleFrame
        let centredX = origin.x + OrbView.diameter / 2 - size.width / 2
        let x = min(max(centredX, visible.minX + 8), visible.maxX - size.width - 8)

        let below = origin.y - size.height - 8
        let above = origin.y + OrbView.diameter + 8
        let y = below >= visible.minY + 8 ? below
              : min(above, visible.maxY - size.height - 8)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
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

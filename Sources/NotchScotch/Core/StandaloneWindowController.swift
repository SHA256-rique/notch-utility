import AppKit
import SwiftUI
import Combine

/// NotchScotch as an ordinary window: resizable, full-screenable, and staying
/// put until it is closed.
///
/// ## Why this exists
/// The notch panel is deliberately transient. It opens on hover, collapses when
/// the pointer leaves, and is sized for a glance. That is right for checking a
/// timer and wrong for the things this app grew: reading a 40-row disk map,
/// working in a four-way terminal split, or writing a script in the
/// teleprompter. Those are tasks, and a task needs a window that does not close
/// because you looked away.
///
/// ## What is different from the panel
/// The window hosts the **same** `ExpandedPanelView`, so there is one
/// implementation of every tab and no second layout to keep in step. What it
/// does not inherit is the panel's behaviour: no hover-collapse, no pin button
/// (it is always pinned), no notch gap in the header (there is no notch above
/// it), and a real title bar so it can be moved, zoomed and full-screened like
/// anything else.
///
/// ## Why a separate window rather than "un-notching" the panel
/// The panel is an `NSPanel` that is non-activating, borderless, and pinned to
/// the top of the screen — three properties a normal window must not have.
/// Toggling all of them on one window object means a window that is sometimes a
/// panel, and every behaviour in it has to ask which it is today. Two windows
/// sharing one view tree is the smaller thing.
@MainActor
final class StandaloneWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = StandaloneWindowController()

    @Published private(set) var isOpen = false

    private var window: NSWindow?

    private override init() { super.init() }

    /// Opens the window, or brings it forward if it is already up.
    func open(selecting tab: ActiveTab? = nil) {
        if let tab { NotchPanelController.shared.openTab(tab) }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NotchPanelController.shared
        let root = ExpandedPanelView(chrome: .window)
            .environmentObject(controller)
            .environmentObject(NotchArbiter.shared)
            .environmentObject(ThemeManager.shared)
            .environmentObject(Settings.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)

        window.title = "NotchScotch"
        // The panel draws its own background and rounded chrome, so the window's
        // titlebar is made transparent and the content runs under it. Without
        // this there is a grey strip above the app's own header.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 720, height: 460)
        // `fullScreenPrimary` is what puts the green button into full-screen
        // mode rather than plain zoom, which is the thing being asked for.
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.setFrameAutosaveName("NotchScotchWindow")

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        isOpen = true

        // The window is attended by definition, so the hub runs for it. Without
        // this the stats rings and every other widget sit frozen in a window the
        // user is actively looking at.
        WidgetPollingHub.shared.setActive(true)
        Log.panel.info("standalone window opened")
    }

    func close() {
        window?.close()
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func toggleFullScreen() {
        if window == nil { open() }
        window?.toggleFullScreen(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        window = nil
        // Hand the power decision back to the panel, which may well be
        // collapsed -- at which point everything should stop again.
        NotchPanelController.shared.settingsChanged()
        Log.panel.info("standalone window closed")
    }
}

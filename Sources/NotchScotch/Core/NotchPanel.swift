import AppKit

/// The one and only window for the notch surface.
///
/// It is created once at launch and then only ever **resized and repositioned**.
/// Destroying and recreating an NSPanel on every hover would mean a window-server
/// round trip, a fresh backing store allocation and a layer-tree rebuild several
/// times a minute -- all for a window whose content is already in memory.
///
/// Style choices, each of which is load-bearing:
///   * `.borderless` -- no title bar, no traffic lights; we draw the whole chrome.
///   * `.nonactivatingPanel` -- clicking the pill must NOT steal focus from the
///     app the user is typing in. Without this, tapping a timer would yank focus
///     out of their editor. Text fields inside the panel still work because we
///     explicitly activate only when a tab that needs input is opened.
///   * `level: .statusBar` -- above normal windows and above the Dock, but below
///     genuine system alerts, which is the correct neighbourhood for this.
///   * `.canJoinAllSpaces` + `.stationary` -- the notch is physical hardware; it
///     must not slide away during a Space switch.
///   * `.fullScreenAuxiliary` -- keeps the panel visible over full-screen apps,
///     otherwise the feature dies exactly when someone is watching a video.
final class NotchPanel: NSPanel {

    /// Set true while a tab needs real keyboard input (Terminal, AI Chat, notes).
    /// A non-activating panel cannot become key by default, so this is the opt-in.
    var wantsKeyboardFocus = false {
        didSet {
            guard wantsKeyboardFocus != oldValue else { return }
            if wantsKeyboardFocus {
                // Order matters: the app must be active before the panel can
                // meaningfully take key status.
                NSApp.activate(ignoringOtherApps: true)
                makeKey()
            } else {
                resignKey()
            }
        }
    }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // A borderless panel would otherwise be draggable by its background,
        // which makes hover-to-expand feel broken when a click-drag slides the
        // whole notch off-centre.
        //
        // `isMovable` is flipped on for the orb, which is the one presentation
        // where moving the window is the entire point. It stays off by default
        // because `performDrag(with:)` is a no-op on an immovable window --
        // silently, which is exactly how the orb ended up un-draggable.
        isMovable = false
        isMovableByWindowBackground = false

        // Never show up in Exposé/Mission Control or the window cycle.
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = false

        // Animations are driven by SwiftUI springs inside the content view; the
        // window's own resize must be instantaneous or the two fight each other
        // and you get the rubber-banding that plagues apps in this category.
        animationBehavior = .none
    }

    // A borderless window returns false for both of these by default, which
    // would make every text field in every tab inert.
    override var canBecomeKey: Bool { wantsKeyboardFocus }

    /// Orb mode needs a movable window; notch mode must not have one.
    func setDraggable(_ draggable: Bool) {
        isMovable = draggable
        // Background dragging stays off even for the orb: the orb hands
        // `performDrag` a specific mouse-down from a view it controls, and
        // background dragging would additionally let a drag start anywhere in
        // the window -- including the transparent area a toast occupies.
        isMovableByWindowBackground = false
    }
    override var canBecomeMain: Bool { false }

    /// `.none` makes the window invisible to screen capture, screen sharing and
    /// screenshots at the window-server level -- the same mechanism password
    /// managers use. Applied to the teleprompter by default and offered as a
    /// general toggle for the panel.
    func setHiddenFromCapture(_ hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }
}

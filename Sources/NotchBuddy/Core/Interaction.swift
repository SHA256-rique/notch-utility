import SwiftUI
import AppKit

/// The pointing-hand cursor, for things that are clickable but do not look like
/// AppKit controls.
///
/// ## Why this is not automatic
/// AppKit gives `NSButton` a cursor rect for free. Nothing in this panel is an
/// `NSButton` -- every control is drawn, because a stock bordered button breaks
/// the illusion that the panel is part of the hardware (see `NBButtonStyle`).
/// The cost of that choice is that affordance has to be put back by hand, and
/// until now it was missing: an app icon in the Launch grid looked clickable and
/// the cursor said otherwise.
///
/// ## Why push/pop and not `.pointerStyle`
/// SwiftUI's `pointerStyle(.link)` is macOS 15. This project targets macOS 14,
/// so the cursor is managed directly.
///
/// ## Why the balance matters
/// `NSCursor.push()` and `pop()` are a stack. An unbalanced push leaves the
/// hand cursor stuck over the whole screen until something else resets it --
/// a genuinely user-visible bug, and an easy one to write, because a view can
/// be destroyed while the cursor is still inside it (switch tabs with the
/// cursor over a tile, and `onHover(false)` never arrives). So this tracks
/// whether *this instance* pushed, and unwinds on disappear and on being
/// disabled as well as on exit.
private struct PointerCursor: ViewModifier {
    var enabled: Bool

    @State private var didPush = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && enabled {
                    push()
                } else {
                    unwind()
                }
            }
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { unwind() }
            }
            .onDisappear { unwind() }
    }

    private func push() {
        guard !didPush else { return }
        NSCursor.pointingHand.push()
        didPush = true
    }

    private func unwind() {
        guard didPush else { return }
        NSCursor.pop()
        didPush = false
    }
}

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view.
    ///
    /// Use it on anything clickable that is not already an obvious control:
    /// tiles that open a detail, icons in the dock, app shortcuts, day cells,
    /// list rows with a tap action. Do **not** use it on text fields or on
    /// draggable-only surfaces, where the hand would promise a click that does
    /// nothing.
    func pointerCursor(_ enabled: Bool = true) -> some View {
        modifier(PointerCursor(enabled: enabled))
    }
}

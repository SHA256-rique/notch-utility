import AppKit

/// Works out where the physical notch is, and where to put the panel when there
/// isn't one.
///
/// The reliable signal for "this screen has a notch" is `safeAreaInsets.top > 0`
/// on macOS 12+. Alternatives that were rejected:
///   * Hardcoding model identifiers -- breaks on every new Mac.
///   * `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` -- these do
///     describe the menu-bar regions either side of the notch, but they are nil
///     when the menu bar is auto-hidden or the screen is in full-screen, which
///     is precisely when we still need to position the panel.
/// safeAreaInsets keeps reporting through both of those.
enum ScreenGeometry {

    struct Layout {
        let screen: NSScreen
        /// Rect of the notch cutout itself in screen coordinates, or a synthetic
        /// equivalent at top-centre on a notchless display.
        let notchRect: CGRect
        let hasPhysicalNotch: Bool
    }

    /// Physical notch width varies by model (about 200pt on 14"/16", 170pt on the
    /// 13"/15" Air). We derive it from the auxiliary areas when available and
    /// fall back to a value that looks right rather than guessing per model.
    private static let fallbackNotchWidth: CGFloat = 200

    static func current(preferring screen: NSScreen? = nil) -> Layout {
        let target = screen ?? notchScreen() ?? NSScreen.main ?? NSScreen.screens.first!
        let frame = target.frame
        let inset = target.safeAreaInsets.top

        if inset > 0 {
            let width = measuredNotchWidth(on: target) ?? fallbackNotchWidth
            let rect = CGRect(x: frame.midX - width / 2,
                              y: frame.maxY - inset,
                              width: width,
                              height: inset)
            return Layout(screen: target, notchRect: rect, hasPhysicalNotch: true)
        }

        // Notchless: external display, Intel Mac, or a Mac mini. Synthesise a
        // notch-shaped region at top-centre, tucked just under the menu bar so
        // the pill does not fight with menu-bar items for clicks.
        let barHeight: CGFloat = max(24, frame.maxY - target.visibleFrame.maxY)
        let rect = CGRect(x: frame.midX - fallbackNotchWidth / 2,
                          y: frame.maxY - barHeight,
                          width: fallbackNotchWidth,
                          height: barHeight)
        return Layout(screen: target, notchRect: rect, hasPhysicalNotch: false)
    }

    /// The gap between the two auxiliary menu-bar areas is the notch, exactly.
    private static func measuredNotchWidth(on screen: NSScreen) -> CGFloat? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        return width > 40 && width < 400 ? width : nil
    }

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// How much usable width there is either side of the cutout, for a panel of
    /// the given width.
    ///
    /// This is the number that decides whether a message can be shown *in* the
    /// notch row at all. macOS reserves the cutout rectangle -- no application
    /// can draw into it, which is why every app in this category lays out
    /// around the housing rather than under it -- so content wider than a
    /// shoulder is not clipped or dimmed, it is simply not on the screen.
    ///
    /// Returns zero on a display with no physical notch, where the whole width
    /// is usable and the question does not arise.
    static func shoulderWidth(panelWidth: CGFloat, layout: Layout) -> CGFloat {
        guard layout.hasPhysicalNotch else { return panelWidth / 2 }
        return max(0, (panelWidth - layout.notchRect.width) / 2)
    }

    /// Frame for the panel at a given content size, centred on the notch.
    ///
    /// The panel's top edge is pinned to the very top of the screen (not below
    /// the menu bar) so that the collapsed pill can visually merge with the
    /// black of the physical notch instead of floating below it.
    static func panelFrame(for size: CGSize, layout: Layout) -> CGRect {
        let f = layout.screen.frame
        let x = (f.midX - size.width / 2).rounded()
        let y = (f.maxY - size.height).rounded()
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

import SwiftUI

/// The pill's outline: concave where it meets the menu bar, generously rounded
/// where it hangs free.
///
/// ## Why not `UnevenRoundedRectangle`
/// The pill used square top corners and rounded bottom ones, which is the naive
/// reading of "hangs from the notch". In practice it drew two hard 90° corners
/// against the top of the screen, and a hard corner is exactly what the physical
/// cutout does not have. The result read as a black rectangle taped under the
/// hardware.
///
/// The cutout itself flares *outward* at the top — the display's black region
/// curves away into the menu bar rather than meeting it at a point. Matching
/// that is a small concave arc at each top corner, and it is the single change
/// that makes drawn chrome look like it belongs to the machine.
///
/// ```
///   ╭ flare                      flare ╮      ← concave, curves outward
///   │                                  │
///   ╰──────────────────────────────────╯      ← convex, generous
/// ```
///
/// ## The flare lives outside the frame
/// A concave top corner necessarily paints *beyond* the shape's own width — it
/// is the curve of the thing it is attached to, not of the thing itself. Callers
/// must leave `flare` points of horizontal slack or it is clipped, which looks
/// like a rendering bug rather than a shape.
struct NotchShape: Shape {
    /// Radius of the outward curve at the top corners.
    var flare: CGFloat = 9
    /// Radius of the rounded bottom corners.
    var bottomRadius: CGFloat = 15

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Clamp so a very short pill cannot produce curves that cross each
        // other and render as a bow tie.
        let flare = min(self.flare, rect.height / 2)
        let bottom = min(bottomRadius, min(rect.height - flare, rect.width / 2))

        path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        // Top-left: curve *in* from the menu bar down onto the left edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + flare),
            control: CGPoint(x: rect.minX, y: rect.minY))

        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX, y: rect.maxY))

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + flare))
        // Top-right: curve back out into the menu bar.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + flare, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY))

        path.closeSubpath()
        return path
    }
}

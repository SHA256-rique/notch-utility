import SwiftUI

/// Tier 1. Everything on screen while the panel is collapsed.
///
/// The rule this view enforces visually: **render nothing when there is nothing
/// to say**. An idle timer widget shows no "00:00", an idle Now Playing shows no
/// empty scrubber. When no claim exists the pill collapses to a bare shape that
/// merges with the physical notch, and the app is visually absent.
///
/// ## Two layers, never a swap
/// A transient never replaces a persistent claim. The arbitration rule says it
/// *overlays* for its lifetime, so the persistent view stays mounted underneath
/// and the toast is drawn over it. When the TTL expires the running timer is
/// simply still there -- no re-entry animation to get wrong, no frame where the
/// pill is empty.
///
/// How the transient presents itself is the user's choice between two shared
/// animations (`TransientStyle`), applied to every transient in the app.
struct CollapsedPillView: View {
    @EnvironmentObject private var arbiter: NotchArbiter
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var controller: NotchPanelController
    @EnvironmentObject private var settings: Settings

    var body: some View {
        let theme = themes.theme
        let persistent = arbiter.allPersistent.first
        let transient = arbiter.transient
        let ambient = arbiter.ambient
        let style = settings.data.transientStyle

        VStack(spacing: 0) {
            GeometryReader { geo in
                // Everything below hangs off this one number. See
                // `ScreenGeometry.shoulderWidth`: the middle of this row is
                // behind the camera housing and macOS lets nobody draw there,
                // so a message wider than a shoulder is not clipped -- it is
                // invisible, with no way for the user to know it existed.
                let shoulder = ScreenGeometry.shoulderWidth(
                    panelWidth: geo.size.width + 20, layout: ScreenGeometry.current())
                let fitsShoulder = transient.map { Self.estimatedWidth(of: $0) <= shoulder - 10 } ?? true
                let sweeping = (style == .sweep && fitsShoulder) ? transient : nil
                let toasting = (style == .toast || !fitsShoulder) ? transient : nil

                VStack(spacing: 0) {
                  ZStack(alignment: .leading) {
                    // --- Base layer: the persistent claim and the ambient items.
                    HStack(spacing: 0) {
                        if let persistent {
                            claimView(persistent, theme: theme, emphasised: true)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                                    removal: .opacity))
                                .id(persistent.id)
                        }

                        // The notch cutout itself. Nothing at rest may be drawn
                        // here -- it is physical hardware. The spacer is what
                        // makes content appear to flow around the camera housing.
                        Spacer(minLength: notchWidth)

                        // Right shoulder: ambient items, only while something
                        // else is already holding the pill open. On a resting
                        // pill they stay hidden so the app is invisible when idle.
                        if persistent != nil || transient != nil {
                            HStack(spacing: 8) {
                                ForEach(ambient.prefix(2)) { claim in
                                    claimView(claim, theme: theme, emphasised: false)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    // Dim the base only while a sweep is crossing it. A toast
                    // sits *below* the pill and does not overlap anything, so
                    // dimming for one would be dimming for no reason.
                    .opacity(sweeping == nil ? 1 : 0.25)
                    .animation(Motion.pillContent, value: sweeping == nil)

                    // --- Overlay layer: a sweeping transient, right to left.
                    if let sweeping {
                        HStack(spacing: 0) {
                            claimView(sweeping, theme: theme, emphasised: true,
                                      maxTextWidth: shoulder - 46)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(theme.tint(sweeping.module).opacity(0.18))
                                        .overlay(SweepHighlight(tint: theme.tint(sweeping.module)))
                                        .clipShape(Capsule())
                                )
                                // Hard ceiling, not just a text limit: the
                                // capsule's own background must not reach the
                                // cutout either.
                                .frame(maxWidth: max(60, shoulder - 6), alignment: .leading)
                            Spacer(minLength: 0)
                        }
                        .transition(.notchSweep(distance: geo.size.width))
                        // Keyed on the content, not just the slot id, so two
                        // toasts in quick succession genuinely re-run the
                        // animation rather than cross-fading their text in place.
                        .id(key(sweeping))
                    }
                    }
                    .frame(width: geo.size.width, height: pillHeight)
                    .padding(.horizontal, 10)
                    .background(pillShape(theme: theme))
                    .clipShape(pillClip)

                    // --- The toast, hanging below the notch rather than in it.
                    //
                    // This is also the overflow route: a message too wide for a
                    // shoulder lands here whichever style is selected, because
                    // below the notch the full width of the screen is available
                    // and nothing is behind hardware.
                    if let toasting {
                        toastView(toasting, theme: theme)
                            .transition(.toastDrop())
                            .id(key(toasting))
                            .padding(.top, 4)
                    }
                }
                .frame(width: geo.size.width, alignment: .top)
                .animation(Motion.pillContent, value: persistent)
                .animation(Motion.pillContent, value: ambient.count)
                // Each style gets its own pair of curves, and the direction of
                // travel decides which one applies.
                .animation(sweeping == nil ? Motion.sweepOut : Motion.sweepIn, value: sweeping)
                .animation(toasting == nil ? Motion.toastOut : Motion.toastIn, value: toasting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
    }

    /// Rough width of a rendered claim, used only to decide shoulder-vs-toast.
    ///
    /// A real measurement would need a layout pass, a preference key and a
    /// second render -- for a decision whose only failure mode is picking the
    /// toast slightly too eagerly. The constants are the icon, the padding and
    /// an average glyph advance at 11pt SF; they are deliberately generous,
    /// because erring toward the toast costs nothing and erring the other way
    /// hides the message.
    nonisolated static func estimatedWidth(of claim: PillClaim) -> CGFloat {
        let longest = max(claim.text.count, claim.detail?.count ?? 0)
        return 46 + CGFloat(longest) * 6.4
    }

    private var notchWidth: CGFloat {
        ScreenGeometry.current().hasPhysicalNotch ? ScreenGeometry.current().notchRect.width : 120
    }

    /// The pill occupies only the notch's own height; anything below it is the
    /// toast's. Without this the pill would stretch to fill the taller window
    /// the controller opens for a toast, and the "notch" would visibly grow.
    private var pillHeight: CGFloat {
        max(ScreenGeometry.current().notchRect.height, 32)
            + (arbiter.hasUrgentContent ? 6 : 0)
    }

    private func key(_ claim: PillClaim) -> String {
        claim.id + claim.text + (claim.detail ?? "")
    }

    // MARK: - Toast

    /// The phone-shaped notification: a self-contained capsule under the notch,
    /// with its own background rather than the pill's, because it is a separate
    /// object that appeared -- not a region of the notch lighting up.
    private func toastView(_ claim: PillClaim, theme: Theme) -> some View {
        let tint = theme.tint(claim.module)
        return HStack(spacing: 6) {
            Image(systemName: claim.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .themeGlow(tint, radius: theme.glowRadius(4))
            Text(claim.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            if let detail = claim.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(theme.panelBackground)
                .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
                .themeGlow(tint, radius: theme.glowRadius(8))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        )
        .fixedSize()
    }

    // MARK: - Claim rendering

    @ViewBuilder
    private func claimView(_ claim: PillClaim, theme: Theme, emphasised: Bool,
                           maxTextWidth: CGFloat? = nil) -> some View {
        let tint = theme.tint(claim.module)
        HStack(spacing: 5) {
            ZStack {
                if let progress = claim.progress, claim.priority == .persistent {
                    NBRing(progress: progress, tint: tint, lineWidth: 2.5,
                           glow: theme.glowRadius(4))
                        .frame(width: 15, height: 15)
                }
                Image(systemName: claim.symbol)
                    .font(.system(size: claim.progress != nil && claim.priority == .persistent ? 7 : 10,
                                  weight: .semibold))
                    .foregroundStyle(tint)
                    .themeGlow(tint, radius: theme.glowRadius(3))
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(claim.text)
                    .font(.system(size: emphasised ? 11 : 10,
                                  weight: emphasised ? .semibold : .medium,
                                  design: claim.module == .time ? .rounded : .default))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if emphasised, let detail = claim.detail {
                    Text(detail)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            // Measured, not a magic 120. The left shoulder on a 14" is much
            // narrower than on a 16", and a fixed cap either wastes the wider
            // one or overruns the narrower one into the cutout.
            .frame(maxWidth: maxTextWidth ?? (emphasised ? 120 : 64), alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shape

    private var pillClip: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 14,
            bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
    }

    /// The bottom corners are rounded and the top ones are square, so the pill
    /// reads as hanging *from* the notch rather than floating under it. On a
    /// notchless display it still works as a menu-bar-adjacent tab.
    private func pillShape(theme: Theme) -> some View {
        pillClip
            .fill(Color.black)
            .overlay(pillClip.stroke(theme.panelStroke, lineWidth: theme.kind == .neon ? 1 : 0.5))
            // Only glow when the pill has content; a resting pill must be invisible.
            .themeGlow(theme.accent, radius: arbiter.hasUrgentContent ? theme.glowRadius(8) : 0)
    }
}

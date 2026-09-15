import SwiftUI

/// Tier 1. Everything on screen while the panel is collapsed.
///
/// The rule this view enforces visually: **render nothing when there is nothing
/// to say**. An idle timer widget shows no "00:00", an idle Now Playing shows no
/// empty scrubber. When no claim exists the pill collapses to a bare shape that
/// merges with the physical notch, and the app is visually absent.
struct CollapsedPillView: View {
    @EnvironmentObject private var arbiter: NotchArbiter
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var controller: NotchPanelController

    var body: some View {
        let theme = themes.theme
        let persistent = arbiter.allPersistent.first
        let transient = arbiter.transient
        let ambient = arbiter.ambient
        let hasContent = persistent != nil || transient != nil

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // --- Base layer: the persistent claim and the ambient items.
                //
                // The persistent claim is NOT replaced when a transient arrives.
                // The arbitration rule says a transient only *overlays* for its
                // lifetime, and the cheapest way to be literally faithful to
                // that is to keep the persistent view mounted underneath and let
                // the transient sweep over it. When the toast expires the timer
                // is simply still there -- no re-entry animation, no flicker.
                HStack(spacing: 0) {
                    if let persistent {
                        claimView(persistent, theme: theme, emphasised: true)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.8).combined(with: .opacity),
                                removal: .opacity))
                            .id(persistent.id)
                    }

                    // The notch cutout itself. Nothing at rest may be drawn
                    // here -- it is physical hardware. The spacer is what makes
                    // content appear to flow around the camera housing.
                    Spacer(minLength: notchWidth)

                    // Right shoulder: ambient items, only while something else
                    // is already holding the pill open. On a resting pill they
                    // stay hidden so the app is invisible when idle.
                    if hasContent {
                        HStack(spacing: 8) {
                            ForEach(ambient.prefix(2)) { claim in
                                claimView(claim, theme: theme, emphasised: false)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                // Dim the base while a toast is crossing it, so the two layers
                // never compete for the eye at the same brightness.
                .opacity(transient == nil ? 1 : 0.25)
                .animation(Motion.pillContent, value: transient == nil)

                // --- Overlay layer: the transient, sweeping right to left.
                if let transient {
                    HStack(spacing: 0) {
                        claimView(transient, theme: theme, emphasised: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(theme.tint(transient.module).opacity(0.18))
                                    .overlay(SweepHighlight(tint: theme.tint(transient.module)))
                                    .clipShape(Capsule())
                            )
                        Spacer(minLength: 0)
                    }
                    .transition(.notchSweep(distance: geo.size.width))
                    // Keyed on the content, not just the slot id, so two toasts
                    // in quick succession genuinely re-run the sweep rather than
                    // cross-fading their text in place.
                    .id(transient.id + transient.text + (transient.detail ?? ""))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pillShape(theme: theme))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 14,
                bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
        )
        .animation(Motion.pillContent, value: persistent)
        .animation(Motion.pillContent, value: ambient.count)
        // Two different animations for the two directions of the sweep: it
        // arrives on a spring and leaves on an ease-in, because the exit is
        // continuing its travel rather than settling.
        .animation(transient == nil ? Motion.sweepOut : Motion.sweepIn, value: transient)
        .contentShape(Rectangle())
    }

    private var notchWidth: CGFloat {
        ScreenGeometry.current().hasPhysicalNotch ? ScreenGeometry.current().notchRect.width : 120
    }

    // MARK: - Claim rendering

    @ViewBuilder
    private func claimView(_ claim: PillClaim, theme: Theme, emphasised: Bool) -> some View {
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
            .frame(maxWidth: emphasised ? 120 : 64, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shape

    /// The bottom corners are rounded and the top ones are square, so the pill
    /// reads as hanging *from* the notch rather than floating under it. On a
    /// notchless display it still works as a menu-bar-adjacent tab.
    private func pillShape(theme: Theme) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 14,
            bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
        .fill(Color.black)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 14,
                bottomTrailingRadius: 14, topTrailingRadius: 0, style: .continuous)
            .stroke(theme.panelStroke, lineWidth: theme.kind == .neon ? 1 : 0.5)
        )
        // Only glow when the pill has content; a resting pill must be invisible.
        .themeGlow(theme.accent, radius: arbiter.hasUrgentContent ? theme.glowRadius(8) : 0)
    }
}

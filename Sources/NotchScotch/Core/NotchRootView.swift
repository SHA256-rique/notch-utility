import SwiftUI

/// Root of the panel's view tree. Owns the collapsed <-> expanded crossfade and
/// the hover tracking that drives the state machine.
struct NotchRootView: View {
    @EnvironmentObject private var controller: NotchPanelController
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var arbiter: NotchArbiter

    var body: some View {
        ZStack(alignment: .top) {
            switch controller.state {
            case .collapsed:
                // Two shapes for the same state. Which one is a property of the
                // display, not of the app: see `PanelPresentation`.
                Group {
                    if controller.presentation == .orb {
                        OrbView()
                    } else {
                        CollapsedPillView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.animation(Motion.panel.delay(0.05)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
            case .expanded:
                ExpandedPanelView()
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .top)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.96, anchor: .top)
                            .combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Motion.panel, value: controller.state)
        // The hover target is the whole window. `contentShape` is required
        // because a mostly-transparent view has no hit area of its own, and
        // without it the hover would only register over drawn pixels.
        .contentShape(Rectangle())
        // Hover-to-expand belongs to the notch and not to the orb. The notch is
        // a fixed place at the edge of the screen that you go to on purpose; an
        // orb is a small object sitting in the middle of the user's work, and
        // one that opened a 880pt panel every time the cursor crossed it would
        // be unusable. The orb opens on a click, like any other floating
        // control.
        .onHover { inside in
            guard controller.presentation != .orb else {
                controller.orbHoverChanged(inside)
                return
            }
            controller.hoverChanged(inside)
        }
        .onTapGesture {
            if controller.state == .collapsed {
                controller.expand(selecting: controller.activeTab ?? .builtin(.home))
            }
        }
    }
}

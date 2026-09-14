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
                CollapsedPillView()
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
        .onHover { controller.hoverChanged($0) }
        .onTapGesture {
            if controller.state == .collapsed {
                controller.expand(selecting: .builtin(.home))
            }
        }
    }
}

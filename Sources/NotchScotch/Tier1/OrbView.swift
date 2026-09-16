import SwiftUI
import AppKit

/// The collapsed app on a display that has no notch: a small circle the user
/// drags where they want it.
///
/// ## Why not the synthesised notch
/// On a notchless display the app used to draw a black tab at top-centre, under
/// the menu bar, pretending there was a cutout there. It works on a laptop-sized
/// screen. On a 27" external monitor it puts the app in the least reachable part
/// of a very large display, and the illusion it is selling — "this is your
/// hardware" — is false there in a way it is not on a MacBook.
///
/// An orb is honest about being a floating control, and being movable is the
/// entire point: on an external display there is no one right place for it.
///
/// ## What it shows
/// The same arbitration output as the pill, compressed to what fits in a circle:
/// the focal claim's symbol, a progress ring when it has one, and a count badge
/// when more than one thing is live. Text goes in the tooltip and in the toast,
/// not in the orb — a 46pt circle that tries to hold "Converted 3 files" holds
/// nothing legibly.
struct OrbView: View {
    @EnvironmentObject private var arbiter: NotchArbiter
    @EnvironmentObject private var themes: ThemeManager
    @EnvironmentObject private var controller: NotchPanelController

    @State private var isDragging = false
    @State private var isHovering = false

    /// Resting means untouched for `orbIdleDelay`. Read from the controller
    /// rather than tracked here, because the timer has to survive this view
    /// being rebuilt when a claim changes.
    private var isResting: Bool { !controller.isOrbActive && !isDragging && !isHovering }

    static let diameter: CGFloat = 46

    var body: some View {
        let theme = themes.theme
        let focus = arbiter.allPersistent.first ?? arbiter.transient
        let liveCount = arbiter.allPersistent.count

        VStack(alignment: .leading, spacing: 6) {
        ZStack {
            Circle()
                .fill(theme.panelBackground)
                .overlay(Circle().stroke(theme.panelStroke, lineWidth: 1))
                .themeGlow(focus.map { theme.tint($0.module) } ?? theme.accent,
                           radius: theme.glowRadius(arbiter.hasUrgentContent ? 10 : 4))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)

            if let focus, let progress = focus.progress {
                NBRing(progress: progress, tint: theme.tint(focus.module),
                       lineWidth: 3, glow: theme.glowRadius(4))
                    .padding(4)
            }

            Image(systemName: focus?.symbol ?? "circle.hexagongrid.fill")
                .font(.system(size: focus == nil ? 16 : 15, weight: .semibold))
                .foregroundStyle(focus.map { theme.tint($0.module) } ?? theme.secondaryText)
                .themeGlow(focus.map { theme.tint($0.module) } ?? .clear, radius: theme.glowRadius(4))

            if liveCount > 1 {
                Text("\(liveCount)")
                    .font(.system(size: 9, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(3)
                    .background(Circle().fill(theme.accent))
                    .offset(x: Self.diameter / 2 - 7, y: -Self.diameter / 2 + 7)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(isDragging ? 1.12 : (isHovering ? 1.06 : (isResting ? 0.88 : 1)))
        // Faint, but never gone. A control that disappears entirely is one the
        // user has to remember the position of; a faint one is still a target.
        // Anything with a live claim stays legible regardless -- fading out a
        // running timer to 18% would defeat the point of showing it.
        .opacity(isResting && !arbiter.hasUrgentContent ? 0.18 : 1)
        .animation(Motion.pillContent, value: isDragging)
        .animation(Motion.pillContent, value: isHovering)
        .animation(Motion.pillContent, value: focus)
        .animation(.easeInOut(duration: 0.45), value: isResting)
        .pointerCursor()
        .onHover { inside in
            isHovering = inside
            controller.orbHoverChanged(inside)
        }
        .help(focus.map { "\($0.text)\($0.detail.map { d in " — \(d)" } ?? "")" }
              ?? "NotchScotch — drag to move, click to open")
        // Dragging is handled by AppKit, not by a SwiftUI gesture. See
        // `OrbDragHandle` for why -- the gesture version flickered badly.
        .overlay(OrbDragHandle(
            onClick: { controller.expand(selecting: controller.activeTab ?? .builtin(.home)) },
            onDragBegan: { isDragging = true; controller.wakeOrb() },
            onDragEnded: {
                isDragging = false
                controller.commitOrbPosition()
                controller.scheduleOrbFade()
            }))

        // A transient gets the same toast the notch presentation uses, hung
        // under the orb. One shared shape for one category of message, whatever
        // the app happens to be wearing on this display.
        if let transient = arbiter.transient {
            OrbToast(claim: transient)
                .transition(.toastDrop())
                .id(transient.id + transient.text + (transient.detail ?? ""))
        }
        }
        .animation(arbiter.transient == nil ? Motion.toastOut : Motion.toastIn,
                   value: arbiter.transient)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A message arriving is contact: the orb comes back so the toast is
        // attached to something visible, then settles again.
        .onChange(of: arbiter.transient) { _, new in
            if new != nil {
                controller.wakeOrb()
                controller.scheduleOrbFade()
            }
        }
        .onAppear { controller.scheduleOrbFade() }
    }
}

/// The orb's toast. Deliberately the same capsule the pill uses, rather than a
/// second design: a confirmation should look like a confirmation whichever
/// presentation the display is in.
struct OrbToast: View {
    @EnvironmentObject private var themes: ThemeManager
    let claim: PillClaim

    var body: some View {
        let theme = themes.theme
        let tint = theme.tint(claim.module)
        return HStack(spacing: 6) {
            Image(systemName: claim.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
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
                .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
        )
        .fixedSize()
    }
}

/// Drags the orb's window, and distinguishes a drag from a click.
///
/// ## Why AppKit and not a SwiftUI `DragGesture`
/// The gesture version flickered badly, and the reason is a feedback loop that
/// cannot be tuned away.
///
/// `DragGesture` reports a *cumulative* translation measured relative to the
/// view — and therefore relative to the window the view is in. Moving the
/// window in response changes the origin that the next event is measured from,
/// so the next translation is already partly stale. Applying only the delta
/// helps but does not fix it: the events and the window moves are on different
/// clocks, so every frame the window is drawn somewhere slightly wrong and
/// corrected on the next one. That correction, sixty times a second, is the
/// flicker.
///
/// `NSWindow.performDrag(with:)` is the API this is for. AppKit tracks the
/// mouse itself, at the window-server level, and moves the window in lockstep
/// with the cursor — the same mechanism that drags any titlebar. There is no
/// feedback loop because SwiftUI is not in it.
///
/// ## Why this also handles the click
/// `performDrag` consumes the mouse-down and blocks until the mouse comes back
/// up, so a click never reaches SwiftUI's `onTapGesture` once this view is in
/// the way. Rather than fight that, the same handler decides: if the window did
/// not move, it was a click.
struct OrbDragHandle: NSViewRepresentable {
    var onClick: () -> Void
    var onDragBegan: () -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.configure(onClick: onClick, onDragBegan: onDragBegan, onDragEnded: onDragEnded)
        return view
    }

    func updateNSView(_ nsView: DragView, context: Context) {
        nsView.configure(onClick: onClick, onDragBegan: onDragBegan, onDragEnded: onDragEnded)
    }

    final class DragView: NSView {
        private var onClick: (() -> Void)?
        private var onDragBegan: (() -> Void)?
        private var onDragEnded: (() -> Void)?

        func configure(onClick: @escaping () -> Void,
                       onDragBegan: @escaping () -> Void,
                       onDragEnded: @escaping () -> Void) {
            self.onClick = onClick
            self.onDragBegan = onDragBegan
            self.onDragEnded = onDragEnded
        }

        /// The panel is non-activating, so without this the first click after
        /// the app loses focus is swallowed activating it.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return super.mouseDown(with: event) }
            let before = window.frame.origin
            onDragBegan?()
            // Blocks until mouse-up, moving the window itself.
            window.performDrag(with: event)
            let after = window.frame.origin

            // Anything under a point is a click that wobbled, not a drag.
            let moved = hypot(after.x - before.x, after.y - before.y) > 1
            onDragEnded?()
            if !moved { onClick?() }
        }
    }
}

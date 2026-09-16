import SwiftUI

/// The app's animation vocabulary, in one place.
///
/// The brief's bar is "match Apple's own spring quality -- no linear easing, no
/// jank". The way to actually hit that is not to tune magic numbers per call
/// site but to define a *small* set of named springs and use them everywhere, so
/// every surface in the app decelerates the same way.
///
/// SwiftUI's `.spring(response:dampingFraction:)` is parameterised the way
/// designers think: `response` is roughly "how long until it settles" and
/// `dampingFraction` is "how much overshoot". macOS system chrome sits around
/// 0.32-0.42s response with damping just under 1 -- present but barely-there
/// overshoot. Values above 1.0 damping are overdamped and read as sluggish;
/// below ~0.7 they read as bouncy-toy.
enum Motion {
    /// The notch opening and closing. The signature motion of the app, so it
    /// gets the most overshoot of anything here -- but only just.
    static let panel = Animation.spring(response: 0.38, dampingFraction: 0.78, blendDuration: 0.1)

    /// Switching between tabs inside an already-open panel. Faster and flatter:
    /// the container is not moving, only its contents, so overshoot here reads
    /// as instability rather than liveliness.
    static let tabSwitch = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// Content appearing/disappearing inside the pill (a timer starting, a
    /// transient toast). Snappy, because these are frequent and small.
    static let pillContent = Animation.spring(response: 0.30, dampingFraction: 0.82)

    /// Anything the user is dragging: volume, brightness, scrub position.
    /// `interactiveSpring` is specifically tuned for gesture-tracking -- it has
    /// a much shorter response so the control stays under the finger/cursor
    /// instead of lagging behind it.
    static let interactive = Animation.interactiveSpring(response: 0.18, dampingFraction: 0.86, blendDuration: 0.05)

    /// Progress rings and bars advancing on a data tick. Deliberately *not* a
    /// spring: a CPU gauge that overshoots is lying about the data. This is the
    /// one place easing is correct, and it is linear-ish on purpose because it
    /// is interpolating between two real samples.
    static let dataTick = Animation.easeOut(duration: 0.45)

    /// Sheets/popovers within the panel.
    static let sheet = Animation.spring(response: 0.34, dampingFraction: 0.85)

    /// Dock magnification. Very short response and near-critical damping: the
    /// icons must track the cursor, and any overshoot here reads as the whole
    /// dock wobbling because several items are animating out of phase at once.
    static let dockMagnify = Animation.interactiveSpring(response: 0.14, dampingFraction: 0.92)
}

// MARK: - Shared view furniture

/// The rounded container used by every card in the expanded panel.
struct NBCard<Content: View>: View {
    @EnvironmentObject private var themes: ThemeManager
    var tint: ModuleTint = .system
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        let theme = themes.theme
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.tint(tint).opacity(theme.kind == .neon ? 0.35 : 0.10), lineWidth: 1)
                    )
            )
    }
}

/// A compact ring gauge (CPU/RAM/Disk, pomodoro, timer progress).
struct NBRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 5
    var glow: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .themeGlow(tint, radius: glow)
                .animation(Motion.dataTick, value: progress)
        }
    }
}

/// Buttons in the panel must not look like AppKit buttons -- the panel is drawn
/// chrome, and a stock bordered button breaks the illusion immediately.
struct NBButtonStyle: ButtonStyle {
    var tint: Color
    var filled: Bool = false
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(filled ? tint.opacity(configuration.isPressed ? 0.55 : 0.85)
                                 : tint.opacity(configuration.isPressed ? 0.28 : 0.15))
            )
            .foregroundStyle(filled ? Color.black.opacity(0.9) : tint)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(Motion.interactive, value: configuration.isPressed)
            // Every drawn button in the app routes through this style, so this
            // one line is most of the app's click affordance. The remaining
            // call sites are the ones that are clickable without being buttons:
            // tiles, icons, day cells, list rows.
            .pointerCursor()
    }
}

/// Section header inside a tab.
struct NBSectionHeader: View {
    @EnvironmentObject private var themes: ThemeManager
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 10, weight: .medium))
            }
        }
        .foregroundStyle(themes.theme.secondaryText)
    }
}

/// Shown by a tab that has nothing to display yet, instead of a blank rectangle.
struct NBEmptyState: View {
    @EnvironmentObject private var themes: ThemeManager
    let symbol: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
            Text(title).font(.system(size: 12, weight: .medium))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
            }
        }
        .foregroundStyle(themes.theme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

/// A text field that looks native to the panel rather than to AppKit.
struct NBTextField: View {
    @EnvironmentObject private var themes: ThemeManager
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        let theme = themes.theme
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .onSubmit { onSubmit?() }
    }
}

// MARK: - The transient sweep

/// Every transient pop-in in the app -- "Copied", "Converted 3 files", "Backup
/// finished" -- enters the same way: a highlight that travels **right to left**
/// across the notch and settles on the left shoulder, then leaves by continuing
/// left rather than fading where it stands.
///
/// This is deliberately one shared transition rather than a per-feature
/// animation. The notch is a single ~700pt-wide surface; if the clipboard toast
/// fades, the converter toast scales and the backup toast drops in, the surface
/// reads as three unrelated widgets sharing a strip of glass. One motion for one
/// category of message is what makes it read as a single piece of hardware.
///
/// `progress` is 1 when the content is parked off the right edge and 0 at rest.
/// Removal drives it negative so the exit continues the same leftward travel
/// instead of reversing it -- a reversal would read as "it came back", which is
/// the wrong story for a message that has just expired.
struct NotchSweep: ViewModifier, Animatable {
    var progress: Double
    var distance: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: distance * CGFloat(progress))
            // Fade only near the ends of the travel, so the middle of the sweep
            // is fully opaque and the eye can actually read the text in motion.
            .opacity(1 - min(1, abs(progress) * 1.6))
            // A touch of horizontal compression while travelling. Real objects
            // moving fast do not stay geometrically perfect, and this is the
            // cheapest possible nod to that without a motion-blur shader.
            .scaleEffect(x: 1 - min(0.12, abs(progress) * 0.2), y: 1, anchor: .center)
    }
}

extension AnyTransition {
    /// Right-to-left traverse across the notch. `distance` should be the full
    /// travel width -- the collapsed pill's width -- so the content genuinely
    /// starts beyond the right edge instead of popping in halfway.
    static func notchSweep(distance: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: NotchSweep(progress: 1.0, distance: distance),
                                 identity: NotchSweep(progress: 0, distance: distance)),
            removal: .modifier(active: NotchSweep(progress: -0.75, distance: distance),
                               identity: NotchSweep(progress: 0, distance: distance))
        )
    }
}

extension Motion {
    /// The transient sweep. Slower response than `pillContent` because the
    /// content is crossing the whole width of the notch rather than appearing in
    /// place, and higher damping because a toast that overshoots and settles
    /// back rightward contradicts the direction of travel.
    static let sweepIn = Animation.spring(response: 0.46, dampingFraction: 0.90)
    /// The exit continues leftward and does not need to settle, so it is eased.
    static let sweepOut = Animation.easeIn(duration: 0.26)
}

/// The moving specular band that rides along with a sweeping transient.
///
/// It is a plain animated gradient offset rather than a `.mask` over live
/// content: masking the text would force SwiftUI to rasterise the label every
/// frame of the sweep, which is exactly the kind of cost this app spends its
/// whole architecture avoiding.
struct SweepHighlight: View {
    var tint: Color
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, tint.opacity(0.28), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.45)
            .offset(x: geo.size.width * phase)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onAppear {
                phase = 1.2
                withAnimation(.easeOut(duration: 0.55)) { phase = -0.6 }
            }
        }
    }
}

// MARK: - The transient toast

/// The other way a transient can arrive: a capsule that drops just below the
/// notch, holds, and fades upward.
///
/// ## Why offer two at all
/// The sweep uses the hardware -- the message travels *along* the notch, and it
/// reads as the machine telling you something. That is the better idea and it
/// stays the default. But it is also unfamiliar, it needs the full width of the
/// pill to play out, and on a notchless display it has much less to work with.
///
/// The toast is the shape every phone has trained people to read without
/// looking directly at it: appear near where you are already looking, hold
/// briefly, leave. For a "Copied" that fires twenty times an hour, the
/// unremarkable one is arguably the right one.
///
/// Both are still **one** animation applied to every transient. What the setting
/// picks is which of the two, not which one a given feature gets to use -- the
/// thing that made the original per-feature animations wrong was the
/// inconsistency, not the specific curve.
struct ToastDrop: ViewModifier, Animatable {
    /// -1 is fully above and hidden, 0 is resting, +1 is drifted up and gone.
    var phase: Double
    var travel: CGFloat

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func body(content: Content) -> some View {
        content
            // Entry drops *down* out of the notch and exit drifts *up* back
            // into it, so the notch is visibly where the message came from.
            .offset(y: travel * CGFloat(phase))
            .opacity(1 - min(1, abs(phase)))
            // A small overshoot in scale on the way in is what makes a toast
            // read as arriving rather than as being revealed.
            .scaleEffect(1 - min(0.10, abs(phase) * 0.14), anchor: .top)
    }
}

extension AnyTransition {
    static func toastDrop(travel: CGFloat = 14) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: ToastDrop(phase: -1, travel: travel),
                                 identity: ToastDrop(phase: 0, travel: travel)),
            removal: .modifier(active: ToastDrop(phase: 1, travel: travel),
                               identity: ToastDrop(phase: 0, travel: travel)))
    }
}

extension Motion {
    /// The toast arriving. A touch more overshoot than `pillContent`: it is a
    /// small object moving a short distance and it should feel light.
    static let toastIn = Animation.spring(response: 0.34, dampingFraction: 0.72)
    /// Leaving. Quick and eased -- nobody watches a toast leave.
    static let toastOut = Animation.easeIn(duration: 0.22)
}

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

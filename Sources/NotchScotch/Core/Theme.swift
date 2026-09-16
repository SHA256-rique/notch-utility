import SwiftUI
import AppKit

/// Themes only restyle NotchScotch's own surfaces -- nothing here reaches
/// outside the app's windows.
///
/// ## Light themes and the pill
/// Two of these are light, and they deliberately do **not** lighten the
/// collapsed pill. The pill's job is to be continuous with a black plastic
/// cutout; a cream-coloured tab hanging off the notch would be the most visible
/// thing on the screen. Light themes apply to the expanded panel, which is a
/// window, and leave Tier 1 dark.
enum ThemeKind: String, Codable, CaseIterable, Identifiable {
    case minimal, playful, neon, ember, midnight, latte, parchment

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal:   return "Minimal"
        case .playful:   return "Playful"
        case .neon:      return "Neon"
        case .ember:     return "Ember"
        case .midnight:  return "Midnight"
        case .latte:     return "Latte"
        case .parchment: return "Parchment"
        }
    }

    var blurb: String {
        switch self {
        case .minimal:   return "Black and white. Nothing competes with your content."
        case .playful:   return "One accent colour per module, so tabs are recognisable by hue."
        case .neon:      return "Saturated and glowing. Best on a dark desktop."
        case .ember:     return "Black and red. Warm, low, and easy at night."
        case .midnight:  return "Black, blue and white. Cool and high-contrast."
        case .latte:     return "Beige and coffee. Light, for a bright desktop."
        case .parchment: return "Warm paper and ink. The quietest light theme."
        }
    }

    /// True when the expanded panel is a light surface, which flips text,
    /// strokes and card fills throughout.
    var isLight: Bool { self == .latte || self == .parchment }

    /// Whether module tints apply. Minimal collapses everything to one colour
    /// on purpose; the two-tone themes do the same for the same reason.
    var usesModuleTints: Bool {
        switch self {
        case .minimal, .ember, .midnight: return false
        default: return true
        }
    }
}

/// A module identity, used by Playful/Neon to give each tab its own accent.
enum ModuleTint: String {
    case home, time, snippets, notes, calendar, files, api, docker, terminal, ai, message, settings, system, battery, media, approval, custom
}

struct Theme {
    let kind: ThemeKind

    // MARK: Surfaces

    /// Pill and panel background. Kept quite opaque because the panel sits over
    /// arbitrary desktop content and text legibility beats translucency.
    var panelBackground: Color {
        switch kind {
        case .minimal:   return Color.black.opacity(0.92)
        case .playful:   return Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.94)
        case .neon:      return Color(red: 0.03, green: 0.01, blue: 0.08).opacity(0.95)
        case .ember:     return Color(red: 0.08, green: 0.04, blue: 0.04).opacity(0.94)
        case .midnight:  return Color(red: 0.04, green: 0.06, blue: 0.10).opacity(0.94)
        case .latte:     return Color(red: 0.96, green: 0.93, blue: 0.88).opacity(0.97)
        case .parchment: return Color(red: 0.97, green: 0.95, blue: 0.91).opacity(0.97)
        }
    }

    var panelStroke: Color {
        switch kind {
        case .minimal:   return Color.white.opacity(0.10)
        case .playful:   return Color.white.opacity(0.13)
        case .neon:      return Color(red: 0.55, green: 0.25, blue: 1.0).opacity(0.45)
        case .ember:     return Color(red: 0.86, green: 0.22, blue: 0.24).opacity(0.28)
        case .midnight:  return Color(red: 0.36, green: 0.62, blue: 1.00).opacity(0.28)
        case .latte:     return Color(red: 0.38, green: 0.28, blue: 0.20).opacity(0.18)
        case .parchment: return Color(red: 0.30, green: 0.26, blue: 0.20).opacity(0.16)
        }
    }

    var cardBackground: Color {
        switch kind {
        case .minimal:   return Color.white.opacity(0.06)
        case .playful:   return Color.white.opacity(0.07)
        case .neon:      return Color(red: 0.36, green: 0.16, blue: 0.78).opacity(0.18)
        case .ember:     return Color(red: 0.92, green: 0.24, blue: 0.24).opacity(0.10)
        case .midnight:  return Color(red: 0.40, green: 0.66, blue: 1.00).opacity(0.10)
        // Light themes need a card that is *darker* than the panel, not
        // lighter -- the usual white-over-dark trick inverts to nothing here.
        case .latte:     return Color(red: 0.42, green: 0.31, blue: 0.22).opacity(0.09)
        case .parchment: return Color(red: 0.34, green: 0.29, blue: 0.22).opacity(0.07)
        }
    }

    /// Fill for text fields, editors and any other inset control.
    ///
    /// The app is full of `Color.white.opacity(0.07)` used as "slightly lighter
    /// than the panel". On a cream panel that is invisible, so the two light
    /// themes invert it to a wash of their own ink. Every shared control reads
    /// this rather than the literal.
    var fieldBackground: Color {
        isLight ? Color(red: 0.40, green: 0.30, blue: 0.20).opacity(0.10)
                : Color.white.opacity(0.07)
    }

    /// A barely-there wash over the panel, for dock strips and side rails.
    var surfaceTint: Color {
        isLight ? Color(red: 0.40, green: 0.30, blue: 0.20).opacity(0.06)
                : Color.white.opacity(0.04)
    }

    var primaryText: Color {
        switch kind {
        case .latte:     return Color(red: 0.20, green: 0.14, blue: 0.09)
        case .parchment: return Color(red: 0.16, green: 0.14, blue: 0.11)
        default:         return .white
        }
    }

    var secondaryText: Color {
        switch kind {
        case .neon:      return Color(red: 0.78, green: 0.72, blue: 1.0).opacity(0.85)
        case .ember:     return Color(red: 1.00, green: 0.82, blue: 0.80).opacity(0.60)
        case .midnight:  return Color(red: 0.82, green: 0.90, blue: 1.00).opacity(0.62)
        case .latte:     return Color(red: 0.34, green: 0.25, blue: 0.17).opacity(0.72)
        case .parchment: return Color(red: 0.28, green: 0.24, blue: 0.18).opacity(0.70)
        default:         return Color.white.opacity(0.62)
        }
    }

    /// Global accent, used where no module is in play.
    var accent: Color {
        switch kind {
        case .minimal:   return .white
        case .playful:   return Color(red: 0.30, green: 0.66, blue: 1.0)
        case .neon:      return Color(red: 0.62, green: 0.30, blue: 1.0)
        case .ember:     return Color(red: 0.94, green: 0.26, blue: 0.24)
        case .midnight:  return Color(red: 0.36, green: 0.64, blue: 1.00)
        case .latte:     return Color(red: 0.47, green: 0.31, blue: 0.19)
        case .parchment: return Color(red: 0.55, green: 0.35, blue: 0.22)
        }
    }

    /// Per-module accent. Minimal collapses every module to white on purpose --
    /// that *is* the theme, not an unfinished case.
    func tint(_ module: ModuleTint) -> Color {
        // Single-accent themes collapse every module to one colour. That *is*
        // the theme, not an unfinished case.
        guard kind.usesModuleTints else { return accent }
        let base: Color
        switch module {
        case .home:     base = Color(red: 0.32, green: 0.68, blue: 1.00)
        case .time:     base = Color(red: 1.00, green: 0.56, blue: 0.24)
        case .snippets: base = Color(red: 0.42, green: 0.84, blue: 0.52)
        case .notes:    base = Color(red: 1.00, green: 0.82, blue: 0.32)
        case .calendar: base = Color(red: 1.00, green: 0.38, blue: 0.44)
        case .files:    base = Color(red: 0.60, green: 0.52, blue: 1.00)
        case .api:      base = Color(red: 0.26, green: 0.80, blue: 0.80)
        case .docker:   base = Color(red: 0.24, green: 0.60, blue: 0.94)
        case .terminal: base = Color(red: 0.52, green: 0.94, blue: 0.62)
        case .ai:       base = Color(red: 0.84, green: 0.50, blue: 1.00)
        case .message:  base = Color(red: 1.00, green: 0.46, blue: 0.72)
        case .settings: base = Color(red: 0.70, green: 0.72, blue: 0.78)
        case .system:   base = Color(red: 0.36, green: 0.86, blue: 0.94)
        case .battery:  base = Color(red: 0.40, green: 0.88, blue: 0.48)
        case .media:    base = Color(red: 1.00, green: 0.44, blue: 0.62)
        case .approval: base = Color(red: 1.00, green: 0.70, blue: 0.20)
        case .custom:   base = Color(red: 0.55, green: 0.75, blue: 0.95)
        }
        // Neon pushes toward full saturation and relies on the glow modifier
        // below. Light themes darken every tint instead: the palette above is
        // tuned for white text on black, and the same hues on cream are
        // unreadable without dropping their luminance.
        guard kind.isLight else { return base }
        return base.darkened(by: 0.42)
    }

    /// Neon's signature is an outer glow; the other themes return a no-op radius
    /// so callers do not need a branch at every call site.
    func glowRadius(_ base: CGFloat = 6) -> CGFloat { kind == .neon ? base : 0 }

    var cornerRadius: CGFloat { 18 }

    var isLight: Bool { kind.isLight }
}

extension Color {
    /// Blends toward black. Used to make the module palette legible on a light
    /// panel without maintaining a second set of hues.
    func darkened(by amount: Double) -> Color {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let factor = 1 - max(0, min(1, amount))
        return Color(.sRGB,
                     red: Double(nsColor.redComponent) * factor,
                     green: Double(nsColor.greenComponent) * factor,
                     blue: Double(nsColor.blueComponent) * factor,
                     opacity: Double(nsColor.alphaComponent))
    }
}

/// Observable holder so SwiftUI views re-render on theme change without every
/// view having to observe `Settings` wholesale.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    @Published private(set) var theme = Theme(kind: .minimal)

    func apply(_ kind: ThemeKind) {
        guard kind != theme.kind else { return }
        theme = Theme(kind: kind)
    }
}

// MARK: - Small shared view helpers

extension View {
    /// Neon glow that compiles away to nothing in the other two themes.
    @ViewBuilder
    func themeGlow(_ color: Color, radius: CGFloat) -> some View {
        if radius > 0 { self.shadow(color: color.opacity(0.75), radius: radius) }
        else { self }
    }
}

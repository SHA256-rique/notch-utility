import SwiftUI

/// Three themes from the brief. Themes only restyle NotchScotch's own surfaces --
/// nothing here reaches outside the app's windows.
enum ThemeKind: String, Codable, CaseIterable, Identifiable {
    case minimal, playful, neon
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .playful: return "Playful"
        case .neon:    return "Neon"
        }
    }
    var blurb: String {
        switch self {
        case .minimal: return "Black and white. Nothing competes with your content."
        case .playful: return "One accent colour per module, so tabs are recognisable by hue."
        case .neon:    return "Saturated and glowing. Best on a dark desktop."
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
        case .minimal: return Color.black.opacity(0.92)
        case .playful: return Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.94)
        case .neon:    return Color(red: 0.03, green: 0.01, blue: 0.08).opacity(0.95)
        }
    }

    var panelStroke: Color {
        switch kind {
        case .minimal: return Color.white.opacity(0.10)
        case .playful: return Color.white.opacity(0.13)
        case .neon:    return Color(red: 0.55, green: 0.25, blue: 1.0).opacity(0.45)
        }
    }

    var cardBackground: Color {
        switch kind {
        case .minimal: return Color.white.opacity(0.06)
        case .playful: return Color.white.opacity(0.07)
        case .neon:    return Color(red: 0.36, green: 0.16, blue: 0.78).opacity(0.18)
        }
    }

    var primaryText: Color { .white }
    var secondaryText: Color {
        switch kind {
        case .neon: return Color(red: 0.78, green: 0.72, blue: 1.0).opacity(0.85)
        default:    return Color.white.opacity(0.62)
        }
    }

    /// Global accent, used where no module is in play.
    var accent: Color {
        switch kind {
        case .minimal: return .white
        case .playful: return Color(red: 0.30, green: 0.66, blue: 1.0)
        case .neon:    return Color(red: 0.62, green: 0.30, blue: 1.0)
        }
    }

    /// Per-module accent. Minimal collapses every module to white on purpose --
    /// that *is* the theme, not an unfinished case.
    func tint(_ module: ModuleTint) -> Color {
        guard kind != .minimal else { return .white }
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
        // Neon pushes toward full saturation and relies on the glow modifier below.
        return kind == .neon ? base.opacity(1.0) : base
    }

    /// Neon's signature is an outer glow; the other themes return a no-op radius
    /// so callers do not need a branch at every call site.
    func glowRadius(_ base: CGFloat = 6) -> CGFloat { kind == .neon ? base : 0 }

    var cornerRadius: CGFloat { 18 }
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

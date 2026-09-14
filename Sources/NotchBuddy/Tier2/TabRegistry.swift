import SwiftUI

/// Identity for a Tier-2 tab. String-backed because the enabled/ordered list is
/// persisted to JSON, and a raw-value string survives reordering and removal of
/// cases in a way an Int would not.
enum TabID: String, Codable, CaseIterable, Identifiable, Hashable {
    case home, time, snippets, notes, calendar, files, api, docker, terminal, ai, message, settings
    var id: String { rawValue }

    static let defaultOrder: [String] = TabID.allCases.map(\.rawValue)

    var title: String {
        switch self {
        case .home: return "Home"
        case .time: return "Time"
        case .snippets: return "Snippets"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .files: return "Files"
        case .api: return "API"
        case .docker: return "Docker"
        case .terminal: return "Terminal"
        case .ai: return "AI Chat"
        case .message: return "Message"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2.fill"
        case .time: return "timer"
        case .snippets: return "doc.on.clipboard.fill"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        case .files: return "arrow.triangle.2.circlepath.doc.on.clipboard"
        case .api: return "network"
        case .docker: return "shippingbox.fill"
        case .terminal: return "terminal.fill"
        case .ai: return "sparkles"
        case .message: return "text.bubble.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tint: ModuleTint {
        switch self {
        case .home: return .home
        case .time: return .time
        case .snippets: return .snippets
        case .notes: return .notes
        case .calendar: return .calendar
        case .files: return .files
        case .api: return .api
        case .docker: return .docker
        case .terminal: return .terminal
        case .ai: return .ai
        case .message: return .message
        case .settings: return .settings
        }
    }

    /// Tabs that need real keystrokes routed to them. The panel is a
    /// non-activating panel by default (so clicking the pill never steals focus
    /// from the user's editor); opening one of these flips `wantsKeyboardFocus`
    /// and only then does the app activate.
    var needsKeyboardFocus: Bool {
        switch self {
        case .terminal, .ai, .notes, .api, .message, .snippets, .settings: return true
        default: return false
        }
    }
}

/// A tab currently on screen -- either a built-in or a user-configured custom tab.
enum ActiveTab: Equatable, Hashable {
    case builtin(TabID)
    case custom(UUID)
}

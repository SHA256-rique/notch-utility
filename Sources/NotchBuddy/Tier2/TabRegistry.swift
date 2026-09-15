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

    /// How much room this tab wants when it is the one on screen.
    ///
    /// ## Why not one size for everything
    /// Every tab used to open at 680x420, which meant the panel was sized for
    /// none of them: the terminal got 28 rows on a 15" display, the Home grid
    /// scrolled after four tiles, and the Message composer sat in a box twice
    /// the height of its content with a grey void underneath. A single size is
    /// only right if every tab holds the same amount, and they visibly do not.
    ///
    /// The panel is drawn chrome hanging from the notch, so it cannot be
    /// user-resizable without inventing a grab handle and a persisted size per
    /// tab. Declaring the size each tab actually wants gets most of that value
    /// for none of that complexity, and the resize rides the same spring as the
    /// open/close animation.
    var preferredSize: CGSize {
        switch self {
        case .home:     return CGSize(width: 640, height: 470)   // ten tiles, two columns
        case .time:     return CGSize(width: 620, height: 440)
        case .snippets: return CGSize(width: 800, height: 450)   // list plus the task board
        case .notes:    return CGSize(width: 600, height: 430)
        case .calendar: return CGSize(width: 650, height: 470)   // month grid plus a day list
        case .files:    return CGSize(width: 660, height: 440)
        case .api:      return CGSize(width: 720, height: 480)   // request above, response below
        case .docker:   return CGSize(width: 660, height: 400)
        case .terminal: return CGSize(width: 820, height: 510)   // columns matter here more than anywhere
        case .ai:       return CGSize(width: 680, height: 480)
        case .message:  return CGSize(width: 620, height: 400)
        case .settings: return CGSize(width: 700, height: 490)
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

/// A view that is worth a full page but not worth a permanent place in the dock.
///
/// ## Why these are not `TabID` cases
/// A tab in the dock is a claim on the user's attention forever. Screen Time,
/// a revenue breakdown and a storage report are things you look at occasionally
/// and then stop looking at -- and a dock with twelve permanent icons is already
/// at the limit of what fits beside the pin and close buttons on a 680pt panel.
///
/// So they work the way an editor's tabs do: a tile opens one, it appears in the
/// dock with a close button, and closing it is how you leave. Nothing about them
/// is persisted -- a relaunch starts with none open, which is right, because
/// none of them is where you left off working.
///
/// The rule for deciding which a thing should be: if you would be annoyed to
/// find it *gone* from the dock tomorrow, it is a `TabID`. If you would be
/// annoyed to find it *still there* tomorrow, it is a `DetailTab`.
enum DetailTab: String, CaseIterable, Identifiable, Hashable {
    case screenTime
    case revenue
    case claudeUsage
    case dailyWord
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenTime:  return "Screen Time"
        case .revenue:     return "Revenue"
        case .claudeUsage: return "Claude Usage"
        case .dailyWord:   return "Word of the Day"
        case .storage:     return "Storage"
        }
    }

    /// Shown in the dock beside the icon. Deliberately shorter than `title`:
    /// the dock is a strip, not a menu.
    var shortTitle: String {
        switch self {
        case .screenTime:  return "Screen"
        case .revenue:     return "Revenue"
        case .claudeUsage: return "Usage"
        case .dailyWord:   return "Word"
        case .storage:     return "Storage"
        }
    }

    var symbol: String {
        switch self {
        case .screenTime:  return "hourglass"
        case .revenue:     return "dollarsign.circle"
        case .claudeUsage: return "sparkles.rectangle.stack"
        case .dailyWord:   return "character.book.closed"
        case .storage:     return "internaldrive"
        }
    }

    var tint: ModuleTint {
        switch self {
        case .screenTime:  return .home
        case .revenue:     return .api
        case .claudeUsage: return .ai
        case .dailyWord:   return .notes
        case .storage:     return .files
        }
    }

    var preferredSize: CGSize {
        switch self {
        case .screenTime:  return CGSize(width: 660, height: 480)  // chart plus a per-app list
        case .revenue:     return CGSize(width: 640, height: 450)
        case .claudeUsage: return CGSize(width: 680, height: 470)
        case .dailyWord:   return CGSize(width: 620, height: 450)
        case .storage:     return CGSize(width: 640, height: 450)
        }
    }
}

/// A tab currently on screen -- a built-in, a user-configured custom tab, or an
/// on-demand detail.
enum ActiveTab: Equatable, Hashable {
    case builtin(TabID)
    case custom(UUID)
    case detail(DetailTab)
}

import Foundation
import SwiftUI

/// LLM providers. Adding one means adding a case plus a branch in `LLMClient`;
/// nothing in the UI is hardcoded to a particular vendor.
enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai, ollama
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .ollama:    return "Ollama (local)"
        }
    }
    /// Keychain account name. Ollama is local and keyless, but it still gets an
    /// account slot so the code path has no special case.
    var keychainAccount: String { "llm.\(rawValue)" }
    var needsKey: Bool { self != .ollama }
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openai:    return "gpt-4o-mini"
        case .ollama:    return "llama3.2"
        }
    }
    var defaultEndpoint: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openai:    return "https://api.openai.com/v1/chat/completions"
        case .ollama:    return "http://127.0.0.1:11434/api/chat"
        }
    }
}

/// The fixed catalogue of *types* a user-added tab can be.
///
/// This is config-driven by design: the user picks a type and fills in fields.
/// There is no bundle loading, no JS runtime, no dlopen of user code. See
/// docs/decisions/0010-config-driven-custom-tabs.md for why a plugin runtime was
/// rejected for v1.
enum CustomTabKind: String, Codable, CaseIterable, Identifiable {
    case webView       // a pinned page at a URL
    case launcher      // a grid of app/file shortcuts
    case snippetList   // a filtered view of the snippet store
    case metric        // a number pulled from a URL + JSON path
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .webView:     return "Pinned Web Page"
        case .launcher:    return "Shortcut Launcher"
        case .snippetList: return "Snippet List"
        case .metric:      return "Custom Metric"
        }
    }
    var symbol: String {
        switch self {
        case .webView: return "globe"
        case .launcher: return "square.grid.2x2"
        case .snippetList: return "text.badge.star"
        case .metric: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct CustomTabConfig: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: CustomTabKind
    var title: String
    var symbol: String
    // Kind-specific fields; unused ones stay empty rather than becoming an
    // enum-with-payload, which keeps the Codable round-trip forgiving when a
    // user edits the JSON by hand or an older build reads a newer file.
    var url: String = ""
    var jsonPath: String = ""           // e.g. "data.today.total"
    var unit: String = ""
    var refreshSeconds: Double = 300
    var headers: [String: String] = [:]
    var shortcutPaths: [String] = []
    var snippetTagFilter: String = ""
}

/// A home-grid widget the user can add, remove and drag to reorder.
///
/// These are deliberately *named* widgets, not instances of one generic
/// "number from a URL" tile. Revenue knows what a paid customer is; Visitors
/// knows what a 30-day sparkline is; Claude usage knows what a day streak is.
/// Only their data sources are configurable -- their shape is not, because a
/// tile that renders whatever the endpoint happened to return is a debugging
/// tool, not a dashboard.
enum HomeWidgetKind: String, Codable, CaseIterable, Identifiable {
    case systemRings, soundLight, screenTime, revenue, claudeUsage
    case weather, nowPlaying, quickTimer, dailyWord, launch
    case visitors, customMetric

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screenTime:   return "Screen Time"
        case .weather:      return "Weather"
        case .soundLight:   return "Sound & Light"
        case .launch:       return "Launch"
        case .systemRings:  return "System"
        case .customMetric: return "Custom Metric"
        case .revenue:      return "Revenue"
        case .visitors:     return "Visitors"
        case .claudeUsage:  return "Claude Usage"
        case .nowPlaying:   return "Now Playing"
        case .quickTimer:   return "Quick Timer"
        case .dailyWord:    return "Word of the Day"
        }
    }

    var symbol: String {
        switch self {
        case .screenTime:   return "hourglass"
        case .weather:      return "cloud.sun"
        case .soundLight:   return "sun.max"
        case .launch:       return "square.grid.2x2"
        case .systemRings:  return "cpu"
        case .customMetric: return "chart.bar"
        case .revenue:      return "dollarsign.circle"
        case .visitors:     return "person.2.wave.2"
        case .claudeUsage:  return "sparkles.rectangle.stack"
        case .nowPlaying:   return "music.note"
        case .quickTimer:   return "timer"
        case .dailyWord:    return "character.book.closed"
        }
    }

    /// Widgets that span two grid columns because their content needs the width.
    var isWide: Bool {
        switch self {
        case .screenTime, .claudeUsage, .nowPlaying, .visitors: return true
        default: return false
        }
    }

    /// Everything except the widgets the brief says must be opt-in. Visitors is
    /// opt-in because most people have no analytics endpoint to point it at, and
    /// a permanently-unconfigured tile on the default grid is worse than no
    /// tile. Custom Metric is opt-in for the same reason.
    static let defaultGrid: [HomeWidgetKind] = [
        .systemRings, .soundLight, .screenTime, .revenue,
        .claudeUsage, .weather, .nowPlaying, .quickTimer, .dailyWord, .launch
    ]
}

/// Stripe-backed revenue. The secret key lives in Keychain under
/// `stripe.secret`; only the non-secret shape of the connection is stored here.
struct StripeConfig: Codable, Equatable {
    /// Overridable so a user can point this at their own proxy rather than
    /// putting a live Stripe secret key on a laptop -- which is the right thing
    /// to do and which we should not make harder than the naive path.
    var apiBase: String = "https://api.stripe.com/v1"
    /// Stripe reports minor units; this is only ever used for display.
    var currencySymbol: String = "$"
    /// Live-mode keys see live charges. A test key is the safe way to try it.
    var includeRefunded: Bool = false
}

/// Visitors. There is no universal "visitors" API, so the *source* is
/// configurable -- but the widget itself is not generic: it renders a live
/// count, a percent change and a 30-day sparkline, and nothing else.
struct VisitorsConfig: Codable, Equatable {
    var url: String = ""
    var headers: [String: String] = [:]
    /// Dot-paths into the response, resolved by `MetricFetcher.value(at:in:)`.
    var currentPath: String = "results.visitors.value"
    var previousPath: String = "results.visitors.previous"
    /// Must resolve to an array. Elements may be plain numbers or objects, in
    /// which case `seriesValuePath` is applied to each element.
    var seriesPath: String = "results.timeseries"
    var seriesValuePath: String = "visitors"
    var refreshSeconds: Double = 600
}

/// Word of the day. Multiple languages can be enabled at once; the widget
/// shows one card per enabled language.
struct DailyWordConfig: Codable, Equatable {
    var languages: [String] = [WordLanguage.spanish.rawValue]
    var showExample: Bool = true
}

struct SettingsData: Codable {
    var theme: ThemeKind = .minimal

    // MARK: Power

    /// The brief calls this a trust signal, and it is: it exposes the internal
    /// "don't poll while collapsed" rule as a switch the user can see and verify.
    /// Leaving it on means *zero* widget timers run unless the panel is attended.
    var batterySaver: Bool = true
    /// Pinning the panel open counts as "attended", so stats keep updating.
    var pinnedCountsAsAttended: Bool = true
    var statsPollInterval: Double = 2.0

    // MARK: Panel behaviour

    var hoverToExpand: Bool = true
    var hoverExpandDelay: Double = 0.18     // debounce so a cursor passing through does not trigger
    var hoverCollapseDelay: Double = 0.45
    var hideFromScreenRecordingPanel: Bool = false
    var hideFromScreenRecordingTeleprompter: Bool = true
    var launchAtLogin: Bool = false
    var globalHotKeyEnabled: Bool = true
    var globalHotKeyCode: UInt32 = 49       // Space
    var globalHotKeyModifiers: UInt32 = 0   // filled in at first run (cmd+opt)

    // MARK: Tier 1

    var showBatteryInPill: Bool = true
    var showNowPlayingInPill: Bool = true
    var showTimersInPill: Bool = true
    var showStatsInPill: Bool = true
    var showApprovalsInPill: Bool = true

    // MARK: Tabs

    var enabledTabs: [String] = TabID.defaultOrder
    /// Same idea as `homeGridVersion`: lets a tab that ships later appear in an
    /// existing dock without resetting an order the user arranged by hand.
    var tabDockVersion: Int = 0
    var customTabs: [CustomTabConfig] = []

    // MARK: Home grid

    var homeWidgets: [HomeWidgetKind] = HomeWidgetKind.defaultGrid
    /// Bumped when new widgets ship, so an existing grid gains them once
    /// instead of either never seeing them or being reset to defaults.
    var homeGridVersion: Int = 0
    var launchShortcuts: [String] = []      // file:// paths to .app bundles
    // Optional, not a NaN sentinel: JSONEncoder refuses to encode Double.nan,
    // which would silently break *all* settings persistence for any user who
    // hadn't set a location. Caught by a round-trip test; see
    // docs/learning/05-bugs-the-tests-caught.md
    var weatherLatitude: Double? = nil
    var weatherLongitude: Double? = nil
    var weatherPlaceName: String = ""
    var weatherUseCelsius: Bool = true
    var customMetricConfig: CustomTabConfig? = nil
    var stripe = StripeConfig()
    var visitors = VisitorsConfig()
    var dailyWord = DailyWordConfig()

    // MARK: Water

    var waterNudgesEnabled: Bool = false
    var waterIntervalMinutes: Double = 45
    var waterGlassGoal: Int = 8

    // MARK: Calendar

    /// Apple's EventKit and Google can both be on at once; the agenda merges
    /// them. Google needs its own OAuth client -- see `GoogleCalendarService`.
    var calendarUseAppleEventKit: Bool = true
    var calendarUseGoogle: Bool = false
    var googleOAuthClientID: String = ""

    // MARK: Snippets / clipboard

    var captureClipboard: Bool = true
    var clipboardHistoryLimit: Int = 200
    var captureFromPasswordManagers: Bool = false   // honours NSPasteboard transient/concealed hints

    // MARK: LLM

    var llmProvider: LLMProvider = .anthropic
    var llmModel: String = LLMProvider.anthropic.defaultModel
    var llmEndpointOverride: String = ""
    var selectionAssistEnabled: Bool = false        // requires Accessibility permission

    // MARK: Terminal

    var terminalShell: String = ""                  // empty -> $SHELL, then /bin/zsh
    var keepTerminalAliveInBackground: Bool = false // off by default, per the brief

    // MARK: Approvals

    var approvalHookEnabled: Bool = true
    var approvalStdoutFallbackEnabled: Bool = false
    var approvalAlwaysAllowRules: [String] = []     // e.g. "Read", "Bash:git status"
}

/// Single source of truth for user configuration.
///
/// Note what is absent: no API keys, no tokens. Those live in `Keychain` and are
/// fetched at the moment of use.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let store = JSONStore<SettingsData>(filename: "settings.json", debounce: 0.4)

    @Published var data: SettingsData {
        didSet {
            store.save(data)
            if data.theme != oldValue.theme { ThemeManager.shared.apply(data.theme) }
        }
    }

    private init() {
        var loaded = store.load() ?? SettingsData()
        if loaded.globalHotKeyModifiers == 0 {
            loaded.globalHotKeyModifiers = HotKeyCenter.defaultModifiers
        }
        Self.migrateHomeGrid(&loaded)
        Self.migrateTabDock(&loaded)
        self.data = loaded
        ThemeManager.shared.apply(loaded.theme)
    }

    var theme: Theme { ThemeManager.shared.theme }

    func flush() { store.saveNow(data) }

    /// Appends widgets that shipped after the user's grid was last written,
    /// preserving whatever order they had arranged. The alternative -- resetting
    /// to `defaultGrid` -- would throw away a deliberate arrangement every time
    /// we add a tile, and silently doing nothing would mean an existing user
    /// never discovers a new widget exists.
    ///
    /// Opt-in widgets are excluded by construction: `defaultGrid` does not
    /// contain them, so Visitors stays off the grid until it is added by hand,
    /// exactly as the brief requires.
    private static func migrateHomeGrid(_ data: inout SettingsData) {
        let currentVersion = 1
        guard data.homeGridVersion < currentVersion else { return }
        // A first run has no stored file at all, so the grid is already the
        // default; only stamp the version in that case.
        if !data.homeWidgets.isEmpty {
            for kind in HomeWidgetKind.defaultGrid where !data.homeWidgets.contains(kind) {
                data.homeWidgets.append(kind)
            }
        }
        data.homeGridVersion = currentVersion
    }

    /// Adds built-in tabs that shipped after this dock was last written, and
    /// repairs two things that would otherwise leave the user stuck: an
    /// `enabledTabs` list containing ids no longer in `TabID`, and a dock
    /// missing Settings, which is the only route back to fixing any of it.
    private static func migrateTabDock(_ data: inout SettingsData) {
        data.enabledTabs = data.enabledTabs.filter { TabID(rawValue: $0) != nil }

        let currentVersion = 1
        if data.tabDockVersion < currentVersion {
            if !data.enabledTabs.isEmpty {
                for id in TabID.defaultOrder where !data.enabledTabs.contains(id) {
                    data.enabledTabs.append(id)
                }
            }
            data.tabDockVersion = currentVersion
        }

        if data.enabledTabs.isEmpty { data.enabledTabs = TabID.defaultOrder }
        if !data.enabledTabs.contains(TabID.settings.rawValue) {
            data.enabledTabs.append(TabID.settings.rawValue)
        }
    }
}

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

/// A home-grid widget the user can add/remove/reorder.
enum HomeWidgetKind: String, Codable, CaseIterable, Identifiable {
    case screenTime, weather, soundLight, launch, systemRings, customMetric
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .screenTime:   return "Screen Time"
        case .weather:      return "Weather"
        case .soundLight:   return "Sound & Light"
        case .launch:       return "Launch"
        case .systemRings:  return "System"
        case .customMetric: return "Custom Metric"
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
        }
    }
    /// Widgets that span two grid columns because their content needs the width.
    var isWide: Bool { self == .screenTime }
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
    var customTabs: [CustomTabConfig] = []

    // MARK: Home grid

    var homeWidgets: [HomeWidgetKind] = [.systemRings, .soundLight, .screenTime, .weather, .launch]
    var launchShortcuts: [String] = []      // file:// paths to .app bundles
    var weatherLatitude: Double = .nan
    var weatherLongitude: Double = .nan
    var weatherPlaceName: String = ""
    var weatherUseCelsius: Bool = true
    var customMetricConfig: CustomTabConfig? = nil

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
        self.data = loaded
        ThemeManager.shared.apply(loaded.theme)
    }

    var theme: Theme { ThemeManager.shared.theme }

    func flush() { store.saveNow(data) }
}

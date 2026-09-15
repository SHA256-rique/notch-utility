import SwiftUI
import Carbon.HIToolbox

struct SettingsTabView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", power = "Power", tabs = "Tabs", widgets = "Widgets"
        case ai = "AI", approvals = "Approvals", about = "About"
        var id: String { rawValue }
    }

    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @State private var page: Page = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch page {
                    case .general:   GeneralSettings()
                    case .power:     PowerSettings()
                    case .tabs:      TabsSettings()
                    case .widgets:   WidgetSettings()
                    case .ai:        AISettings()
                    case .approvals: ApprovalStatusView()
                    case .about:     AboutSettings()
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Theme")
        HStack(spacing: 6) {
            ForEach(ThemeKind.allCases) { kind in
                Button {
                    settings.data.theme = kind
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.displayName).font(.system(size: 11, weight: .semibold))
                        Text(kind.blurb).font(.system(size: 8)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(NBButtonStyle(tint: theme.accent, filled: settings.data.theme == kind))
            }
        }
        Text("Themes only restyle NotchBuddy's own windows. Nothing here touches system appearance.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)

        NBSectionHeader(title: "Panel")
        toggle("Expand when I hover the notch", $settings.data.hoverToExpand, theme)
        HStack(spacing: 10) {
            labelledSlider("Open delay", value: $settings.data.hoverExpandDelay, range: 0...0.6, theme: theme)
            labelledSlider("Close delay", value: $settings.data.hoverCollapseDelay, range: 0.1...1.5, theme: theme)
        }
        Text("A short delay in each direction stops the panel flickering when the cursor merely crosses the top of the screen.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)

        toggle("Hide the notch panel from screen recording", $settings.data.hideFromScreenRecordingPanel, theme) {
            NotchPanelController.shared.settingsChanged()
        }
        toggle("Hide the teleprompter from screen recording", $settings.data.hideFromScreenRecordingTeleprompter, theme) {
            TeleprompterController.shared.hideFromCapture = settings.data.hideFromScreenRecordingTeleprompter
            TeleprompterController.shared.applyCaptureHiding()
        }

        NBSectionHeader(title: "System")
        toggle("Launch at login", $settings.data.launchAtLogin, theme) {
            let ok = LaunchAtLogin.set(settings.data.launchAtLogin)
            if !ok { settings.data.launchAtLogin = LaunchAtLogin.isEnabled }
        }

        HStack(spacing: 8) {
            Toggle("", isOn: $settings.data.globalHotKeyEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .onChange(of: settings.data.globalHotKeyEnabled) { AppDelegate.shared?.refreshHotKey() }
            Text("Global hotkey").font(.system(size: 11)).foregroundStyle(theme.primaryText)
            Picker("", selection: $settings.data.globalHotKeyCode) {
                ForEach(HotKeyCenter.choices, id: \.code) { Text($0.label).tag($0.code) }
            }
            .labelsHidden().frame(width: 80)
            .onChange(of: settings.data.globalHotKeyCode) { AppDelegate.shared?.refreshHotKey() }
            Text(HotKeyCenter.describe(keyCode: settings.data.globalHotKeyCode,
                                       modifiers: settings.data.globalHotKeyModifiers))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.accent)
            Spacer()
        }
        Text("Registered with the window server via Carbon, which is the only hotkey API that doesn't require Accessibility access.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)

        NBSectionHeader(title: "Clipboard")
        toggle("Capture clipboard history", $settings.data.captureClipboard, theme) {
            settings.data.captureClipboard ? ClipboardWatcher.shared.start() : ClipboardWatcher.shared.stop()
        }
        toggle("Also capture from password managers", $settings.data.captureFromPasswordManagers, theme)
        Text("Off by default. Apps mark secrets with a 'concealed' pasteboard type; NotchBuddy skips those unless you turn this on.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
        HStack {
            Text("History limit").font(.system(size: 11)).foregroundStyle(theme.primaryText)
            Stepper(value: $settings.data.clipboardHistoryLimit, in: 20...1000, step: 20) {
                Text("\(settings.data.clipboardHistoryLimit)").font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(theme.primaryText)
            }
            .frame(width: 110)
            Spacer()
        }

        NBSectionHeader(title: "Teleprompter")
        Button(TeleprompterController.shared.isOpen ? "Close teleprompter" : "Open teleprompter") {
            TeleprompterController.shared.isOpen
                ? TeleprompterController.shared.close()
                : TeleprompterController.shared.open()
        }
        .buttonStyle(NBButtonStyle(tint: theme.tint(.notes)))
        TextEditor(text: Binding(get: { TeleprompterController.shared.script },
                                 set: { TeleprompterController.shared.script = $0
                                        TeleprompterController.shared.persist() }))
            .font(.system(size: 11))
            .scrollContentBackground(.hidden)
            .frame(height: 80)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
    }

    @ViewBuilder
    private func toggle(_ title: String, _ binding: Binding<Bool>, _ theme: Theme,
                        onChange: (() -> Void)? = nil) -> some View {
        HStack {
            Toggle("", isOn: binding)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .onChange(of: binding.wrappedValue) { onChange?() }
            Text(title).font(.system(size: 11)).foregroundStyle(theme.primaryText)
            Spacer()
        }
    }

    private func labelledSlider(_ title: String, value: Binding<Double>,
                                range: ClosedRange<Double>, theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title)  \(String(format: "%.2fs", value.wrappedValue))")
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            Slider(value: value, in: range).controlSize(.mini).frame(width: 130)
        }
    }
}

// MARK: - Power

/// The battery-saver page doubles as the app's honesty page: it shows exactly
/// what is scheduled right now, so a user chasing battery drain can verify the
/// claim rather than take it on faith.
struct PowerSettings: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @State private var diagnostics: (active: Bool, entries: [(label: String, interval: TimeInterval)], effectiveTick: TimeInterval) = (false, [], 0)
    @State private var refreshTick = 0

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Battery saver")
        HStack {
            Toggle("", isOn: $settings.data.batterySaver)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .onChange(of: settings.data.batterySaver) {
                    NotchPanelController.shared.settingsChanged()
                    refresh()
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Don't poll while the panel is closed")
                    .font(.system(size: 11)).foregroundStyle(theme.primaryText)
                Text("On: every widget timer is stopped when you're not looking at the panel. Off: stats keep updating while collapsed.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }

        HStack {
            Toggle("", isOn: $settings.data.pinnedCountsAsAttended)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .onChange(of: settings.data.pinnedCountsAsAttended) {
                    NotchPanelController.shared.settingsChanged(); refresh()
                }
            Text("Pinning the panel counts as 'looking at it'")
                .font(.system(size: 11)).foregroundStyle(theme.primaryText)
            Spacer()
        }

        HStack {
            Text("Stats refresh").font(.system(size: 11)).foregroundStyle(theme.primaryText)
            Slider(value: $settings.data.statsPollInterval, in: 1...10, step: 0.5)
                .controlSize(.mini).frame(width: 140)
            Text(String(format: "%.1fs", settings.data.statsPollInterval))
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.secondaryText)
            Spacer()
        }

        NBSectionHeader(title: "What's scheduled right now",
                        trailing: diagnostics.active ? "RUNNING" : "IDLE")
        NBCard(tint: .system, padding: 10) {
            VStack(alignment: .leading, spacing: 5) {
                if diagnostics.entries.isEmpty {
                    Text("Nothing registered. The app has no scheduled work at all.")
                        .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(Array(diagnostics.entries.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Circle().fill(diagnostics.active ? Color.green : Color.gray)
                                .frame(width: 5, height: 5)
                            Text(entry.label)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Text(String(format: "%.2fs", entry.interval))
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    Divider().overlay(theme.panelStroke)
                    HStack {
                        Text("Actual wakeups")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Text(diagnostics.active
                             ? "1 timer every \(String(format: "%.2f", diagnostics.effectiveTick))s"
                             : "none")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(diagnostics.active ? theme.accent : Color.green)
                    }
                }
            }
        }
        Text("Every widget shares one timer running at the greatest common divisor of their intervals, with 25% leeway so the kernel can coalesce the wakeup. Battery, Now Playing, clipboard-change and app-usage tracking are event-driven and never appear here.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

        Button("Refresh") { refresh() }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.system), compact: true))
        .onAppear { refresh() }
    }

    private func refresh() {
        diagnostics = WidgetPollingHub.shared.diagnostics()
    }
}

// MARK: - Tabs

struct TabsSettings: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @State private var newKind: CustomTabKind = .webView
    @State private var newTitle = ""
    @State private var newURL = ""
    @State private var newPath = ""
    @State private var newTag = ""

    /// Enabled tabs in their dock order, then the hidden ones. Listing them in
    /// `TabID.allCases` order would contradict the dock the user just arranged.
    private var orderedTabs: [TabID] {
        let enabled = settings.data.enabledTabs.compactMap(TabID.init(rawValue:))
        return enabled + TabID.allCases.filter { !enabled.contains($0) }
    }

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Built-in tabs", trailing: "drag them in the dock to reorder")
        Text("These are the tabs the dock can show. To change their order, drag the icons in the dock itself — the order you see there is the order that is stored.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        FlowRow(spacing: 5) {
            ForEach(orderedTabs) { id in
                let enabled = settings.data.enabledTabs.contains(id.rawValue)
                Button {
                    if enabled {
                        // Settings must never be hideable or the user can lock
                        // themselves out of the only way back.
                        guard id != .settings else { return }
                        settings.data.enabledTabs.removeAll { $0 == id.rawValue }
                    } else {
                        settings.data.enabledTabs.append(id.rawValue)
                    }
                } label: {
                    Label(id.title, systemImage: id.symbol).font(.system(size: 10))
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(id.tint), filled: enabled, compact: true))
            }
        }

        NBSectionHeader(title: "Custom tabs")
        Text("Pick a type and configure it. NotchBuddy has no plugin runtime — a custom tab is configuration, never code, so adding one can't introduce a new security surface or a per-plugin memory cost.")
            .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

        ForEach(settings.data.customTabs) { config in
            NBCard(tint: .custom, padding: 8) {
                HStack(spacing: 7) {
                    Image(systemName: config.symbol.isEmpty ? config.kind.symbol : config.symbol)
                        .font(.system(size: 11)).foregroundStyle(theme.tint(.custom))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.title).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text("\(config.kind.displayName)\(config.url.isEmpty ? "" : " · \(config.url)")")
                            .font(.system(size: 9)).lineLimit(1).foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        settings.data.customTabs.removeAll { $0.id == config.id }
                    } label: { Image(systemName: "trash").font(.system(size: 9)) }
                    .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
                }
            }
        }

        NBCard(tint: .custom, padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Picker("", selection: $newKind) {
                        ForEach(CustomTabKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                    NBTextField(placeholder: "Tab name", text: $newTitle)
                }
                switch newKind {
                case .webView:
                    NBTextField(placeholder: "https://…", text: $newURL, monospaced: true)
                case .metric:
                    NBTextField(placeholder: "https://api.example.com/stats", text: $newURL, monospaced: true)
                    NBTextField(placeholder: "JSON path, e.g. data.today.total", text: $newPath, monospaced: true)
                case .snippetList:
                    NBTextField(placeholder: "Tag to show", text: $newTag)
                case .launcher:
                    Text("Add apps to the tab after creating it, from the tab itself.")
                        .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                }
                HStack {
                    Spacer()
                    Button("Add tab") {
                        guard !newTitle.isEmpty else { return }
                        var config = CustomTabConfig(kind: newKind, title: newTitle, symbol: newKind.symbol)
                        config.url = newURL
                        config.jsonPath = newPath
                        config.snippetTagFilter = newTag
                        settings.data.customTabs.append(config)
                        newTitle = ""; newURL = ""; newPath = ""; newTag = ""
                    }
                    .buttonStyle(NBButtonStyle(tint: theme.tint(.custom), filled: true, compact: true))
                }
            }
        }

        NBSectionHeader(title: "Home custom-metric widget")
        NBCard(tint: .custom, padding: 9) {
            VStack(alignment: .leading, spacing: 6) {
                NBTextField(placeholder: "Label", text: Binding(
                    get: { settings.data.customMetricConfig?.title ?? "" },
                    set: { updateMetric { $0.title = $1 }($0) }))
                NBTextField(placeholder: "https://api.example.com/stats", text: Binding(
                    get: { settings.data.customMetricConfig?.url ?? "" },
                    set: { updateMetric { $0.url = $1 }($0) }), monospaced: true)
                NBTextField(placeholder: "JSON path, e.g. data.today.total", text: Binding(
                    get: { settings.data.customMetricConfig?.jsonPath ?? "" },
                    set: { updateMetric { $0.jsonPath = $1 }($0) }), monospaced: true)
            }
        }
    }

    /// Small helper so the three bindings above do not each repeat the
    /// "create-if-absent then mutate" dance.
    private func updateMetric(_ mutate: @escaping (inout CustomTabConfig, String) -> Void) -> (String) -> Void {
        { newValue in
            var config = settings.data.customMetricConfig
                ?? CustomTabConfig(kind: .metric, title: "Metric", symbol: "chart.bar")
            mutate(&config, newValue)
            settings.data.customMetricConfig = config
        }
    }
}

// MARK: - AI

struct AISettings: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var watcher = SelectionWatcher.shared
    @State private var keyDraft = ""
    @State private var saved = false

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "Provider")
        Picker("", selection: $settings.data.llmProvider) {
            ForEach(LLMProvider.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .onChange(of: settings.data.llmProvider) {
            settings.data.llmModel = settings.data.llmProvider.defaultModel
            keyDraft = ""
        }

        NBTextField(placeholder: "Model", text: $settings.data.llmModel, monospaced: true)
        NBTextField(placeholder: "Endpoint override (optional)",
                    text: $settings.data.llmEndpointOverride, monospaced: true)

        if settings.data.llmProvider.needsKey {
            NBSectionHeader(title: "API key",
                            trailing: Keychain.has(settings.data.llmProvider.keychainAccount) ? "stored in Keychain" : "not set")
            HStack(spacing: 6) {
                SecureField("sk-…", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                Button(saved ? "Saved" : "Save") {
                    Keychain.set(keyDraft, for: settings.data.llmProvider.keychainAccount)
                    keyDraft = ""
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                }
                .buttonStyle(NBButtonStyle(tint: theme.tint(.ai), filled: true, compact: true))
                Button("Remove") {
                    Keychain.delete(settings.data.llmProvider.keychainAccount)
                }
                .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
            }
            Text("Stored in the macOS Keychain, marked this-device-only so it never syncs to another Mac. It is read only at the moment a request is made and is never written to a settings file.")
                .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Ollama runs locally and needs no key. Make sure `ollama serve` is running.")
                .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
        }

        NBSectionHeader(title: "Selection assist")
        HStack {
            Toggle("", isOn: $settings.data.selectionAssistEnabled)
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .onChange(of: settings.data.selectionAssistEnabled) {
                    if settings.data.selectionAssistEnabled {
                        if SelectionWatcher.hasAccessibilityPermission {
                            SelectionWatcher.shared.arm()
                        } else {
                            SelectionWatcher.requestAccessibilityPermission()
                        }
                    } else {
                        SelectionWatcher.shared.disarm()
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Explain / Rewrite / Translate on any selected text")
                    .font(.system(size: 11)).foregroundStyle(theme.primaryText)
                Text(SelectionWatcher.hasAccessibilityPermission
                     ? (watcher.isArmed ? "Armed. Listening for selection-change notifications — no polling."
                                        : "Permission granted, currently off.")
                     : "Needs Accessibility permission. Turning this on will ask for it.")
                    .font(.system(size: 9)).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        if !SelectionWatcher.hasAccessibilityPermission {
            Button("Open Accessibility settings") {
                SelectionWatcher.requestAccessibilityPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .buttonStyle(NBButtonStyle(tint: theme.tint(.ai), compact: true))
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject private var themes: ThemeManager
    @ObservedObject private var nowPlaying = NowPlayingMonitor.shared

    var body: some View {
        let theme = themes.theme
        NBSectionHeader(title: "NotchBuddy")
        Text("A native macOS notch utility. No Electron, no web view shell, no third-party packages, no account, no telemetry.")
            .font(.system(size: 11)).foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)

        NBSectionHeader(title: "What leaves this Mac")
        VStack(alignment: .leading, spacing: 4) {
            bullet("Your own LLM requests, to the provider you configured with your own key.", theme)
            bullet("Weather: a latitude/longitude rounded to ~1km, sent to open-meteo.com, only while the Home tab is open.", theme)
            bullet("Anything you explicitly send from the API Tester or a custom metric tab.", theme)
            bullet("Nothing else. No analytics, no crash reporting, no update pings.", theme)
        }

        NBSectionHeader(title: "Capabilities on this system")
        capability("Battery (IOKit power-source notifications)", ok: BatteryMonitor.shared.state.isPresent, theme)
        capability("Now Playing (MediaRemote)", ok: nowPlaying.isAvailable, theme,
                   note: nowPlaying.isAvailable ? nil
                        : "Unavailable — macOS 15.4+ restricts this to apps with a private Apple entitlement. The pill simply omits it.")
        capability("Brightness control", ok: SoundLightController.shared.brightnessAvailable, theme,
                   note: SoundLightController.shared.brightnessAvailable ? nil
                        : "No writable brightness parameter on this display.")
        capability("Docker socket", ok: DockerClient.isAvailable, theme,
                   note: DockerClient.isAvailable ? DockerClient.socketPath() : "No daemon socket found.")
        capability("Accessibility (selection assist)", ok: SelectionWatcher.hasAccessibilityPermission, theme)
        capability("Approval hook socket", ok: ApprovalHookServer.shared.isRunning, theme,
                   note: ApprovalHookServer.shared.socketURL.path)

        NBSectionHeader(title: "Data location")
        Text(AppPaths.dataDirectory.path)
            .font(.system(size: 9, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(theme.secondaryText)
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([AppPaths.dataDirectory])
        }
        .buttonStyle(NBButtonStyle(tint: theme.secondaryText, compact: true))
    }

    private func bullet(_ text: String, _ theme: Theme) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("•").foregroundStyle(theme.secondaryText)
            Text(text).font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capability(_ title: String, ok: Bool, _ theme: Theme, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 10))
                .foregroundStyle(ok ? Color.green : theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(theme.primaryText)
                if let note {
                    Text(note).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
    }
}

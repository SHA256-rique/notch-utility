import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Startup order matters here, and the ordering below is deliberate:
///
/// 1. **Accessory activation policy first.** If the app ever becomes `.regular`,
///    even briefly, a Dock icon flashes. Setting this before anything creates a
///    window avoids that.
/// 2. **Event-driven Tier-1 monitors.** Battery, app usage, clipboard. These are
///    the only things that run continuously, and each was chosen because it
///    costs nothing between events.
/// 3. **Stores.** Snippets and time state, so the panel has data the moment it
///    is first hovered.
/// 4. **The panel.** Created once and never recreated.
/// 5. **Approval hook server.** Last, because it publishes a socket other
///    processes can connect to; it should not exist before the UI that answers
///    it does.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    /// NSApplication holds its delegate weakly. Without this the delegate would
    /// be deallocated the moment main.swift's local went out of scope.
    private static var retained: AppDelegate?
    static func retain(_ delegate: AppDelegate) { retained = delegate }

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // 1. No Dock icon, no app menu. The notch and a status item are the
        //    entire presence.
        NSApp.setActivationPolicy(.accessory)

        // 2. Event-driven monitors. None of these own a repeating timer.
        BatteryMonitor.shared.start()
        NowPlayingMonitor.shared.start()
        AppUsageTracker.shared.start()
        ClipboardWatcher.shared.start()

        // 3. Persisted state.
        SnippetStore.shared.start()
        ChatStore.shared.start()
        TaskBoard.shared.start()
        TimeEngine.shared.start()
        WaterTracker.shared.start()

        // 4. The panel.
        NotchPanelController.shared.start()
        installStatusItem()
        refreshHotKey()

        // 5. Approval transports.
        ApprovalHookServer.shared.start()

        // Benchmark hook. `NOTCHSCOTCH_BENCH_TAB=terminal open -a …` launches
        // straight into one tab in the standalone window, which is what lets
        // Scripts/bench-tabs.sh measure a tab's real cost without a human
        // clicking through thirteen of them.
        //
        // Env var rather than a launch argument: `open` does not forward
        // arguments to an already-running instance, and an env var is trivially
        // absent in normal use -- there is no code path here that a user can
        // reach by accident.
        if let requested = ProcessInfo.processInfo.environment["NOTCHSCOTCH_BENCH_TAB"] {
            openBenchmarkTab(named: requested)
        }
        if Settings.shared.data.selectionAssistEnabled,
           SelectionWatcher.hasAccessibilityPermission {
            SelectionWatcher.shared.arm()
        }

        // Keep the teleprompter's capture setting in step with the general one.
        TeleprompterController.shared.hideFromCapture = Settings.shared.data.hideFromScreenRecordingTeleprompter

        // Reconcile the login-item switch with reality. The user can turn it off
        // in System Settings without telling us, and a toggle that lies is worse
        // than no toggle.
        Settings.shared.data.launchAtLogin = LaunchAtLogin.isEnabled

        applyBenchmarkLaunchArguments()

        Log.panel.info("NotchScotch launched")
    }

    /// `--bench-tab <id>` opens and pins a tab at launch.
    ///
    /// This exists so the expanded-state figures in docs/BENCHMARKS.md are
    /// reproducible from a script rather than depending on someone hovering the
    /// notch at the right moment. Benchmarks that cannot be re-run are just
    /// claims, and the whole point of publishing them is that a reader can
    /// check them.
    ///
    /// It changes nothing about normal launches -- with no argument, nothing
    /// here runs.
    private func applyBenchmarkLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--bench-tab"),
              index + 1 < arguments.count,
              let tab = TabID(rawValue: arguments[index + 1]) else { return }
        Log.panel.info("benchmark mode: pinning \(tab.rawValue, privacy: .public)")
        NotchPanelController.shared.togglePin()
        NotchPanelController.shared.expand(selecting: .builtin(tab))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Every debounced store gets a hard flush: a pending 1.5s write must not
        // be lost because the user quit 200ms after typing.
        Settings.shared.flush()
        SnippetStore.shared.flush()
        ChatStore.shared.flush()
        TaskBoard.shared.flush()
        TimeEngine.shared.flush()
        WaterTracker.shared.flush()
        DailyWordService.shared.flush()
        NotesStore.shared.flush()
        AppUsageTracker.shared.flush()

        ApprovalHookServer.shared.stop()
        SelectionWatcher.shared.disarm()
        TerminalSession.shared.forceStop()
        HotKeyCenter.shared.unregister()
    }

    /// Accessory apps get no "reopen" for free; this makes clicking the app in
    /// Finder bring the panel forward instead of appearing to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotchPanelController.shared.forceExpandFromHotKey()
        return true
    }

    // MARK: - Hotkey

    func refreshHotKey() {
        let settings = Settings.shared.data
        guard settings.globalHotKeyEnabled else {
            HotKeyCenter.shared.unregister()
            return
        }
        HotKeyCenter.shared.register(keyCode: settings.globalHotKeyCode,
                                     modifiers: settings.globalHotKeyModifiers) {
            NotchPanelController.shared.forceExpandFromHotKey()
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "NotchScotch")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()

        let open = NSMenuItem(title: "Open NotchScotch", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let windowItem = NSMenuItem(title: "Open in a Window",
                                    action: #selector(openStandaloneWindow), keyEquivalent: "w")
        windowItem.target = self
        menu.addItem(windowItem)
        menu.addItem(.separator())

        let teleprompter = NSMenuItem(title: "Teleprompter", action: #selector(toggleTeleprompter), keyEquivalent: "")
        teleprompter.target = self
        menu.addItem(teleprompter)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let batterySaver = NSMenuItem(title: "Battery saver", action: #selector(toggleBatterySaver), keyEquivalent: "")
        batterySaver.target = self
        batterySaver.state = Settings.shared.data.batterySaver ? .on : .off
        menu.addItem(batterySaver)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotchScotch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func openPanel() {
        NotchPanelController.shared.forceExpandFromHotKey()
    }

    @objc private func openSettings() {
        NotchPanelController.shared.isPinnedForSettings()
    }

    /// Opens a named tab for benchmarking. Unknown names are ignored rather
    /// than defaulted, so a typo in a bench script shows up as "nothing opened"
    /// instead of silently measuring Home thirteen times.
    private func openBenchmarkTab(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "collapsed" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let id = TabID(rawValue: trimmed) {
                StandaloneWindowController.shared.open(selecting: .builtin(id))
                // Lets the bench (and a bug report) open straight into a split.
                if id == .terminal,
                   let name = ProcessInfo.processInfo.environment["NOTCHSCOTCH_BENCH_LAYOUT"],
                   let layout = TerminalWorkspace.Layout(rawValue: name) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        TerminalWorkspace.shared.setLayout(layout)
                    }
                }
            } else if let detail = DetailTab(rawValue: trimmed) {
                NotchPanelController.shared.openDetail(detail)
                StandaloneWindowController.shared.open()
            } else {
                Log.panel.error("bench tab \(trimmed, privacy: .public) not recognised")
            }
        }
    }

    @objc private func openStandaloneWindow() {
        StandaloneWindowController.shared.open(selecting: NotchPanelController.shared.activeTab)
    }

    @objc private func toggleTeleprompter() {
        TeleprompterController.shared.isOpen
            ? TeleprompterController.shared.close()
            : TeleprompterController.shared.open()
    }

    @objc private func toggleBatterySaver(_ sender: NSMenuItem) {
        Settings.shared.data.batterySaver.toggle()
        sender.state = Settings.shared.data.batterySaver ? .on : .off
        NotchPanelController.shared.settingsChanged()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension NotchPanelController {
    /// Used by the status-bar menu: pin open on the Settings tab, since a
    /// menu-driven open should not evaporate when the cursor moves away.
    func isPinnedForSettings() {
        if !isPinned { togglePin() }
        expand(selecting: .builtin(.settings))
    }
}

import AppKit
import ApplicationServices
import Combine

/// Selection-aware Explain / Rewrite / Translate.
///
/// Explicitly **not a tab**, per the brief. It is a global affordance that
/// appears near the user's selection in whatever app they are in, and it shares
/// only the LLM plumbing with the AI Chat tab -- different trigger, different
/// lifetime, different surface.
///
/// ## Event-driven, not polled
/// The naive implementation polls `AXUIElementCopyAttributeValue(...,
/// kAXSelectedTextAttribute)` on a timer. That is an expensive synchronous IPC
/// call into another process, several times a second, forever. On a heavy app
/// (an IDE, a browser with many tabs) it is measurably costly to *both*
/// processes, and it is the single most common reason apps in this category get
/// accused of making the machine feel sluggish.
///
/// Instead we register an `AXObserver` for `kAXSelectedTextChangedNotification`
/// on the focused app only, and re-point it when the frontmost app changes
/// (which is itself an NSWorkspace notification, not a poll). Between selections
/// the cost is zero.
///
/// ## Permission posture
/// This is the one feature that needs Accessibility access, and it is **off by
/// default**. Nothing arms the observer until the user turns it on in Settings,
/// at which point the prompt appears with obvious cause and effect. An app that
/// demands Accessibility at first launch teaches users to distrust it.
@MainActor
final class SelectionWatcher: ObservableObject {
    static let shared = SelectionWatcher()

    @Published private(set) var isArmed = false
    @Published private(set) var lastSelection = ""

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var workspaceToken: NSObjectProtocol?
    private var actionWindow: SelectionActionWindow?

    private init() {}

    // MARK: - Permission

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt. There is no programmatic grant -- this opens the
    /// dialog that sends the user to System Settings.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    func arm() {
        guard !isArmed else { return }
        guard Self.hasAccessibilityPermission else {
            Log.tier1.notice("selection assist requested without Accessibility permission")
            return
        }
        isArmed = true

        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.observe(pid: app?.processIdentifier ?? 0) }
        }
        observe(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        Log.tier1.info("selection watcher armed (AX notifications, 0 timers)")
    }

    func disarm() {
        isArmed = false
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
        }
        workspaceToken = nil
        detachObserver()
        dismissAction()
    }

    // MARK: - AX observation

    private func observe(pid: pid_t) {
        guard pid != 0, pid != observedPID, pid != ProcessInfo.processInfo.processIdentifier else { return }
        detachObserver()

        var newObserver: AXObserver?
        // The callback is a bare C function pointer; `refcon` carries an
        // unretained self, which is safe because we destroy the observer before
        // this singleton could ever go away.
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<SelectionWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { watcher.selectionChanged() }
        }
        guard AXObserverCreate(pid, callback, &newObserver) == .success,
              let newObserver else { return }

        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Not every app implements this notification. A failure here is normal
        // and simply means selection assist does not work in that app.
        let result = AXObserverAddNotification(newObserver,
                                               element,
                                               kAXSelectedTextChangedNotification as CFString,
                                               refcon)
        guard result == .success else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(newObserver),
                           .defaultMode)
        observer = newObserver
        observedPID = pid
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    private func selectionChanged() {
        guard isArmed else { return }
        guard let (text, bounds) = currentSelection() else {
            dismissAction()
            return
        }
        // Ignore trivial selections -- a single click often reports a one- or
        // two-character selection, and popping a menu for that is maddening.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else {
            dismissAction()
            return
        }
        lastSelection = trimmed
        showAction(for: trimmed, near: bounds)
    }

    /// Reads the selected text and its on-screen rect from the focused element.
    private func currentSelection() -> (String, CGRect)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let axElement = element as! AXUIElement

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return nil }

        // Bounds come from the selected *range*, which is what lets the
        // affordance appear next to the selection rather than next to the window.
        var rangeValue: CFTypeRef?
        var rect = CGRect.zero
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let range = rangeValue {
            var boundsValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                axElement,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                range, &boundsValue) == .success,
               let bounds = boundsValue {
                AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
            }
        }
        return (text, rect)
    }

    // MARK: - The floating affordance

    private func showAction(for text: String, near bounds: CGRect) {
        if actionWindow == nil { actionWindow = SelectionActionWindow() }
        actionWindow?.present(text: text, near: bounds)
    }

    func dismissAction() {
        actionWindow?.dismiss()
    }
}

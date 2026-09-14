import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon's `RegisterEventHotKey`.
///
/// Why Carbon, in 2026, for new code:
///   * It is the only global-hotkey API that does **not** require Accessibility
///     permission. `NSEvent.addGlobalMonitorForEvents` and `CGEventTap` both do.
///     Demanding Accessibility access at first launch just to bind cmd-opt-space
///     is a terrible first impression for an app whose pitch is "I respect your
///     machine", and most users who decline never come back to grant it.
///   * The hotkey is registered with the window server, so it fires even when
///     another app is full-screen and focused, which a local event monitor
///     cannot do.
///   * It is deprecated-adjacent but has no replacement and still works; Apple's
///     own apps and every major hotkey library still use it.
///
/// The cost is C interop: the callback is a bare C function pointer and cannot
/// capture context, so the dispatch table lives in a file-private singleton.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// cmd + option, as Carbon modifier bits.
    static var defaultModifiers: UInt32 { UInt32(cmdKey | optionKey) }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    private let signature: OSType = 0x4E424B59 // 'NBKY'

    private init() {}

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // Install the handler once per registration. The callback trampolines
        // straight back into the singleton because a C function pointer has no
        // closure context to carry `self`.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            DispatchQueue.main.async { HotKeyCenter.shared.fire() }
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // The overwhelmingly common cause is another app already owning the
            // combination. Surface it rather than failing silently.
            Log.panel.error("hotkey registration failed (\(status)) -- combination likely taken by another app")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        action = nil
    }

    fileprivate func fire() { action?() }

    /// Human-readable rendering of a Carbon keycode + modifier mask, for the
    /// Settings UI.
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { parts += "⌘" }
        return parts + (keyName(keyCode) ?? "?")
    }

    static func keyName(_ code: UInt32) -> String? {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        default: return nil
        }
    }

    /// Offered in Settings as a short list rather than a full key recorder:
    /// a recorder needs an event tap, which needs Accessibility -- the exact
    /// permission this whole approach exists to avoid.
    static let choices: [(label: String, code: UInt32)] = [
        ("Space", UInt32(kVK_Space)),
        ("N", UInt32(kVK_ANSI_N)),
        ("B", UInt32(kVK_ANSI_B)),
        ("J", UInt32(kVK_ANSI_J)),
        ("K", UInt32(kVK_ANSI_K)),
        ("F1", UInt32(kVK_F1)),
        ("F2", UInt32(kVK_F2))
    ]
}

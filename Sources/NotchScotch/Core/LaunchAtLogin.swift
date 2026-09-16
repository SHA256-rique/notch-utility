import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` (macOS 13+).
///
/// The older approaches are all worse now:
///   * `LSSharedFileListInsertItemURL` -- deprecated and non-functional since
///     Mojave's TCC changes.
///   * A separate login-item helper app embedded in the bundle -- an entire
///     extra target, extra signing, extra ~2MB, and it still shows up in the
///     user's login items as a confusingly-named helper.
/// `SMAppService.mainApp` registers the app itself and appears in System
/// Settings > General > Login Items under the app's own name, which is exactly
/// what a user expects to see when they go looking to turn it off.
///
/// Caveat worth knowing: it only works from a bundle in a stable location and
/// only for a signed app. Running the raw SwiftPM binary during development will
/// throw; that is expected and handled, not a bug.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            Log.panel.error("launch-at-login toggle failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

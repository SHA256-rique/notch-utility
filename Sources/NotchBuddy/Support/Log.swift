import Foundation
import os

/// Unified-logging wrapper.
///
/// `os.Logger` is used rather than `print` because os_log is lazy: the string
/// interpolation is not evaluated at all unless someone is actually collecting
/// logs. `print` on a hot path (the polling hub ticks, the VT parser) would cost
/// real CPU in the exact place this app is trying not to spend any.
enum Log {
    static let panel   = Logger(subsystem: "com.notchbuddy.app", category: "panel")
    static let hub     = Logger(subsystem: "com.notchbuddy.app", category: "pollinghub")
    static let tier1   = Logger(subsystem: "com.notchbuddy.app", category: "tier1")
    static let tabs    = Logger(subsystem: "com.notchbuddy.app", category: "tabs")
    static let approval = Logger(subsystem: "com.notchbuddy.app", category: "approval")
    static let term    = Logger(subsystem: "com.notchbuddy.app", category: "terminal")
    static let llm     = Logger(subsystem: "com.notchbuddy.app", category: "llm")
    static let store   = Logger(subsystem: "com.notchbuddy.app", category: "store")
}

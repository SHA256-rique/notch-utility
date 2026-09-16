import AppKit

// A hand-rolled entry point rather than `@main` + SwiftUI's `App` protocol.
//
// SwiftUI's App lifecycle wants to own window creation, and the central object
// in this app is a single `NSPanel` with a borderless, non-activating style,
// a status-bar level and a custom collection behaviour. Expressing that through
// `WindowGroup`/`Settings` scenes means fighting the framework at every step --
// and `MenuBarExtra`, the nearest SwiftUI equivalent, cannot produce a panel
// positioned under the notch.
//
// AppKit owns the lifecycle; SwiftUI owns everything inside the panel's content
// view. That split is the one that costs the least.
// Top-level code in main.swift is nonisolated, but AppDelegate is @MainActor.
// We are provably on the main thread here -- this is the process entry point --
// so assumeIsolated states that fact rather than hopping through an async task,
// which would let the run loop start before the delegate was installed.
let application = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    // NSApplication does not retain its delegate, and the local would otherwise
    // be the only strong reference.
    AppDelegate.retain(delegate)
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
}
application.run()

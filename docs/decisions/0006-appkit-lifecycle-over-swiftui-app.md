# 0006 — AppKit lifecycle, SwiftUI content

**Status:** Accepted · **Date:** 2026-09-15

## Context

Modern SwiftUI offers `@main struct App: SwiftUI.App` with `WindowGroup`,
`Settings` and `MenuBarExtra` scenes. It is the documented path and it removes
a lot of boilerplate.

## Decision

A hand-written `main.swift` that creates `NSApplication`, installs an
`NSApplicationDelegate` and calls `run()`. SwiftUI is used exclusively for view
content inside `NSHostingView`.

## Why

**The central object is a window SwiftUI cannot describe.** The notch surface is
an `NSPanel` with `[.borderless, .nonactivatingPanel]`, `level = .statusBar`,
`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`,
`isMovable = false`, `animationBehavior = .none`, a clear background and a
runtime-toggled `sharingType`. `WindowGroup` exposes almost none of that.

**`MenuBarExtra` is the closest SwiftUI equivalent and is the wrong shape.** It
produces a popover anchored to a status item. It cannot be positioned under the
notch, cannot be a non-activating panel, and cannot be resized to a specific
frame on a state change.

**Startup ordering matters here and needs to be explicit.** Activation policy
must be `.accessory` before any window exists or a Dock icon flashes. The
approval socket must be published *after* the UI that answers it exists.
`applicationDidFinishLaunching` is a sequence of statements you can read;
declarative scenes are not.

**Non-activating focus needs manual control.** Clicking the pill must not steal
focus from the user's editor — but the Terminal and AI Chat tabs need real
keystrokes. That is `canBecomeKey` returning a stored property flipped on tab
open, which has no declarative equivalent.

**There are four other windows** with unrelated lifetimes: teleprompter, flash
banner, selection popover, plus the status item. Each is created imperatively
when first needed.

## Costs we accepted

- Boilerplate: delegate, retain cycle management, manual `NSStatusItem`.
- `NSApplication` holds its delegate **weakly**, so it must be retained
  explicitly — the local in `main.swift` is otherwise the only strong reference
  and the delegate dies immediately. This is a real trap and is commented at the
  site.
- `main.swift` top-level code is nonisolated while `AppDelegate` is
  `@MainActor`, so entry goes through `MainActor.assumeIsolated` — correct,
  because this *is* the main thread, and better than an async hop that would let
  the run loop start before the delegate was installed.
- No `@Environment(\.openWindow)`, no `Settings` scene, no automatic state
  restoration.

## Revisit if

SwiftUI gains real control over window style masks, levels and collection
behaviour. Not on the horizon.

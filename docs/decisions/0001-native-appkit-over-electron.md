# 0001 — Native Swift/AppKit over Electron or a web view

**Status:** Accepted · **Date:** 2026-09-15

## Context

Every app in this category — NotchNook, Boring Notch, Notchy, Perch, NotchDrop,
AgentNotch, TickerNotch — attracts the same first-week comment thread: *how much
CPU does this use at idle, and will it kill my battery?* Users have learned to
ask before installing.

A cross-platform shell (Electron, Tauri) would have made several features
substantially easier: the web view for pinned pages, the chat UI, charts,
theming, and the flash-message animations are all things the web platform does
well and AppKit does not.

## Decision

Native Swift with AppKit for the window layer and SwiftUI for content. No
Electron, no Tauri, no embedded web runtime as the app shell.

## Why

**The resource floor is the product.** An Electron app idles at 150–300 MB
before it does anything, because that is what a Chromium content process plus a
Node main process costs. NotchScotch's measured collapsed footprint is
[13.6 MB](../BENCHMARKS.md). That is not a 2× difference; it is an order of
magnitude, and it is structural — no amount of optimisation inside an Electron
app closes it.

**The wakeup floor is worse than the memory floor.** A Chromium renderer has its
own timers, its own compositor, its own garbage collector. An app whose entire
thesis is "approximately zero scheduled work while collapsed" cannot be built on
a runtime that schedules work on its own behalf.

**Half the features need native APIs anyway.** IOKit power-source notifications,
`host_statistics64`, CoreAudio device listeners, the Accessibility API,
`posix_spawn` onto a pty, `NSWindow.sharingType`, Carbon hotkeys, Keychain.
Every one of those would need a native module, at which point the cross-platform
framework is providing a UI toolkit and a large liability, not portability.

**There is no second platform.** This app is about a piece of MacBook hardware.
Portability has no value here.

## Costs we accepted

- More code. The VT100 emulator, the flow layout, the chunked-HTTP decoder and
  the JSON store are all things a web stack would have supplied.
- A smaller contributor pool.
- `WKWebView` is still used for the *pinned web page* custom tab — but as a
  leaf component with an explicit teardown, not as the app shell. The
  distinction is the whole point: one page's content process, created on tab
  open and destroyed on tab close, versus a permanently resident runtime.

## Revisit if

Never, for this app. If a genuine second platform appeared the correct response
would be a separate native app sharing a Swift core, not a rewrite onto a web
shell.

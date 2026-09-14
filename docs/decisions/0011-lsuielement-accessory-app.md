# 0011 — Accessory app: no Dock icon, with a status-item fallback

**Status:** Accepted · **Date:** 2026-09-15

## Context

The app's primary surface is the notch. It has no document model, no main
window, and no menu bar of its own worth showing.

## Decision

`LSUIElement = true` in Info.plist and `NSApp.setActivationPolicy(.accessory)`
as the first statement in `applicationDidFinishLaunching`, plus an
`NSStatusItem` with Open / Teleprompter / Settings / Battery saver / Quit.

## Why

**A Dock icon would be a lie.** Clicking it does nothing meaningful — there is
no window to raise, only a panel that appears on hover. A Dock icon promises a
window.

**No menu bar to take over.** An accessory app never becomes the active app in
the menu-bar sense, so the user's menu bar keeps belonging to whatever they are
actually working in. For an app that sits on top of everything, that is the
correct relationship.

**Non-activating panels need this.** The panel is `.nonactivatingPanel` so
clicking the pill does not steal focus from the user's editor. That behaviour is
coherent with an accessory app and incoherent with a regular one.

## The status item is not optional

An app with no Dock icon and no window needs a discoverable way back. The status
item is how a user finds Settings when they have forgotten the hotkey, and how
they quit. Shipping without it would make the app feel unremovable — which is
how utilities earn a bad reputation.

`applicationShouldHandleReopen` is also implemented, so double-clicking the app
in Finder expands the panel rather than appearing to do nothing.

## Costs

- Ordering matters: the activation policy must be set **before** any window
  exists, or a Dock icon flashes at launch. It is the first statement in the
  delegate and is commented as such.
- `NSOpenPanel` from a non-activating accessory app opens behind everything
  unless the app explicitly activates first. Every call site does
  `NSApp.activate(ignoringOtherApps: true)`.
- No standard Cmd-Q / Cmd-, unless we wire them, which the status-item menu does.

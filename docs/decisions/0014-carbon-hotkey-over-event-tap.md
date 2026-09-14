# 0014 — Carbon `RegisterEventHotKey` over `CGEventTap` or a global monitor

**Status:** Accepted · **Date:** 2026-09-15

## Context

The app needs one global hotkey (default ⌘⌥Space) to force-expand the panel.
Three APIs exist:

1. `NSEvent.addGlobalMonitorForEvents`
2. `CGEventTap`
3. Carbon's `RegisterEventHotKey` — API from 2001, in a framework Apple has been
   quietly deprecating for two decades

## Decision

Carbon.

## Why

**It is the only one that does not require Accessibility permission.** Both
`NSEvent.addGlobalMonitorForEvents` and `CGEventTap` require the app to be in
the Accessibility trust list. Demanding the most invasive permission macOS
offers, at first launch, in order to bind a keyboard shortcut, is a terrible
first impression — especially for an app whose entire pitch is *"I respect your
machine"*. Most users who decline a permission prompt never return to grant it.

This app *does* have a feature that needs Accessibility (selection assist). It
is off by default, precisely so the prompt appears with obvious cause and
effect. Spending that permission on a hotkey would poison the well.

**It is registered with the window server.** The hotkey fires when another app
is focused and full-screen. A local event monitor cannot do that, and an event
tap can be silently disabled by the system under load.

**An event tap sees every keystroke.** For a hotkey, that is a wildly
disproportionate capability to hold — and a much worse thing to have to explain
to a security-conscious user than "we registered one key combination".

**It still works.** Deprecated-adjacent, but it has no replacement, and Apple's
own apps plus every major hotkey library still use it.

## Costs we accepted

- **C interop.** The callback is a bare function pointer with no closure
  context, so it trampolines through a file-private singleton.
- **Carbon could be removed** from a future macOS. There is no migration path
  that does not require Accessibility, so that would be a forced trade at the
  time, not one we can pre-empt.
- **No key recorder.** Settings offers a short list of key choices rather than
  "press your shortcut", because a recorder needs an event tap — the exact
  permission this decision exists to avoid. A worse UI, chosen deliberately.
- **Registration can fail** if another app owns the combination. We log it
  clearly rather than failing silently, since that is by far the most common
  cause.

## Revisit if

Apple removes Carbon, or ships a modern global-hotkey API that does not require
Accessibility. The second would be a straight improvement.

# 0028 — A window mode, as a second window

**Status:** Accepted · **Date:** 2026-09-16

## Context

The notch panel is transient by design: it opens on hover, collapses when the
pointer leaves, and is sized for a glance. That is exactly right for checking a
timer, a battery level or what is playing.

It is wrong for what the app grew into. Reading a 40-row disk map, working in a
four-way terminal split, or writing a teleprompter script are *tasks*. A task
needs a surface that does not close because you looked at something else, that
can be resized to the work, and that can go full screen.

## Decision

A second window — `StandaloneWindowController` — hosting the **same**
`ExpandedPanelView`. Ordinary title bar, resizable, `fullScreenPrimary` so the
green button full-screens rather than zooms, and no auto-collapse.

`ExpandedPanelView` gains a `Chrome` parameter with two cases. It governs three
things and nothing else:

- **No notch gap.** The header reserves a hole for the camera housing
  ([ADR 0023](0023-lay-out-around-the-notch.md)); a window has no cutout above
  it, so the hole would just be a hole.
- **No pin button.** A window is always pinned. The button would be a toggle
  with one position.
- **Full screen in place of collapse.** The window's own title bar owns closing.

## Why a second window rather than un-notching the panel

The panel is an `NSPanel` that is non-activating, borderless, and pinned to the
top of the screen. A normal window must not be any of those. Toggling all three
on one object produces a window that is *sometimes* a panel, and from then on
every behaviour in it — hover handling, focus, frame maths, the hub activation
rule — has to start by asking which it is today.

Two windows sharing one view tree is the smaller thing to hold in your head, and
it keeps the panel's own code free of conditionals about a mode it is not in.

## Why not two implementations of the tabs

Considered and rejected immediately. Thirteen tabs, several of which are large,
and every future change would have to be made twice or silently diverge. The
chrome is the only thing that genuinely differs, so the chrome is the only thing
parameterised.

## Costs we accepted

- The app now has three surfaces (pill/orb, panel, window) rather than two.
  Mitigated by all three reading the same state and the same view tree.
- The window is activating, so opening it takes focus from whatever the user was
  in — unlike the panel, which never does. That is correct for a window you
  opened on purpose, and it is why this is opt-in rather than the default.
- Hub activation needs an extra caller: the window is attended by definition, so
  it turns polling on, and closing it hands the decision back to the panel. One
  more place that can switch background work on, where there used to be exactly
  one ([ADR 0002](0002-central-polling-hub.md)).

## Revisit if

Users want the window to reopen at launch. That is a one-line setting plus a
persisted flag; it was left out because an app that opens a window on login is a
different kind of app from one that lives in the notch, and that should be a
deliberate choice rather than a default.

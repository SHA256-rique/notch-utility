# 0024 — An orb on displays without a notch

**Status:** Accepted · **Date:** 2026-09-16

## Context

`ScreenGeometry` synthesises a notch on displays that do not have one: a
200pt-wide rectangle at top-centre, just under the menu bar, which the collapsed
pill hangs from exactly as it would on a MacBook.

On a notchless *laptop* that is fine. On a 27" external monitor it is not. The
pill lands in the least reachable part of a very large screen, and the illusion
the whole design sells — "this is part of your hardware" — is simply false
there. There is no cutout. It is a black tab pretending.

## Decision

A `PanelPresentation` setting with three values:

- **Automatic** (default): notch where there is a physical one, orb where there
  is not.
- **Notch**: always the pill, including the synthesised one.
- **Orb**: always the circle, even on a MacBook's own display.

The orb is a 46pt circle the user drags where they want it.

## Why both explicit modes exist

Automatic is the honest reading of both cases and it is the default. The two
overrides are not hedging: someone who has learned where the pill is may want it
on every display for muscle memory, and someone who finds the notch presentation
fussy may want an orb on their laptop. Neither preference is wrong, and both are
one enum case.

## What the orb shows

The same arbitration output as the pill, compressed to what fits in a circle:
the focal claim's symbol, a progress ring when the claim has one, a count badge
when more than one thing is live.

**No text.** A 46pt circle that tries to hold "Converted 3 files" holds nothing
legibly. Text goes to the tooltip and to the toast, which hangs under the orb
using the same capsule the pill uses — a confirmation should look like a
confirmation whichever presentation the display is wearing.

## The details that took thought

**Dragging moves the window, and that needs care.** The gesture reports a
*cumulative* translation while the window moves underneath it. Applying the
total each event makes the orb accelerate away from the cursor, because the next
event measures from the new origin. Each change applies only the delta not yet
applied.

**Positions are keyed by display id, not by localized name.** Two identical
monitors share a name and would fight over one stored position.

**The position is clamped on read, not only on write.** Undocking a monitor or
changing resolution can otherwise strand the orb off-screen with no way to get
it back short of editing the settings file. There is also a reset button.

**The collapsed window grows for a toast.** An orb has no shoulders to put a
message on, so a transient hangs below it and the window gets taller — with the
orb staying put, which means the window's bottom edge moves and its top edge
does not.

## Costs we accepted

- Two collapsed presentations to maintain, and any Tier-1 feature has to work in
  both. Contained by both reading the same `NotchArbiter` output.
- The orb is a floating window over the user's content, which the pill is not.
  It is small, it is movable, and it is the only honest option on a display with
  nothing to hang from.

## Revisit if

Someone wants several orbs, one per display. The position store is already
keyed per display; what is missing is a panel per screen, which is a larger
change to `NotchPanelController` than this decision implies.

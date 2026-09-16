# 0023 — Lay out around the camera housing, never under it

**Status:** Accepted · **Date:** 2026-09-16

## Context

The expanded panel's tab dock ran along its top edge, and the panel's top edge
is pinned to the very top of the screen so the collapsed pill can merge with the
notch. On a notched MacBook that put the middle three or four tab icons directly
behind the camera housing.

They were not dimmed. They were not clipped. They were simply not on the screen,
and nothing in the interface told the user they existed.

## What the platform actually allows

macOS reserves the housing rectangle. No application can draw into it — the
system composites the display around the cutout, and `NSScreen.safeAreaInsets`
exists precisely to tell applications where that boundary is.

Every other app in this category works the same way: neither NotchNook nor
Boring Notch renders under the housing, because none of them can. They make the
space *around* it useful. The alternative Apple offers — "Scale to fit below
built-in camera" — shrinks the whole app below the notch, which would defeat the
point of an app that lives in it.

## Decision

Three rules, applied everywhere the collapsed pill or the expanded panel touches
the top of the screen:

1. **The tab dock lives at the bottom of the panel.** Centred, magnified on
   hover like the system Dock.
2. **The header reserves a measured gap in its middle.** Title on the left
   shoulder, pin and close on the right, `notchGap` between them — computed from
   `ScreenGeometry`, not a constant, so it is right on a 14", a 16" and an
   external display alike.
3. **Transient messages are shoulder-aware.** `ScreenGeometry.shoulderWidth`
   gives the usable width either side of the cutout. A message that fits is
   rendered there. A message that does not is routed to the toast row *below*
   the notch, where the full width of the screen is available.

## Why the dock at the bottom rather than split around the gap

Splitting the dock into a left group and a right group was the obvious
alternative and it is worse in three ways: the dock is scrollable, so the split
point would move as tabs were added; a dragged tab would have to cross a gap it
cannot be dropped into; and the two halves would read as two different controls.

The bottom edge of a 470pt panel is nowhere near the notch, is where a browser
puts its tab strip when it is not at the top, and frees the top edge for the two
controls that genuinely belong beside a cutout because they are small and can
live on a shoulder.

## Why magnification is not decoration

The icons are 13pt monochrome glyphs. At that size "terminal" and "API" differ
by a few pixels. Centring the dock made it shorter and therefore denser;
magnification is what keeps a dense monochrome strip legible without making
every icon permanently large.

The falloff reads each item's real centre through a SwiftUI preference key
rather than computing it from an index, because detail tabs are text-width and
index arithmetic would be wrong the moment one opened.

## Why the overflow estimate is approximate

Deciding shoulder-versus-toast needs a width before layout has happened. A real
measurement would mean a preference key and a second render pass, for a decision
whose only failure mode is picking the toast slightly too eagerly. The estimate
is a glyph-advance approximation and deliberately generous: erring toward the
toast costs nothing, and erring the other way hides the message entirely.

## Costs we accepted

- The dock is further from the pill you clicked to open the panel. In practice
  the panel is 470pt tall and the cursor is already inside it.
- A long transient no longer uses the sweep animation even when the sweep is
  selected. Correctness wins: a sweep that ends underneath hardware is not an
  animation, it is a disappearance.

## Revisit if

Apple ever exposes a way to render into the housing region, which it will not,
or if the panel gains a mode that does not pin to the top of the screen — the
orb presentation ([ADR 0024](0024-orb-for-notchless-displays.md)) is already
that, and none of these rules apply to it.

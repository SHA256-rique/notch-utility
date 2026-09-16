# 0029 — The pill is notch-shaped, and absent when idle

**Status:** Accepted · **Date:** 2026-09-16

## Context

Feedback on the running app: *"the notch is taking more space than it should
with pointy corners and is showing pitch black on the screen."*

All three observations were correct and they compounded into one impression —
that the app was a black rectangle stuck under the hardware rather than part of
it.

## The three faults

**Square top corners.** The shape was an `UnevenRoundedRectangle` with square
top corners and rounded bottom ones, which is the naive reading of "hangs from
the notch". Drawn, it put two hard 90° angles against the top of the screen. The
physical cutout has no such corner: the black region curves *outward* into the
menu bar.

**Pitch black.** `Color.black` is darker than the notch beside it on any display
that is not perfectly calibrated. Rendering the pill blacker than the hardware
is what made it read as a separate object.

**Always visible.** The resting pill was as wide as the cutout plus 24pt, so
there were always two black wings either side of the camera housing. Tier 1's
stated rule is "render nothing when there is nothing to say", and this had been
quietly violating it since the first build.

## Decision

**`NotchShape`**, with a concave arc at each top corner matching the cutout's
flare and a generous convex radius at the bottom.

**The theme's panel background**, not absolute black.

**Narrower than the cutout when idle.** The drawn shape is
`notchRect.width - 12`, so at rest it is entirely behind the hardware and there
is nothing to see at all.

## The consequence that needed care

Once the pill is invisible, there is nothing to hover — and hover is how the
panel opens.

So the *window* and the *shape* stopped being the same size. The window stays
`notchWidth + 40`, which is the hover target; `CollapsedPillView.pillWidth`
draws a smaller shape inside it. This is the one place in the app where a
window is deliberately larger than what it paints, and it is commented at both
ends because the next person to touch either number will not guess why.

The flare has the same property in the other direction: a concave corner paints
*outside* the shape's own width, because it is the curve of the thing the pill
is attached to rather than of the pill. Callers must leave horizontal slack or
it clips — which looks like a rendering bug, not a shape, so there is a test
asserting the overhang.

## Alternatives considered

**Keep it visible but make it thinner.** Still a visible black object beside the
cutout, which is the thing being complained about.

**Match the notch width exactly.** Fragile: `measuredNotchWidth` derives from
the gap between the auxiliary menu-bar areas and is not always available, so an
exact match would sometimes be a pixel wide sliver of black. Undershooting by a
few points is robust against that.

**Draw nothing at all when idle.** Equivalent visually, and worse in code: the
view would have to special-case "no shape" everywhere instead of just being a
smaller shape, and the transition from idle to active would have no geometry to
animate between.

## Revisit if

`safeAreaInsets` ever reports the cutout's corner radius, at which point `flare`
could be measured rather than chosen. Today it is a constant that looks right on
the 14" and 16" panels.

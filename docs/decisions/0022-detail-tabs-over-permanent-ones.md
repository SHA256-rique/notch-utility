# 0022 — Detail tabs over permanent ones

**Status:** Accepted · **Date:** 2026-09-15

## Context

Several views deserve a full page but do not deserve a permanent place in the
tab dock: a screen-time report, a revenue breakdown, a storage report, today's
word in full.

Three designs were on the table:

1. **A `TabID` case each.** Simple, consistent with everything else, and the
   dock grows by one icon per view forever.
2. **A view pushed over its parent tab**, with a private back button. This is
   what the first implementation did for the Home tile details.
3. **Ephemeral tabs**, the way an editor handles a file you opened to look at
   once: it appears in the tab bar with a close button, and closing it is how
   you leave.

## Decision

Option 3. `ActiveTab` gains a `.detail(DetailTab)` case. Details render in the
dock after a divider, carry a label and a close button, are not draggable, and
are not persisted.

Screen Time moved from a `TabID` to a `DetailTab` as part of this.

## Why not a tab each

**A dock icon is a claim on the user's attention forever.** The dock already
holds twelve built-ins plus any custom tabs, on a 680pt panel that also has to
fit a pin button, a close button and any live persistent claims. Screen Time
is something you check when you are wondering where the day went — perhaps
weekly. Paying for that with a permanent icon, on every launch, is the wrong
trade.

The rule that fell out of this, and which is written into the type so the next
person does not have to re-derive it:

> If you would be annoyed to find it **gone** from the dock tomorrow, it is a
> `TabID`. If you would be annoyed to find it **still there** tomorrow, it is a
> `DetailTab`.

## Why not a pushed view

It worked, and it is what shipped first. Two things were wrong with it.

**It hid the way back.** The back button lived inside the tab's own content, so
it moved depending on what you were looking at, and there was no persistent
signal that you were somewhere you could leave.

**It put two navigation models in one panel.** Tabs along the top, and a
private push/pop inside Home. Two models in a surface this small is one too
many — and the dock already had the affordance the pushed view was missing.

## The details that took thought

**Not persisted.** A relaunch opens none of them. Restoring a storage report
from three days ago is clutter presented as continuity.

**One return slot, not a back stack.** Closing a detail puts you back where you
opened it from. A stack would mean closing two details in a row could land you
somewhere you have no memory of being. The slot is validated on use, because a
custom tab can be deleted while a detail sits on top of it.

**The close × fades in on hover.** Four always-visible ×s compete with the
icons beside them, in a strip where the icons are the content.

**Not draggable.** Dragging implies an arrangement worth keeping, and there is
nothing to keep it in.

**A dashed border and a text label**, where permanent tabs are solid and
icon-only. Three redundant signals saying the same thing: this one is
temporary.

## Costs we accepted

- A third case in `ActiveTab`, which every switch over it must now handle.
  Cheap, and the compiler enforces it.
- The dock can get crowded if a user opens all five details. It scrolls, and
  a right-click offers "Close all details".
- Removing `screenTime` from `TabID` orphans that string in any stored
  `enabledTabs`. No work was needed: `migrateTabDock` already drops ids that no
  longer resolve. There is now a test pinning that behaviour.

## Revisit if

Users start wanting a detail to survive a relaunch — most likely Screen Time,
if it turns out people keep it open all day. That would mean promoting it back
to a `TabID`, which is a one-line change plus a dock migration, and the rule
above is what would decide it.

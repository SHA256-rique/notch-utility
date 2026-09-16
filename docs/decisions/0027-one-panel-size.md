# 0027 — One panel size for every tab

**Status:** Accepted · **Supersedes** per-tab sizing · **Date:** 2026-09-16

## Context

Every tab used to open the panel at 680×420, which meant it was sized for none
of them: the terminal got 28 rows, the Home grid scrolled after four tiles, and
the Message composer sat in a box twice the height of its content.

So each tab was given a `preferredSize` and the window followed on every tab
switch. That shipped, and using it for a day made the problem obvious.

## The bug it caused

The panel auto-collapses when the pointer leaves it. That is the whole
interaction model — you hover the notch, it opens; you move away, it closes.

Resizing on a tab switch moves the panel's edges **out from under the cursor**.
Click a tab that wants a smaller panel and the pointer can end up outside the
new bounds, which fires the collapse, which shuts the app in the same gesture
that opened the tab.

A window that closes because you used it is not a trade-off against layout
quality. It is a bug, and no amount of better-fitting tabs pays for it.

It was also wrong in a way that is obvious in motion and invisible in a
screenshot: every click heaved the whole surface.

## Decision

One fixed size, 880×520, clamped to the screen's usable area.

Chosen for the most demanding tab rather than the average one — Disk Map's three
panels and the terminal's four-way split. Tabs with less to show have
whitespace, which costs nothing.

## Alternatives considered

**Resize only when growing.** Would fix the specific collapse, since the cursor
stays inside a panel that only gets bigger. Rejected: the panel then ratchets up
to the largest tab you have visited and never comes back, which is per-tab
sizing with worse fidelity and a hidden state.

**Suppress hover-collapse for a moment after a resize.** A timing window to
paper over a layout problem. It would also have to survive the user genuinely
moving away during that window, at which point the panel is pinned open for no
reason they can see.

**Make the panel user-resizable.** The panel is drawn chrome hanging from the
notch. A grab handle means a minimum size below which the dock stops fitting, a
persisted size per tab, and a resize affordance on a surface with no title bar.
That is a real feature, not a fix for this.

## Costs we accepted

- Home, Notes and Message have more room than they need. Whitespace is cheap;
  the alternative was measured and it closed the app.
- The panel is large on a small display. The clamp keeps it on screen, and an
  1280×800 Air gets 880×520 with room to spare.

## Revisit if

The hover-collapse model changes — a panel that only closes on an explicit
click could resize freely, because there would be no cursor-position race to
lose. That is a bigger change to the interaction than sizing is worth on its
own.

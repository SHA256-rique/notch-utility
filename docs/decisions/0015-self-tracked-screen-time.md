# 0015 — Track app usage ourselves, not Apple's Screen Time database

**Status:** Accepted · **Date:** 2026-09-15

## Context

The Home tab has a Screen Time widget: today's total, change vs average, most
used app, a 7-day chart, per-app breakdown. macOS already computes all of this
and stores it in `~/Library/Application Support/Knowledge/knowledgeC.db`.

## Decision

Track it ourselves, from `NSWorkspace.didActivateApplicationNotification`.

## Why

**`knowledgeC.db` requires Full Disk Access.** That permission cannot be
requested programmatically — the user must open System Settings and drag the app
into a list. Asking for the single most alarming permission macOS offers so that
a widget can draw a bar chart is a bad trade for an app whose pitch is
restraint. Many users would (correctly) decline, and some would uninstall on the
spot.

**The schema is private and unstable.** It is an undocumented SQLite database
whose structure has changed between releases. Parsing it is a maintenance
liability with no compatibility promise.

**The signal we need is already free.** The frontmost app changes; macOS posts a
notification. Attribute the elapsed wall time since the last switch to the app
that was frontmost. Zero permissions, zero polling.

**Our numbers are explainable.** When a user asks "why does it say 3 hours of
Safari", there is a straightforward answer. With a scraped private database
there would not be.

## Costs we accepted

- **No history before install.** Apple's data goes back weeks; ours starts when
  the app does. The 7-day chart is empty on day one.
- **Numbers will differ from Apple's**, which uses its own definitions of
  active use, idleness and background audio.
- **Front-most is not the same as "using".** Leaving Xcode frontmost while
  reading a book credits Xcode. Apple's implementation has better idle detection
  than we do.
- **Correctness depends on handling the edge cases** — which is where the real
  work went.

## The edge cases, because they are where this goes wrong

- **Sleep and screen lock.** `NSWorkspace.willSleepNotification` and the
  `com.apple.screenIsLocked` distributed notification close the open segment.
  Without this, closing the lid at 6pm and opening it at 9am credits **fifteen
  hours** to whatever was frontmost. This is the bug that makes naive
  implementations obviously wrong.
- **Midnight rollover.** A segment spanning midnight is split at midnight, so
  neither day is over-credited.
- **Our own app is excluded.** It is an accessory app; counting it is noise.
- **Sub-second flickers are ignored**, so alt-tabbing through five apps does not
  create five rows.
- **30-day retention.** Beyond that the file grows without anyone looking at it,
  which is exactly the quiet cost this app is meant to avoid.

## Revisit if

Apple ships a public Screen Time read API. `DeviceActivity` exists on iOS and
has no macOS equivalent with this shape.

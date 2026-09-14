# 0009 — Debounced JSON files over Core Data or SQLite

**Status:** Accepted · **Date:** 2026-09-15

## Context

Seven domains persist state: settings, snippets, timers/alarms, notes, screen
time, saved API requests, teleprompter script.

The reflexive answer for structured local data on Apple platforms is Core Data
or SwiftData; the reflexive answer for anything else is SQLite.

## Decision

`JSONStore<T>` — one `Codable` JSON file per domain, debounced, written
atomically off the main thread.

## Why

**The data is tiny.** The largest collection is clipboard history, capped at a
few hundred entries. That is kilobytes. A database engine's connection, page
cache and background threads cost more RAM than the data does — in an app whose
whole argument is a 13.6 MB footprint.

**Core Data is resident for the process lifetime.** `NSPersistentContainer` plus
a managed object context stay in memory whether or not anyone has opened the tab
that reads them. That is the opposite of this app's lifecycle model, where
everything is supposed to be released when its tab closes.

**Access patterns are trivial.** Load everything on start, filter in memory,
write the whole thing back. There are no joins, no migrations across
relationships, no partial fetches, no concurrent writers. SQL would be answering
a question nobody asked.

**The files are readable.** A user can `cat ~/Library/Application
Support/NotchBuddy/settings.json` and see exactly what the app stores. For an
app that reads your clipboard and holds API keys, that transparency is worth
something — and Settings → About links straight to the folder.

## Costs we accepted

- **Whole-file rewrite on change.** Debouncing (0.4–5s per domain) coalesces
  bursts, so typing in the notes tab is one write rather than one per keystroke.
  At these sizes the cost is irrelevant.
- **No partial load.** Everything in a file is in memory while that store is
  alive. Bounded by the retention caps: 200 clipboard entries, 30 days of usage,
  30 saved requests.
- **No schema migration story.** Mitigated by `Codable` with defaults on every
  field, so a file written by an older build decodes into a newer struct. A
  field that is *removed* is silently dropped, which is acceptable here.
- **No transactions.** Single-writer, and `.atomic` writes mean a crash
  mid-write cannot truncate a file.

## The detail that matters most

`applicationWillTerminate` calls `saveNow` on every store. Without it, a pending
1.5-second debounced write is lost when the user quits 200ms after typing — and
"my note disappeared" is a far worse bug than any amount of write amplification.

## Revisit if

Any collection grows past ~10k rows, or full-text search over history becomes a
feature. SQLite with FTS5 would then be right. The `JSONStore<T>` interface is
narrow enough (`load`/`save`/`saveNow`) that swapping the implementation is
contained.

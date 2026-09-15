# 0021 — Embedded word packs, and a derived word of the day

**Status:** Accepted · **Date:** 2026-09-15

## Context

The word-of-the-day feature shows one new word per day, in one or more
user-chosen languages, with a meaning and an example sentence.

Two obvious designs: fetch from a dictionary API, and pick a random word each
midnight and store it.

## Decision

Curated word packs compiled into the binary, and a word that is a pure function
of `(day, language)`.

## Why not an API

A word a day is the definition of a feature that must work on a plane. An
API-backed version needs a key, a network round trip, a cache, an offline
fallback and a privacy story — to deliver about twelve kilobytes of text per
language that never changes. Embedding the text costs the binary less than one
app icon.

It also keeps Settings → About true: the list of things that leave this Mac
stays at two.

## Why the selection is derived, not stored

The obvious design — pick a random word at midnight and write it to disk —
needs a timer that fires at midnight, survives sleep, survives the clock
changing, and survives the app not running that day. That is four ways to show
the wrong word, or no word.

`index = (dayNumber + languageOffset) % packCount` has none of them. There is no
scheduled work at all, the answer is identical whether you open the app at 00:01
or 23:59, and a day the app never ran simply passes. The only state on disk is
what the user *did* — which words they marked as learned.

Two details this depends on:

- **`dayNumber` counts days in the user's own calendar**, not
  `timeIntervalSince1970 / 86400`. Otherwise the card flips at UTC midnight,
  which is mid-afternoon for anyone west of Greenwich.
- **The per-language offset is a hand-rolled hash, not `hashValue`.** Swift
  seeds string hashing per process, so `hashValue` would change the word of the
  day on every relaunch — the one thing this feature must not do. There is a
  test for it.

The offset exists so that two enabled languages do not march in lockstep through
position 1, position 2, position 3 of their packs, which looks mechanical the
moment you notice it.

## Costs we accepted

- Thirty words per language is about a month before a repeat. That is enough to
  find out whether the habit sticks, and extending a pack is an append to an
  array.
- The packs are curated by hand, so they carry our judgement about which words
  are worth knowing. Stated plainly rather than pretended away: they lean
  towards words a working person would actually use, ordered by rough
  usefulness rather than alphabetically, so someone who sticks with it for two
  weeks still learns something useful.
- Adding a language means writing thirty entries, not flipping a flag.

## Revisit if

Users want a much larger vocabulary, or spaced repetition over words they marked
as learned. The pack format already carries everything spaced repetition would
need; the selection function would become a scheduler, and that is the point at
which storing state starts to earn its complexity.

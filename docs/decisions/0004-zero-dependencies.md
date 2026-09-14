# 0004 — Zero third-party dependencies

**Status:** Accepted · **Date:** 2026-09-15

## Context

Several parts of this app have obvious, good packages available: SwiftTerm for
the terminal, a Keychain wrapper, a hotkey library (HotKey, KeyboardShortcuts),
a charts library, an HTTP client with unix-socket support.

## Decision

`Package.swift` has no `dependencies` array. Nothing is vendored either.

The bar for adding one is *"we cannot reasonably hand-roll it"*. Nothing has
cleared that bar yet — including the terminal emulator, which is ~600 lines.

## Why

**Every dependency is a permanent addition to the RAM floor.** Not the download
size — the resident cost. A library that allocates caches, starts a queue, or
registers observers at init does so for the whole process lifetime, in an app
that is trying to cost nothing while idle.

**Audit surface.** This app runs a shell, reads your clipboard, talks to a
Docker socket, holds API keys in the Keychain, and answers "may this agent run
this command". Every line of third-party code in that process is code a user
would have to trust without reading. Keeping the count at zero means the honest
answer to "what else is in there" is "nothing".

**Most candidates were oversized for the use.** SwiftTerm implements a full
xterm feature set — sixel, mouse reporting, selection, its own NSView renderer
that would need bridging into SwiftUI anyway. We need SGR, cursor movement,
erase, scroll regions and the alternate screen, in a 680pt panel. A hotkey
library is a wrapper around ~60 lines of Carbon. A Keychain wrapper is a wrapper
around four `SecItem` calls.

**Supply-chain risk is real and asymmetric.** A compromised transitive
dependency in *this* process would be unusually valuable to an attacker.

**It also happened to be practical.** The build machine has Command Line Tools
only. A dependency-free package builds with `swift build` and nothing else.

## Costs we accepted

These are real and should be weighed honestly:

- **The terminal emulator is incomplete**, and openly says so in its header. No
  sixel, no mouse reporting, no double-width lines. `vim` renders but imperfectly.
  SwiftTerm would have handled all of it.
- **We own the bugs.** The two bugs the test suite caught were both in code a
  library would have supplied correctly (see
  [learning/05](../learning/05-bugs-the-tests-caught.md)).
- **More code to maintain**, and no upstream fixing it when macOS changes.
- **Charts are hand-drawn**, so they are simpler than Swift Charts would be.

## What this is *not*

It is not a claim that dependencies are bad. It is a claim that for *this* app —
where idle cost is the product and the process holds unusual privileges — the
trade came out on the side of writing it.

## Revisit if

A feature needs something genuinely hard and well-solved: a real PDF renderer, a
cryptography primitive, a full-fidelity terminal. Those clear the bar. A
convenience wrapper never will.

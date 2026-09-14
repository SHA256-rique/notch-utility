# 0008 — A hand-rolled VT100 emulator instead of SwiftTerm

**Status:** Accepted · **Date:** 2026-09-15

## Context

The Terminal tab needs a real interactive shell, which means a pty *and* a
terminal emulator: something that consumes the byte stream, interprets escape
sequences, maintains a screen model, and renders it.

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) is the obvious answer.
It is mature, well-engineered, widely used, and written by someone who has built
terminal emulators before.

## Decision

A ~600-line emulator in `Features/Terminal/TerminalEmulator.swift`, with its
scope stated honestly in the file header.

## Why

**Zero dependencies is a standing constraint** ([ADR 0004](0004-zero-dependencies.md)),
and this was the single largest test of it. It was close.

**Scope mismatch.** SwiftTerm implements a full xterm: sixel graphics, mouse
reporting, bracketed paste, selection, multiple charsets, double-width lines.
This app needs what an interactive shell, `git`, `npm` and a CLI agent actually
emit — SGR, cursor movement, erase, scroll regions, alternate screen, wrap — in
a panel 680 points wide. The unused capability is not free: it is per-session
allocation and code we would have to trust without reading.

**The renderer would have needed replacing anyway.** SwiftTerm ships an
NSView-based renderer. Our constraint is a SwiftUI `Canvas` doing one drawing
pass with style-run grouping, because a view-per-cell over 2,800 cells is
unworkable at output speed. Bridging SwiftTerm's view into SwiftUI and then not
using its renderer is most of the integration cost with little of the benefit.

**Teardown had to be exact.** The tab must release everything on close. Owning
the screen model makes "drop the buffers" a line of code rather than a question
about someone else's lifecycle.

## Costs we accepted — stated plainly

This is the ADR where the cost is most real.

- **The emulator is incomplete.** No sixel, no mouse reporting, no double-width
  characters, no bracketed paste, partial DEC private modes. `vim` renders but
  imperfectly; a mouse-driven TUI will not work properly.
- **We own the bugs.** Notably the UTF-8-split-across-reads case, which is the
  classic way emoji turn to garbage at buffer boundaries — it is handled, and it
  has a test, because it is the kind of thing a library would have got right for
  free.
- **Ongoing maintenance** as tools emit sequences we do not handle.

## What made it defensible

- The scope limitation is **written in the file header**, not discovered by a
  user.
- The parser has **13 tests** covering SGR consumption, split UTF-8, alternate
  screen restore, scrollback capping, OSC swallowing, wrap and erase.
- Scrollback is **hard-capped at 2,000 lines**. An unlimited-history terminal is
  a memory leak with a user interface; `cat bigfile` would grow the process
  without bound. This is the single most important line in the file.

## Revisit if

Users actually need mouse-driven TUIs or graphics in the notch terminal. At that
point SwiftTerm clears the [ADR 0004](0004-zero-dependencies.md) bar — the
feature would be genuinely hard and well-solved elsewhere — and taking it would
be the right call rather than a defeat.

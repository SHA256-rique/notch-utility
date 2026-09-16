# 0026 — Fixed pane layouts, not a pane tree

**Status:** Accepted · **Date:** 2026-09-16

## Context

The Terminal tab needed splits. tmux is the reference everyone has in mind, and
tmux lets you build an arbitrary tree: split any pane, in either direction, to
any depth, and resize every boundary.

## Decision

Five fixed layouts — single, side by side, stacked, main + two, and a 2×2 grid
— with a hard cap of four panes.

## Why four is the cap

Not an arbitrary number. The Terminal tab opens at 880pt. Four panes puts each
at roughly 430pt, which at an 11pt monospace font is about 60 columns — already
under the 80 that most CLI output is written for. A fifth pane produces windows
too narrow to read a stack trace in, and a terminal you cannot read is not a
terminal.

## Why not a tree

A pane tree is right for a full-screen multiplexer you live in. It is wrong for
a panel hanging off a notch, for three reasons:

- **The value here is narrow.** "Watch a build while you run something else."
  Every arrangement worth having for that is one of five presets.
- **A tree needs machinery the presets do not.** A splitter widget,
  drag-to-resize with minimum sizes, and a serialisation format for the tree —
  all to support arrangements nobody would build twice at this size.
- **Fixed layouts can be laid out arithmetically.** Each pane needs its own
  pixel size to derive its column and row count, and a pty told the wrong width
  wraps every line in the wrong place. Computing five known layouts is exact;
  measuring a dynamic tree means a layout pass before the ptys can be sized.

## The details that mattered

**Only the focused pane mounts a key catcher.** Four `NSView`s competing for
first responder is a pane that silently stops accepting input.

**Selection is per-pane state.** Held in `TerminalPaneBody` rather than the
parent — `@State` in the parent would make it shared, so dragging in one pane
would highlight the same cells in all four.

**Retired panes are stopped, not parked.** An invisible shell still holds a pty,
a process group and an emulator buffer. "I closed it" has to mean it is gone.

**Closing a pane keeps a compatible layout.** Dropping from a 2×2 grid to two
must not also flip the survivors from stacked to side by side — that is a layout
the user chose.

**"Keep alive in background" applies to the first pane only.** That setting
exists so a long build survives a glance at another tab; one shell covers it.
Keeping four would quietly hold four ptys for a tab nobody has open.

## Handing off to a real terminal

"Open in Terminal" exists because four 60-column panes is not where you want to
finish a long session. What can honestly transfer, in three parts:

- **The working directory transfers exactly**, from `proc_pidinfo` — the kernel's
  answer for the shell's cwd. Not by parsing the prompt, which is
  user-configurable, and not by shipping a shell hook, which would mean editing
  someone's zshrc for a feature they may never use.
- **The scrollback goes to the clipboard, not into the new window.** Terminal
  and iTerm2 both expose AppleScript `do script`, and pushing the transcript
  through it would be a few lines — but `do script` *executes* what it is given.
  Replaying a build log through a shell is remote code execution with extra
  steps, triggered by whatever happened to be in the output. The clipboard is
  one keystroke away and cannot run anything.
- **The running process cannot transfer**, and nothing can make it. A process is
  attached to its controlling terminal; moving it would mean reparenting it onto
  a pty owned by another application.

## Revisit if

Users ask for a fifth pane often enough to suggest they are using this as a
primary terminal — at which point the right answer is probably a detached window
rather than a fifth column.

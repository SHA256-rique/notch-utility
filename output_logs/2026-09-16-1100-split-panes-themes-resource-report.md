# 2026-09-16 11:00 — Split panes, orb drag, AI context, themes, resource report

## What was asked

1. *"the mini terminals are not working, only the full screen terminals are
   working as i am not able to type in mini terminals"* — and *"is it not
   possible to just have whatever we have in terminal copied to the og terminal
   when i click on open in terminal"*
2. *"when i click on files in ai terminal, it opens up file section but the
   notch window doesnt collapse or go in background, it stays on top so now able
   to see files to select it"* — and *"the context part in terminal should also
   have an option to add text context, i click on context and nothing happens"*
3. *"not able to drag the floating window on screen, i click on it and it opens,
   no option to drag it"*
4. *"add more themes in black/red, black/blue/while, beige/coffee (one or two
   light colored theme)"*
5. Mid-session: *"check how much effect it causes on system, cpu, ram etc on
   diff tabs, in different cases and give a report after everything has been
   done"*

---

## What changed

### 1. Split panes took no keystrokes — `TerminalTabView.swift`, `TerminalWorkspace.swift`

Each pane mounted its own `TerminalKeyCatcher`, gated on `isFocused`. Changing
focus destroyed one and created another, and SwiftUI gives no ordering guarantee
between the two: in practice the outgoing view resigned first responder *after*
the incoming one claimed it, leaving the window with no first responder and the
pane silently deaf.

Single-pane mode never hit it because pane 0 is always focused, so the catcher
never moved — which is exactly why it looked like "only the full-screen terminal
works".

One catcher for the whole tab now, pointed at `workspace.focusedPane`. It never
unmounts, so there is no handover to lose. Selection moved from per-pane
`@State` into the workspace, because cmd-C in the shared catcher has to read the
focused pane's selection.

### 2. Terminal handoff carries the output — `TerminalWorkspace.swift`

Previously clipboard only. It now prints the transcript into the new window.

The safe construction matters: `do script` **executes** what it is given, so
replaying a build log through it is RCE triggered by whatever was in the output.
The transcript goes to a temp file and the command built is
`cd <dir> && cat <file> && rm -f <file>` — every executed string is one this
function constructed, and the transcript is displayed, never interpreted. Paths
are single-quoted with the `'\''` idiom so a directory named `it's` cannot
terminate the command.

Non-scriptable terminals (Ghostty, Kitty, Alacritty, WezTerm) get directory +
clipboard, which is the limit of their public interface.

### 3. Orb drag — `NotchPanel.swift`, `NotchPanelController.swift`

The previous session's rewrite to `performDrag(with:)` was correct and still did
nothing, because `NotchPanel` sets `isMovable = false` — and `performDrag` on an
immovable window is a **silent** no-op. No error, no log.

`setDraggable` flips it on for orb presentation only, and is re-applied on screen
configuration change since docking can flip the resolved presentation.

### 4. AI tab — `AIChatTabView.swift`, `NotchPanelController.swift`

- **File picker opened behind the panel.** The panel is at `.statusBar` level.
  `runningModal` drops it to `.normal` for the duration. Collapsing instead
  would tear down the calling view mid-call, and `runModal()` blocks the run
  loop so the collapse could not finish first. Applied to every `NSOpenPanel`
  in the app — Files and the Launch widget had the same latent bug.
- **Context expanded to nothing** when there were no attachments, so the button
  looked dead. It now explains itself.
- **Typed text context** added, with an optional label and a live token estimate.

### 5. Themes — `Theme.swift` and every view using a white overlay

Ember (black/red), Midnight (black/blue/white), Latte (beige/coffee), Parchment
(warm paper). Seven total.

Two blockers had to go first: `primaryText` was hardcoded `.white`, and the app
was full of `Color.white.opacity(0.07)` meaning "slightly lighter than the
panel" — which is nothing on cream. Those became `theme.fieldBackground` and
`theme.surfaceTint`.

The module palette is tuned for white-on-black, so light themes darken every
tint by 42% rather than maintaining a second palette.

The collapsed pill stays dark in every theme. Its job is continuity with a black
plastic cutout; a cream tab hanging off the notch would be the most visible
thing on screen.

### 6. Benchmark harness — `Scripts/bench-tabs.sh`, `AppDelegate.swift`

One process per tab, driven by `NOTCHSCOTCH_BENCH_TAB`. See the report below.

---

## Commands run and their output

```
$ swift build
Build complete! (0.12s)

$ ./Scripts/test.sh
✔ Test run with 158 tests in 29 suites passed after 0.028 seconds.

$ ./Scripts/build-app.sh
    Built: dist/NotchScotch.app  ( 11M)
```

### Resource report

`Scripts/bench-tabs.sh 8` — one fresh process per tab, 5s settle, 8s
measurement window, `proc_pid_rusage`:

```
TAB              CPU ms/s  WAKEUPS/s    FOOTPRINT          RSS
---              --------  ---------    ---------          ---
collapsed            0.01        1.4       10.9MB       50.3MB
home                 2.90       30.1       35.1MB       93.1MB
time                 0.38        1.8       29.7MB      111.5MB
snippets             0.01        1.8       36.4MB      123.5MB
notes                0.05        2.8       26.5MB       73.9MB
calendar             3.16        3.1       40.2MB       90.7MB
files                0.64       15.8       31.9MB       75.1MB
diskMap             19.06       12.6       32.1MB       97.7MB
api                  0.71       42.0       27.7MB      106.4MB
terminal             0.79        8.0       79.4MB       84.2MB
ai                   0.01        1.4       27.3MB       86.7MB
message              0.05        1.9       36.6MB      120.5MB
teleprompter         0.33       13.4       36.9MB      108.6MB
settings             0.16        3.2       41.2MB      128.8MB
```

Disk Map settling, measured separately over 45s:

```
0-10s (scanning)         19.88 ms/s    11.7 wk/s    38.4MB footprint
10-25s                   14.02 ms/s     4.1 wk/s    38.1MB footprint
25-45s (settled)          3.46 ms/s     3.8 wk/s    38.4MB footprint
```

Collapsed, 5 samples over 20s via `ps`:

```
0.0%  47952 KB
0.0%  44672 KB
0.0%  45184 KB
0.0%  45120 KB
0.0%  44864 KB
```

---

## Decisions and trade-offs

- **One key catcher, not one per pane.** The alternative was to serialise the
  responder handover with explicit ordering, which means depending on SwiftUI
  teardown order — undocumented and version-dependent. A catcher that never
  moves has no ordering to depend on.
- **`cat` a temp file rather than `do script` the transcript.** The safe version
  costs a temp file and a `rm`; the unsafe version is an RCE with a shell
  prompt in front of it.
- **Lower the panel's window level for modals rather than collapsing.**
  Collapsing destroys the calling view mid-call and cannot complete anyway,
  since `runModal()` blocks the run loop.
- **One process per tab in the benchmark.** Switching tabs in a single process
  would attribute every tab's high-water footprint to whichever came last.
- **Light themes darken the existing palette rather than defining a new one.**
  A second set of seventeen hues is a second set to keep in sync; a luma test
  catches the cases where 42% is not enough.

---

## What is still open

- **None of the four UI fixes is visually confirmed.** Build, tests and launch
  all pass, but "I can type in the second pane", "the orb drags", "the file
  picker is in front" and "the light theme is readable" are all things only a
  pointer on your hardware can settle.
- **The terminal handoff has not been run against a real Terminal.app.** The
  AppleScript path will prompt for automation permission the first time; if you
  decline it, it falls back to directory + clipboard rather than failing.
- **`api` showed 42 wakeups/s in one run and lower in another.** I did not
  chase it. It is likely the URLSession the tab holds, but that is a guess and
  it is recorded as one.
- **Theme coverage is not exhaustive.** The shared controls read theme values
  now, but individual tabs may still have literal colours that look wrong on
  Latte or Parchment. I swapped the ones I found by grep, not by looking at
  every screen in every theme.
- **The benchmark measures a tab sitting still.** Typing in the terminal,
  streaming from the AI tab or converting a batch of images will all cost more,
  and none of that is measured here.

---

## Commits

| Hash | Subject |
|---|---|
| `d964bc7` | fix(orb): the window was immovable, so performDrag did nothing |
| `276c97e` | fix(terminal): typing in split panes, and a handoff that carries the output |
| `7099492` | fix(ai): the file picker opened behind the panel, and Context did nothing |
| `005d07a` | feat(theme): four more themes, two of them light |
| `bc219c2` | perf: a per-tab benchmark, because "it feels light" is not a measurement |

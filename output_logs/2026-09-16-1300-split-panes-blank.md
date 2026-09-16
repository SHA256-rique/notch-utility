# 2026-09-16 13:00 — Split panes were blank: two bugs, one symptom

## What was asked

> *"still the multi-terminal isnt working, only first termnial has cli, rest are
> empty"*

A follow-up to the previous session, where I had "fixed" split panes by
consolidating the key catcher. That fixed typing. It did not fix this, and my
previous log recorded the fix as unverified — correctly, as it turns out.

---

## What changed

### The bug that made every pane blank — `TerminalEmulator.swift`

`visibleLines` returns the **last `rows` lines** of the buffer. `resize` grew
the line array when the screen got taller and never shrank it when the screen
got shorter.

Splitting one terminal into four drops each pane from 28 rows to 23.
`lines.count` stayed at 28 while `rows` became 23, so the viewport slid five
lines down the buffer — past the only line with anything on it. A shell that had
printed exactly one prompt rendered as an empty black rectangle.

It never bit single-pane mode because that only ever resizes *upward* from the
emulator's 28-row default. That is precisely why one terminal always worked and
the split never did.

The fix drops trailing **blank** lines on shrink — never the cursor's own line,
never a line with content. Truncating to `rows` would have been one line shorter
and would silently eat scrollback; there is a test asserting real output
survives a shrink.

### The bug underneath it — `TerminalView.swift`

The Canvas forces a redraw by changing its `.id()`, keyed on
`generation-cursorOn-isFocused-selection`. In a split, every *unfocused* pane
produced a byte-identical key: same generation, same cursor phase,
`isFocused: false`, no selection. Three siblings sharing one explicit identity
is not three views to SwiftUI.

`renderKey` now includes the session id, and is a `nonisolated static` so it can
be tested directly.

This one was masked by the resize bug — both had to go before a split would
render anything, which is why fixing the identity alone showed no improvement.

---

## Commands run and their output

**Step 1 — is the OS fine?** A standalone harness spawning four ptys:

```
$ ./multipty
spawned 4 ptys
pane0 pid=14216 bytes=104
pane1 pid=14217 bytes=104
pane2 pid=14218 bytes=104
pane3 pid=14219 bytes=104
```

Four ptys coexist happily. Not the OS, not `posix_spawn`.

**Step 2 — is the app spawning them?**

```
$ NOTCHSCOTCH_BENCH_TAB=terminal NOTCHSCOTCH_BENCH_LAYOUT=grid ...
child shells: 4
```

All four running. So the model was fine and it was a rendering problem.

**Step 3 — what does each pane actually hold?** A temporary diagnostic:

```
pane 0 gen=2 run=true 54x23 lines=49 firstVisible=[                    ]
pane 1 gen=2 run=true 54x23 lines=28 firstVisible=[                    ]
pane 2 gen=2 run=true 54x23 lines=28 firstVisible=[                    ]
pane 3 gen=2 run=true 54x23 lines=28 firstVisible=[                    ]
```

`lines=28` against `rows=23`, and a first visible line of pure spaces. That
names the bug outright.

**Step 4 — after the fix:**

```
pane 0 gen=2 run=true 54x23 lines=23 firstVisible=[shams@shamss-MacBook-Pro notch-utility %  ]
pane 1 gen=2 run=true 54x23 lines=23 firstVisible=[shams@shamss-MacBook-Pro notch-utility %  ]
pane 2 gen=1 run=true 54x23 lines=23 firstVisible=[shams@shamss-MacBook-Pro notch-utility %  ]
pane 3 gen=2 run=true 54x23 lines=23 firstVisible=[shams@shamss-MacBook-Pro notch-utility %  ]
```

**Step 5 — screenshot of the running app.** Four panes, four prompts, one solid
cursor in the focused pane and three hollow ones. Verified by eye, not inferred.

```
$ swift build
Build complete! (9.86s)

$ ./Scripts/test.sh
✔ Test run with 168 tests in 31 suites passed after 0.024 seconds.

$ open dist/NotchScotch.app && ps -o %cpu=,rss= -p $(pgrep -x NotchScotch)
  0.0  51456
```

---

## Decisions and trade-offs

- **Drop only blank trailing lines, not truncate to `rows`.** Truncation is
  simpler and would discard scrollback every time a window got smaller. A test
  pins that real output survives a shrink.
- **Keep `NOTCHSCOTCH_BENCH_LAYOUT`.** Added as a debugging aid; kept because
  opening straight into a split is useful for the benchmark and for the next
  bug report.
- **Test `renderKey` directly rather than through a view.** The failure was two
  strings being equal when they should differ. That is a pure function, and
  testing it through SwiftUI would have proved nothing about why.
- **A pane-start integration test was written and then deleted.** It asserted
  that each pane received bytes, and failed for *all four* panes including the
  working one — swift-testing does not service `DispatchQueue.main.async` the
  way I was spinning the run loop, so the result was a harness artifact rather
  than a finding. Keeping it would have been a permanently red test that proved
  nothing.

---

## What is still open

- **Typing in a specific pane is still unverified by me.** The screenshot shows
  four live prompts and the correct cursor states, which is strong evidence the
  key catcher is attached to the focused pane, but I did not synthesise
  keystrokes into each pane in turn.
- **Resizing a split while output is scrolling is untested.** The shrink path
  now runs on every layout change; a pane mid-build while you split is a case I
  reasoned about but did not exercise.
- **`gen=1` on pane 2** in the verification run, where the others were at 2.
  Harmless — it means that pane had one redraw rather than two — but I noted it
  rather than smoothing it over.

---

## Commits

| Hash | Subject |
|---|---|
| `6c99947` | fix(terminal): split panes were blank because resize never shrank the buffer |

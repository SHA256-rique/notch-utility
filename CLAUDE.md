# NotchScotch — working agreement

A macOS notch utility. Native Swift/AppKit/SwiftUI, zero third-party
dependencies, and an obsession with costing nothing when nobody is looking at
it.

---

## Always: write a session log

**Every time a unit of work is finished, write a Markdown log to
`output_logs/`.** This is not optional and not conditional on the work being
interesting. If the content is similar to what you have told user in the terminal after completing work ,just pipe the response to the new log file.

**Filename:** `output_logs/YYYY-MM-DD-HHMM-short-slug.md`

**It must contain:**

| Section                           | What goes in it                                                                                                                                      |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What was asked**                | The request, in the user's own framing. Quote it where the wording matters.                                                                          |
| **What changed**                  | Files touched and what each change does. Not a diff — the _intent_.                                                                                  |
| **Commands run and their output** | The real commands, with their real output. Build results, test counts, benchmark numbers, launch checks. Paste the output, do not summarise it away. |
| **Decisions and trade-offs**      | Anything where a reasonable engineer would have chosen differently, and why this way. Link the ADR if one was written.                               |
| **What is still open**            | Known gaps, things deliberately skipped, things that need the user to verify. Be honest here; this section is the point.                             |
| **Commits**                       | Hashes and subject lines.                                                                                                                            |

**Rules for the log:**

- **Paste real output.** "Tests passed" is worthless; `✔ Test run with 153 tests
in 28 suites passed` is a record. If a command failed, the failure goes in
  too — a log that only contains successes is a press release.
- **Record what did not work.** Reverted approaches, wrong first attempts, and
  bugs found by running the thing are the most valuable content in the file.
  There is precedent: per-tab sizing shipped and was reverted, and the ADR that
  records why is more useful than the feature was.
- **Never fabricate.** If a verification step was not run, say it was not run.
- **One log per session of work**, appended to if the session continues.

**Commit the log with the work**, or immediately after, and push. The log is
part of the deliverable.

---

## Non-negotiable engineering constraints

These are settled. Do not relitigate them; if something genuinely conflicts,
raise it rather than quietly picking a side.

1. **Native Swift / AppKit / SwiftUI only.** No Electron, no web views for app
   UI, no cross-platform layer.
2. **Zero third-party dependencies.** The bar is "we cannot reasonably
   hand-roll it", and nothing has cleared it — including the VT100 emulator.
3. **No shelling out for system data.** Darwin APIs directly: `host_statistics`,
   IOKit power sources, `proc_pidinfo`, `URLResourceValues`. The one documented
   exception is `/usr/sbin/screencapture`, and it has a comment saying why.
4. **Event-driven over polling, always.** Battery, media, clipboard and calendar
   are notification handlers, not timers.
5. **One `WidgetPollingHub`.** No widget owns a `Timer`. Everything registers an
   interval and a closure; the hub runs a single `DispatchSourceTimer` at the
   GCD of them, and is switched off entirely when the panel is unattended.
   `NotchPanelController` and `StandaloneWindowController` are the only callers
   of `setActive`.
6. **Teardown on close is structural.** Only the selected tab is constructed, so
   SwiftUI destroys the previous one and fires its `.onDisappear`. That is where
   every registration, socket and buffer is released. There is exactly one place
   per tab to check.
7. **Two tiers.** Tier 1 is the collapsed pill/orb and may hold almost nothing.
   Tier 2 is on-demand and pays for itself only while open.
8. **Secrets in Keychain, never in a file.** `SettingsData` holds provider enums
   and endpoints; keys are read at the moment of use.
9. **Local-first.** Settings → About lists everything that leaves the Mac, and
   that list must stay true.
10. **Apple-quality motion.** Springs from `Motion`, never ad-hoc durations. One
    animation per _category_ of thing, not per feature.

---

## House rules for the code

- **Comment the _why_, never the _what_.** `// increment counter` is noise.
  "Skip the publish entirely if nothing changed — Tier-1 subsystems re-assert
  their claim on every event, and without this a battery notification storm
  becomes a SwiftUI invalidation storm" is the standard.
- **A non-obvious decision gets a doc comment on the type**, structured as
  `## Why X and not Y`.
- **A genuinely contested decision gets an ADR** in `docs/decisions/`, stating
  the alternatives that were actually considered, what they would have cost, and
  what would make us revisit.
- **Tests cover what is expensive to get wrong and invisible when it is**:
  arithmetic, parsing, ordering, retention rules. Do not mock AppKit or IOKit —
  a test asserting "we called `IOPSCopyPowerSourcesInfo`" proves nothing.
- **Never leave a test asserting something no longer true.** When a premise
  changes, change the assertion and say so in the commit.

---

## Verification before claiming done

In this order, every time:

```bash
swift build                  # must be clean
./Scripts/test.sh            # must be green; paste the count
./Scripts/build-app.sh       # must sign and verify
open dist/NotchScotch.app    # must launch and stay up
```

Then check it is still alive and what it costs:

```bash
ps -o %cpu=,rss= -p $(pgrep -x NotchScotch)
```

**"It builds" is not "it works."** If a UI change cannot be verified by running
it, say so in the log rather than implying it was checked.

---

## Commits

- Conventional prefixes: `feat(scope):`, `fix(scope):`, `chore:`, `docs:`,
  `test:`, `perf(scope):`.
- The subject line says what changed. **The body says why, and what it cost.**
  Commit messages here are long on purpose — they are the closest thing to a
  design record that travels with the code.
- End every commit message with:

  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

- Push to `origin main` when the work is verified.
- **Do not commit binaries** — screenshots, `.app` bundles, `dist/`.

---

## Project layout

```
Sources/NotchScotch/
  Core/         panel, window, geometry, notch shape, polling hub, arbiter,
                settings, theme, motion, cursor
  Tier1/        battery, now playing, system stats, collapsed pill, orb
  Tier2/        expanded panel, tab dock, word rail, Tabs/*
  Features/
    Approval/   waiting-on-approval primitive + three transports
    Terminal/   pty, VT100 emulator, session, panes, renderer
    Storage/    disk scanner, squarified treemap, cleanup categories
    Calendar/   EventKit and Google sources, OAuth loopback flow
    LLM/        streaming client, chat store, context loader
    Snippets/   unified store + clipboard watcher + task board
    Time/       timers, alarms, pomodoro, stopwatch, water
    Widgets/    screen time, weather, Stripe, visitors, Claude usage, words
    Files/ Message/ Selection/ Teleprompter/
  Support/      logging, JSON store, Keychain
Tests/          swift-testing
Scripts/        build-app.sh · test.sh · bench-idle.sh · install-hook.sh
docs/           ARCHITECTURE.md · BENCHMARKS.md · decisions/ · learning/
output_logs/    one Markdown log per session of work
```

---

## Things that bite

- **macOS reserves the camera-housing rectangle.** Nothing may be drawn there.
  Content placed under it is not clipped or dimmed — it is absent, with nothing
  to tell the user it exists. Use `ScreenGeometry.shoulderWidth` before drawing
  anything near the top of the screen. See ADR 0023.
- **TCC keys folder permissions to the bundle identifier.** The rename to
  `com.notchscotch.app` dropped every grant the old identifier held. Detect a
  denial and point at the settings pane; never report "empty".
- **`URL(string:)` succeeds without a scheme.** `URL(string: "google.com")` is a
  valid URL with a nil scheme, which is how a custom tab shipped looking correct
  and rendering blank.
- **Swift's `%` keeps the sign of the dividend.** Stepping an index backwards
  needs `((n % c) + c) % c`.
- **`hashValue` is seeded per process.** Anything that must be stable across
  launches needs its own hash.
- **`performDrag(with:)`, not `DragGesture`, for moving a window.** The gesture
  reports cumulative translation relative to the window it is in, so moving the
  window feeds back into the next event. That loop is the flicker.

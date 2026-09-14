# Benchmarks

The brief calls shipping an idle-CPU number "table stakes", and it is right:
users in this category have learned to ask before installing. So here is the
number, the method, and everything wrong with the method.

---

## Results

**Apple M5 (10 cores) · macOS 26.5.1 · release build · 3 × 10s windows**

| State | CPU (% of one core) | Wakeups/sec | Footprint | RSS |
|---|---:|---:|---:|---:|
| **Collapsed, nothing open** | **0.0004%** | **0.9** | **13.6 MB** | 39.7 MB |
| Collapsed, nothing open *(repeat run)* | 0.0010% | 1.0 | 13.7 MB | 37.8 MB |
| Collapsed, clipboard capture off | 0.0005% | 0.2 | 14.0 MB | 41.7 MB |
| Expanded, Home tab (stats at 2s) | 0.1198% | 11.0 | 24.9 MB | 65.0 MB |
| Expanded, Terminal tab (idle shell on a pty) | 0.0003% | 0.9 | 20.9 MB | 58.4 MB |

The collapsed state is listed twice, from two separate launches of the same
build, because the spread is informative: **wakeups and footprint reproduced
almost exactly (0.9 vs 1.0, 13.6 vs 13.7 MB) while CPU varied by 2.5×**. That is
the clearest possible demonstration of the point made below — at this scale the
CPU column is noise and the wakeup column is signal.

Reproduce:

```sh
./Scripts/build-app.sh release
open dist/NotchBuddy.app
./Scripts/bench-idle.sh 10 3

# expanded states, reproducibly:
pkill -x NotchBuddy
open dist/NotchBuddy.app --args --bench-tab home       # or: terminal
./Scripts/bench-idle.sh 10 3
```

---

## How to read this table

### Wakeups/sec is the number that matters

On Apple Silicon, the cost of a periodic task is dominated by the **wakeup**,
not by the work in the callback. Pulling a core out of an idle state costs
roughly the same whether the callback does one thing or nothing at all;
`powermetrics` treats wakeups per second as a first-class metric for exactly
this reason.

It is also considerably harder to game than CPU percentage. An app can look
good on CPU% by doing tiny amounts of work very often — which is precisely the
pattern that ruins battery life. That is why this column is reported
first-class.

### The clipboard comparison is the interesting row

`0.9 → 0.2` wakeups/sec when clipboard capture is turned off.

The clipboard watcher runs at a 1.2-second interval, i.e. 0.83 wakeups/sec. It
accounts for essentially the entire difference. With it off, the remaining
**0.2/sec is AppKit's own housekeeping plus our event-driven monitors doing
nothing** — which is the architectural floor for a running GUI process.

This is the most useful single fact in this document, because it demonstrates
the claim rather than asserting it: with the one polling component disabled,
the rest of a twelve-tab app measurably costs nothing while collapsed.

macOS has never offered a pasteboard-change notification, so every clipboard
manager on the platform polls. We poll the cheapest thing available — a single
`changeCount` integer, which does not deserialise pasteboard contents — and we
publish the cost rather than hiding it.

### Do not over-read the CPU column

Anything below about **0.01% is at the edge of meaningful**. Those are real
measured nanoseconds of CPU time, but at that scale the figure is dominated by
scheduler noise and sampling boundaries.

The two collapsed rows in the table are the proof: identical build, identical
machine, two launches, and the CPU figure moved 2.5× (0.0004% → 0.0010%) while
wakeups moved 11% (0.9 → 1.0) and footprint moved 0.7% (13.6 → 13.7 MB). So
`0.0003%` is not meaningfully lower than `0.0010%`; both mean "effectively
nothing". Only the wakeup and footprint columns discriminate usefully at the low
end, which is why the README leads with wakeups.

### Footprint vs RSS

`ri_phys_footprint` is what Activity Monitor shows in its **Memory** column, and
it is the honest figure: **13.6 MB collapsed**.

RSS (39.7 MB) is also reported, for transparency, but it counts shared framework
pages — AppKit, SwiftUI, Foundation — that are mapped by every Cocoa app on the
system and would be resident whether or not NotchBuddy were running. Quoting RSS
would understate the app; quoting only footprint without mentioning RSS would be
selective. Both are in the table.

For calibration, the brief's stated target was "far below" the 150–300 MB that a
web-view-based notch app idles at.

### Why the Home tab costs more than the Terminal tab

This looks backwards until you see what each is doing.

The **Home tab** has live UI: three animated progress rings, a screen-time
sparkline, and a stats sampler on the hub at 2s. SwiftUI re-renders that content
on every sample, and the 11 wakeups/sec is mostly the rendering and the CoreAudio
property listener, not the hub itself (which contributes 0.5/sec at a 2s tick).

The **Terminal tab** has a pty and a `/bin/zsh -l` child process — but an idle
shell is blocked in `read()` and costs nothing, and the emulator only redraws
when bytes arrive. A visible terminal doing nothing is genuinely cheaper than a
visible dashboard doing something.

Note also that the Home tab figure is the **worst realistic case**: it is the
most expensive tab, pinned open indefinitely. In normal use the panel is
expanded for seconds at a time.

---

## Method

[`Scripts/bench-idle.sh`](../Scripts/bench-idle.sh) samples
`proc_pid_rusage(pid, RUSAGE_INFO_V4)` at the start and end of each window and
reports the deltas:

- `ri_user_time + ri_system_time` — CPU time in **nanoseconds**
- `ri_interrupt_wkups` — wakeups, divided by elapsed wall time
- `ri_phys_footprint`, `ri_resident_size` — memory, point-in-time

Measurement is done **from outside the process**, by a separate tool. A
benchmark an app reports about itself is not evidence.

### Two approaches that were tried and rejected

**`ps -o %cpu` — wrong, and wrong in the flattering direction.** On Darwin,
`ps`'s `%cpu` is total CPU time divided by total elapsed time *since the process
started* — a lifetime average, not an interval. An app that burned a full core
for its first second and then slept for an hour reports approximately zero. Any
app looks good on that metric given enough uptime, so publishing it would have
proved nothing at all. The first version of this script made exactly this
mistake.

**`ps -o cputime` — right idea, insufficient resolution.** It does measure a
real interval, but only to 10ms. For this app every window read `0`, which
cannot distinguish "genuinely idle" from "quietly busy just under the threshold".

Both dead ends are left documented in the script's header so the next person does
not repeat them.

---

## Honest caveats

Please read these before quoting the table.

1. **One machine, one OS version.** Apple M5 on macOS 26.5.1. Intel Macs will
   differ, and older Apple Silicon will differ somewhat. Numbers from a single
   machine are an existence proof, not a distribution.

2. **A quiet machine.** Measured with no heavy background load. A busy system
   changes scheduling and coalescing behaviour.

3. **Short windows.** 3 × 10 seconds catches steady-state idle, not rare
   periodic work. A day-long soak would be a better test and has not been run.
   If you run one, please open an issue with the numbers.

   Relatedly: **each state below was measured on one launch** (except the
   collapsed state, measured twice). Treat the single-run figures as indicative,
   not as means. The right fix is more runs, not more decimal places.

4. **Energy is not measured.** CPU time and wakeups are proxies for battery
   impact, good ones, but not the thing itself. A proper energy measurement
   needs `powermetrics` with root, over a longer window, ideally with the
   display off. That is the obvious next step for this document.

5. **Not every feature is exercised.** These figures cover the collapsed state
   and two tabs. Selection assist armed, an active LLM stream, or a running
   teleprompter all cost more — the teleprompter in particular scrolls at 60Hz
   by design while it is playing.

6. **Debug builds are much slower.** Always benchmark `release`. A debug build
   carries bounds checks and no optimisation and will produce numbers several
   times worse.

7. **First-launch is not steady state.** Give the app a few seconds after
   launch before measuring; the script does not do this for you.

---

## What we would measure next

- `powermetrics` energy impact over a 1-hour window, screen off.
- A 24-hour soak, watching footprint for slow growth.
- Intel baseline.
- The same table with every tab exercised in rotation, to catch a tab that fails
  to tear down. A leak would show as footprint that does not return to ~13.6 MB
  after collapsing.

That last one is the highest-value future test, because a teardown bug is
exactly the failure this architecture is designed to prevent and exactly the
kind that would not show up in the numbers above.

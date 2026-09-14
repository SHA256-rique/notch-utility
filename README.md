# NotchBuddy

A native macOS utility that turns the MacBook notch into a Dynamic-Island-style
surface: a collapsed pill that shows only genuinely urgent glance info, and an
expandable panel of on-demand tools.

Swift, AppKit and SwiftUI. **Zero third-party dependencies.** No Electron, no
web view shell, no account, no telemetry.

---

## The number you came for

Measured on an Apple M5 (10-core), macOS 26.5.1, with
[`Scripts/bench-idle.sh`](Scripts/bench-idle.sh) — reproduce it yourself:

| State | CPU | Wakeups/sec | Memory |
|---|---:|---:|---:|
| **Collapsed, nothing open** | **0.0004–0.0010%** of one core | **0.9–1.0** | **13.6 MB** |
| Collapsed, clipboard capture off | 0.0005% | 0.2 | 14.0 MB |
| Expanded, Home tab (stats polling at 2s) | 0.1198% | 11.0 | 24.9 MB |
| Expanded, Terminal tab (pty alive, idle shell) | 0.0003% | 0.9 | 20.9 MB |

The collapsed row is given as a range because it was measured twice, on separate
launches, and that is the spread. Reporting the luckier of the two as a single
figure would be the wrong kind of precision — see the note below on reading the
CPU column.

Full method, caveats and how to re-run: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

Two things about this table are worth reading carefully.

**Wakeups per second is the real metric.** On Apple Silicon the cost of a timer
is the wakeup itself, not the work in the callback — a core pulled out of an
idle state costs roughly the same whether the callback does one thing or
nothing. CPU percentage is easy to make look good and hard to interpret;
wakeups are neither. This app is architected around driving that number to
approximately zero, and the collapsed figure of 0.9/sec is almost entirely one
component.

**That component is the clipboard watcher**, at a 1.2-second interval —
0.83 wakeups/sec of the 0.9. Turn clipboard capture off and the whole app drops
to 0.2/sec, which is AppKit's own housekeeping plus our event-driven monitors
doing nothing. macOS has never offered a pasteboard-change notification, so
every clipboard manager on the platform polls; we poll the cheapest thing there
is (a single integer) and we say so out loud rather than hiding it.

**On the "% of one core" numbers:** anything below ~0.01% is at the edge of what
is meaningful. It is real measured CPU time, but at that scale it is dominated
by scheduler noise — the same build measured on two launches gave 0.0004% and
0.0010%, a 2.5× spread of nothing. Do not read 0.0003% as meaningfully lower
than 0.0010%; both mean "effectively nothing". The wakeup column is the one that
actually discriminates, and it was stable at 0.9–1.0 across both runs.

---

## Quick start

Requires macOS 14+. Xcode is **not** required — Command Line Tools are enough.

```sh
git clone https://github.com/shams03/notchbuddy.git
cd notchbuddy

./Scripts/build-app.sh release     # builds dist/NotchBuddy.app
open dist/NotchBuddy.app

./Scripts/test.sh                  # 55 tests
./Scripts/bench-idle.sh 10 3       # idle benchmark (app must be running)
```

The app has no Dock icon. It lives in the notch and in a status-bar item.
Hover the notch to expand, or press **⌘⌥Space**.

To watch what it is doing:

```sh
log stream --predicate 'subsystem == "com.notchbuddy.app"' --level debug
```

---

## The architecture, in one page

### Two tiers, and a hard rule between them

**Tier 1** is the collapsed pill. Only content that is genuinely urgent or
momentary is allowed here, and each item renders *nothing at all* when it has
nothing to say — an idle timer shows no `00:00`, a paused track shows no empty
scrubber. Battery, Now Playing, running timers, the agent-approval badge, and
an optional compact stats readout.

**Tier 2** is everything else: twelve tabs behind icons. Nothing in Tier 2
exists until its tab is opened, and nothing survives it closing.

The rule between them: **nothing outside Tier 1 may poll, render, or hold
retained state while the user is not looking at it.**

### The polling hub is how that rule is enforced

No widget in this app is permitted to own a `Timer`.

The naive structure — ten widgets, ten timers — produces ten independent
scheduler wakeups. Widgets instead register `(interval, closure)` with
[`WidgetPollingHub`](Sources/NotchBuddy/Core/WidgetPollingHub.swift), which runs
**one** `DispatchSourceTimer` at the greatest common divisor of every registered
interval and dispatches each registration when its own period elapses. Ten
widgets at 1s/2s/5s produce one wakeup per second, not ten. The timer carries
25% leeway so the kernel can coalesce our wakeup with one it was already going
to perform.

`setActive(false)` **cancels the underlying source** rather than setting a flag
and continuing to tick. When the panel is collapsed and unpinned, the process
has no scheduled widget work at all. There is exactly one caller of that method
in the entire codebase —
[`NotchPanelController.updateHubActivation()`](Sources/NotchBuddy/Core/NotchPanelController.swift)
— which makes the power behaviour auditable rather than emergent.

Settings → Power shows the live registration list, so a user chasing battery
drain can verify this instead of taking our word for it.

### Teardown is structural, not a convention

The expanded panel builds **only** the selected tab — a `switch` inside a
`Group`, never a `TabView` (which keeps every page alive) and never a stack of
hidden views. SwiftUI therefore destroys the previous tab's view tree on switch,
firing its `.onDisappear`, and that is where each tab unregisters from the hub,
closes its sockets and releases its buffers.

The consequence is that forgetting to clean up is *hard*: there is exactly one
place per tab to check, and the framework fires it for you.

### Notch arbitration

Defined in one place so "what is the notch showing right now" is never a
side-effect of whichever subsystem updated last
([`NotchArbiter`](Sources/NotchBuddy/Core/NotchArbiter.swift)):

- **Persistent** claims (a running timer, a blocked CLI) *hold* the pill until
  they resolve.
- **Transient** pop-ins (a copy confirmation, a conversion-finished toast) share
  exactly one rotating slot. Newest wins; nothing stacks and nothing queues — a
  queue would mean five rapid copies make the notch unusable for ten seconds.
  A transient *overlays* a persistent claim without evicting it, so the
  persistent one reappears when it fades with no extra bookkeeping.
- **Ambient** claims (battery, stats) are the floor.
- Among equal persistent claims, **lowest rank wins**. Timers set rank =
  seconds remaining, which produces "show the one closest to completion" without
  the arbiter ever learning what a timer is. All of them stay visible in the
  expanded header.

---

## Why each API, over the obvious alternative

This is the section the brief asked for, and it is the most useful thing in this
README. Longer treatments are in [docs/decisions](docs/decisions/).

### System stats → `host_statistics` / `host_statistics64`, not `top`

The tempting version is `Process` + `top -l 1` and some string parsing. That is
**10–30ms of CPU per sample** for process spawn plus dynamic linking plus the
tool's own startup. At a 2-second interval that is 0.5–1.5% of a core burned
continuously — the measurement would cost more than everything else the app does
combined. A Mach trap costs microseconds.

Beyond cost: `top`'s column layout is not an API and has changed between
releases, it is localised (`"1,5%"` parses to `1` in a naive `Double(_:)`), and
spawning shells widens the process tree in ways that are easy to get subtly
wrong.

Memory Used deliberately follows Activity Monitor's definition — active + wired
+ compressed — rather than `total - free`, which reads as 90% on every healthy
Mac and makes the widget look broken.

### Battery → IOKit power-source notifications, not a timer

`IOPSNotificationCreateRunLoopSource` fires when power management itself decides
something changed. A 30-second poll would be 2,880 wakeups a day to learn a
number that changes maybe 200 times — and they would happen while collapsed,
the exact state this app promises costs nothing.

### Now Playing → MediaRemote via `dlopen`, and honest degradation

There has never been a public read API for "what is the system playing"
(`MPNowPlayingInfoCenter` only *publishes* your own app's state), so everyone in
this category reads the private `MediaRemote.framework`.

As of macOS 15.4, Apple gated `MRMediaRemoteGetNowPlayingInfo` behind a private
entitlement. We therefore resolve every symbol at runtime with `dlopen`/`dlsym`
and **never link the framework**. A hard link against a private framework is how
apps in this category end up refusing to launch after an OS update. When the
symbols are missing or return nothing, the pill simply omits the item and
Settings → About explains why. The fallback is deliberately *nothing* rather
than a worse heuristic: AppleScripting Music.app would mean Apple Events prompts
and per-app special-casing for a cosmetic feature.

### Clipboard → `changeCount`, not content polling

No pasteboard-change notification exists. What makes polling acceptable is
*what* is polled: `changeCount` is a single monotonic integer maintained by the
pasteboard server, and reading it does **not** deserialise the contents. The
naive version calls `string(forType:)` every tick, which forces the *owning
application* to re-render its data into the requested type on every poll —
3,600 times an hour for a 20MB image on the pasteboard. We touch real data only
on the ticks where the counter moved.

Concealed (password-manager) and transient pasteboard types are skipped by
default. Honouring those conventions is the difference between a clipboard
manager you can trust with a 1Password copy and one you cannot.

### Screen Time → our own tracking, not `knowledgeC.db`

Apple's Screen Time data requires **Full Disk Access** — a permission that
cannot be requested programmatically, only granted by the user walking into
System Settings and dragging the app into a list. Asking for the most alarming
permission macOS offers so a widget can draw a bar chart is a bad trade for an
app whose pitch is restraint. The schema is also private and has changed shape
between releases.

`NSWorkspace.didActivateApplicationNotification` is the only signal needed.
Sleep, screen lock and midnight rollover all close the open segment — without
which, closing the lid at 6pm and opening it at 9am credits fifteen hours to
whatever app happened to be frontmost.

### Global hotkey → Carbon `RegisterEventHotKey`

Yes, Carbon, in 2026, for new code. It is the only global-hotkey API that does
**not** require Accessibility permission — `NSEvent.addGlobalMonitorForEvents`
and `CGEventTap` both do. Demanding Accessibility at first launch just to bind
⌘⌥Space is a terrible first impression for an app whose entire pitch is "I
respect your machine", and most users who decline never come back to grant it.
It also fires over full-screen apps, which a local event monitor cannot.

The cost is C interop: the callback is a bare function pointer with no closure
context, so it trampolines through a singleton.

### Selection assist → `AXObserver` notifications, not AX polling

The naive implementation polls `AXUIElementCopyAttributeValue` for
`kAXSelectedTextAttribute` several times a second, forever. That is an expensive
*synchronous IPC call into another process*, and on a heavy app (an IDE, a
browser with many tabs) it is measurably costly to **both** processes. It is the
single most common reason apps in this category get accused of making the
machine feel sluggish.

We register an `AXObserver` for `kAXSelectedTextChangedNotification` on the
focused app and re-point it when the frontmost app changes — itself a workspace
notification, not a poll. Between selections the cost is zero.

This is the one feature that needs Accessibility access, and it is **off by
default**. Nothing arms the observer until the user turns it on, at which point
the permission prompt has obvious cause and effect.

### Terminal → a pty, not pipes

A pipe is not a terminal. With pipes there is no job control (ctrl-C kills
nothing), `isatty()` is false so every well-behaved CLI disables colour and
switches to non-interactive mode, and there is no window size. Since one of the
headline features is intercepting an interactive approval prompt from a CLI
agent, a pipe-backed "run one command and show output" box would have made that
feature impossible.

`posix_spawn` rather than `fork()`: forking a process with a live Swift/ObjC
runtime, GCD queues and CoreFoundation is genuinely unsafe — only
async-signal-safe calls are legal between fork and exec, and the Swift runtime
is not one.

### Docker → the daemon socket, not the `docker` CLI

Two reasons beyond the usual. A GUI app does not inherit the shell's
environment, so a Docker Desktop install that works perfectly in Terminal is
invisible to an app that spawns `/usr/bin/env docker` — this sidesteps an entire
class of "works in my terminal" bug report. And `docker ps` output is formatted
for humans and its columns shift, while the Engine API returns documented,
versioned JSON.

`URLSession` cannot open an `AF_UNIX` socket, so this is ~100 lines of
`connect`/`write`/`read` plus a chunked-transfer decoder — smaller and more
auditable than the dependency would have been.

### Secrets → Keychain, `AfterFirstUnlockThisDeviceOnly`

LLM API keys never touch `UserDefaults`, a plist, or the settings JSON.
`SettingsData` stores only the provider enum; the key is fetched at the moment
of the request. `ThisDeviceOnly` means the key never syncs to another Mac via
iCloud Keychain or Migration Assistant, and `AfterFirstUnlock` means background
work still functions while the screen is locked.

There is a test asserting that an encoded `SettingsData` contains no
secret-shaped material, because that is the kind of rule that regresses quietly.

---

## The CLI approval feature

When a CLI agent blocks waiting for permission, the notch shows a badge;
clicking it expands to the prompt with Approve / Deny / Always-allow; your
answer goes back to the waiting process.

It is built as a **generalised primitive**, not a Claude Code integration.
`PendingApproval` carries a source, a tool name, a prompt, optional detail and a
responder closure. Any blocking CLI can be taught to produce one without the UI
or the arbiter learning anything new.

Three transports, in the priority order the brief specifies:

### 1. Hook — primary, exact

```
claude ──PreToolUse──▶ nb-approve ──┐
                                     │ JSON over a unix socket
                                     ▼
                        ~/.notchbuddy/approval.sock
                                     │
                          badge appears in the notch
                                     │
                            you click Approve
                                     │
                     hook prints the decision, exits ──▶ claude proceeds
```

The hook process sits in a **blocking read**. No timer, no polling, no busy
loop — it is descheduled entirely until we reply.

**A unix domain socket, not a loopback TCP port.** A loopback port is reachable
by every process and every user on the machine, and by anything that can make a
browser issue a request. A unix socket is a filesystem object protected by file
permissions — created at `0600` inside a `0700` directory. Given that the
question being answered is *"may this agent run this shell command"*, that
difference matters a great deal.

The bridge script is **generated, not shipped as an opaque binary**, so the
socket path is always right for your user and so you can read the whole thing —
it is 20 lines of `sh` — before wiring it into a tool that runs commands on your
machine. If NotchBuddy is not running it exits 0 immediately (measured: 31ms),
so your agent never hangs because a UI app was closed.

We print the `settings.json` snippet with a copy button rather than editing
`~/.claude/settings.json` for you. Writing into another tool's config behind
your back is exactly what you should not accept from a utility app.

```sh
./Scripts/install-hook.sh      # prints the snippet; changes nothing
```

### 2. Owned pty — preferred over log watching

When you run the agent inside NotchBuddy's own Terminal tab, we are on both
ends: we see the byte stream with no screen scraping and no Accessibility
permission, and the response is a `write()` into the pty the process is already
reading from — no synthetic keystrokes, no focus stealing, works even when the
panel is not frontmost.

Detection here is still *pattern-based* and the UI labels it "best-effort". Its
advantage over transport 3 is the reliable response channel, not better
detection.

### 3. Log tailing — last resort, off by default

You cannot read another process's file descriptors on macOS; the approaches that
appear to work need SIP disabled or root. So this tails a file you pipe your
session to (`claude 2>&1 | tee ~/agent.log`), using
`DispatchSourceFileSystemObject` rather than a `stat` loop, reading only newly
appended bytes.

[`ApprovalPatterns.swift`](Sources/NotchBuddy/Features/Approval/ApprovalPatterns.swift)
is isolated, logic-free, and carries a prominent warning: matching a CLI's
prompt by looking at its output is inherently unstable, because wording and
box-drawing are presentation details that authors change freely. Updating it
after a CLI changes its output should be a one-file, no-thinking edit.

The badge is the notification. We never steal focus or force the panel open —
that is the behaviour that makes notch apps annoying.

---

## What's in the app

**Tier 1 (collapsed):** battery · Now Playing · running timers · agent-approval
badge · optional compact system stats

**Tier 2 (tabs):** Home (customisable widget grid) · Time (multiple named
timers, alarms with weekday repeats, Pomodoro, stopwatch) · Snippets (clipboard
history + saved snippets + pinned, one store) · Notes · Calendar · Files
(image/format converter) · API Tester · Docker · Terminal · AI Chat · Message
(flash-across-the-notch) · Settings

**Home widgets:** Screen Time (with 7-day chart and per-app drill-in) · Weather
· Sound & Light · Launch shortcuts · CPU/RAM/Disk rings · custom metric from any
JSON endpoint

**Not tabs:** selection-aware Explain/Rewrite/Translate (global, Accessibility)
· Teleprompter (separate always-on-top window, hidden from screen recording by
default)

**Cross-cutting:** three themes (Minimal / Playful / Neon) · launch at login ·
global hotkey · per-window hide-from-screen-recording · battery-saver switch
with live diagnostics · config-driven custom tabs

**Deliberately excluded:** currency converter, world clock.

---

## What leaves your Mac

- Your own LLM requests, to the provider you configured with your own key.
- Weather: a latitude/longitude **rounded to two decimal places (~1.1km)**
  before it leaves the process, sent to open-meteo.com, and only while the Home
  tab is open.
- Anything you explicitly send from the API Tester or a custom-metric tab.
- **Nothing else.** No analytics, no crash reporting, no update pings, no
  account.

Settings → About lists this in the app, alongside which platform capabilities
actually resolved on your system — including the ones that did not.

---

## Documentation

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, module map, data flow, lifecycles |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | Full method, raw numbers, how to reproduce |
| [docs/decisions/](docs/decisions/) | Architecture decision records — what was chosen, what was rejected, and why |
| [docs/learning/](docs/learning/) | Knowledge-transfer guides for developers joining the codebase |

If you are new to this repo, start with
[docs/learning/01-orientation.md](docs/learning/01-orientation.md).

---

## Project layout

```
Sources/NotchBuddy/
  Core/         panel, geometry, polling hub, arbiter, settings, theme, motion
  Tier1/        battery, now playing, system stats, collapsed pill
  Tier2/        expanded panel, tab registry, Tabs/*
  Features/
    Approval/   the waiting-on-approval primitive + three transports
    Terminal/   pty, VT100 emulator, session, renderer
    Time/       timers, alarms, pomodoro, stopwatch
    Snippets/   unified store + clipboard watcher
    LLM/        shared streaming client
    Selection/  AX-driven selection assist
    Widgets/    screen time, weather, sound & light, metrics
    Docker/ Files/ Message/ Teleprompter/
  Support/      logging, JSON store, Keychain
Tests/          55 tests (swift-testing)
Scripts/        build-app.sh · test.sh · bench-idle.sh · install-hook.sh
```

## Status

Built to the brief in one pass. The foundation (two-tier model, polling hub,
arbitration) and the tabs the brief asked to prioritise — system stats,
Timers/Alarms, Clipboard/Snippets — are solid and tested. The remaining tabs
follow the same established patterns.

Known limitations are documented rather than hidden:
[docs/learning/06-known-limitations.md](docs/learning/06-known-limitations.md).

## License

MIT

# Architecture

This document explains how NotchBuddy is put together and, more importantly,
*why* the seams fall where they do. If you are about to add a feature, read
[the lifecycle contract](#the-lifecycle-contract) first — it is the rule that
most new code gets wrong.

---

## 1. The single design driver

Every app in this category gets the same complaint: idle CPU, RAM and battery
drain. That complaint is the design driver here, and it **overrides feature
convenience whenever the two conflict**.

Concretely, that means a feature is allowed to be less convenient to implement
if the convenient version would cost something while nobody is looking at it.
Several things in this codebase are more work than they needed to be for exactly
that reason — the polling hub, the hand-rolled VT100 emulator, the per-tab
teardown discipline, the `dlopen` of MediaRemote.

---

## 2. Process shape

One process. No helper apps, no XPC services, no login-item helper.

```
NotchBuddy (LSUIElement, .accessory activation policy)
│
├── NotchPanel            the notch surface — created once, never recreated
├── NSStatusItem          menu-bar fallback: open, teleprompter, settings, quit
├── TeleprompterWindow    separate always-on-top window, own lifetime
├── FlashMessage window   click-through banner across the top of the display
├── SelectionActionWindow small popover beside a text selection
│
└── child processes
    └── /bin/zsh -l       only while the Terminal tab is open, on a pty
```

The panel is an `NSPanel` with `[.borderless, .nonactivatingPanel]` at
`.statusBar` level, `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
Each of those is load-bearing and the reasoning is in
[`NotchPanel.swift`](../Sources/NotchBuddy/Core/NotchPanel.swift).

The panel is **resized and repositioned, never destroyed and recreated**.
Recreating it on every hover would mean a window-server round trip, a fresh
backing-store allocation and a layer-tree rebuild several times a minute, for a
window whose content is already in memory.

---

## 3. The two-tier content model

```
┌─────────────────────────────────────────────────────────────┐
│ TIER 1 — collapsed pill                                     │
│ always present · must cost ~nothing · event-driven only     │
│                                                             │
│   BatteryMonitor      IOKit power-source run-loop source    │
│   NowPlayingMonitor   MediaRemote notification (dlopen'd)   │
│   TimeEngine          absolute deadlines + one-shot wakeups │
│   ApprovalCenter      pushed to by the transports           │
│   SystemStats         the ONE exception: hub-registered,    │
│                       and only while "attended"             │
└─────────────────────────────────────────────────────────────┘
                              ▲
                              │  claims
                              │
                  ┌───────────────────────┐
                  │     NotchArbiter      │  decides what the pill shows
                  └───────────────────────┘
                              │
┌─────────────────────────────────────────────────────────────┐
│ TIER 2 — expanded panel                                     │
│ instantiate on open · TEAR DOWN on close                    │
│                                                             │
│   Home · Time · Snippets · Notes · Calendar · Files ·       │
│   API · Docker · Terminal · AI Chat · Message · Settings    │
│   + user-configured custom tabs                             │
└─────────────────────────────────────────────────────────────┘
```

**The rule:** nothing outside Tier 1's handful of items may poll, render, or
hold retained state while the user is not looking at it.

Note what Tier 1 does *not* contain: any repeating timer except the stats
sampler, which is itself gated on the panel being attended. Battery, Now Playing
and app-usage tracking are pure notification handlers. They stay live while
collapsed because they are free.

---

## 4. The polling hub

[`WidgetPollingHub`](../Sources/NotchBuddy/Core/WidgetPollingHub.swift)

**No widget in this app is permitted to own a `Timer`.** This is the single
most important invariant in the codebase.

### Why

The naive structure is ten widgets, ten timers, ten independent scheduler
wakeups. On Apple Silicon the cost is the *wakeup*, not the work in the
callback: a core pulled out of an idle state costs roughly the same whether the
callback does one thing or nothing. `powermetrics` treats "wakeups per second"
as a first-class metric for exactly this reason.

### How

```
 widget A  register(interval: 1.0) ─┐
 widget B  register(interval: 2.0) ─┼──▶  one DispatchSourceTimer
 widget C  register(interval: 5.0) ─┘     tick = gcd(1,2,5) = 1.0s
                                          leeway = 25% of tick
                                              │
                          fires each registration when its
                          own interval has elapsed
```

Three details that matter more than they look:

**GCD, quantised to 250ms.** A raw GCD over `[0.75, 2.0]` is `0.25`. Over
`[1/3, 2]` it approaches zero. Quantising to quarter-seconds and flooring at
250ms means no combination of registered intervals can produce a pathological
tick rate.

**25% leeway.** This is arguably the single highest-leverage line in the file.
Leeway lets the kernel coalesce our wakeup with one it was going to perform
anyway. Nothing here needs millisecond precision — it is a CPU gauge and a
countdown label.

**`setActive(false)` cancels the source.** It does not set a flag and keep
ticking. When the panel is collapsed and unpinned, the process has no scheduled
widget work at all.

### The one caller

```swift
// NotchPanelController.updateHubActivation()
let attended = (state == .expanded) || (isPinned && s.pinnedCountsAsAttended)
WidgetPollingHub.shared.setActive(attended || !s.batterySaver)
```

That is the **only** call to `setActive` in the codebase. Centralising it is
what makes the power behaviour auditable instead of emergent — you can verify
the whole claim by reading one method.

`diagnostics()` exposes the live registration list to Settings → Power, so a
user can check it without reading the source.

---

## 5. The lifecycle contract

**Read this before adding a tab or a widget.**

Every tab and every widget that holds a resource follows the same two-line
pattern:

```swift
.onAppear  { thing.activate()   }   // register with the hub, open sockets, allocate
.onDisappear { thing.deactivate() } // unregister, close, release
```

This works — and is hard to get wrong — because
[`ExpandedPanelView`](../Sources/NotchBuddy/Tier2/ExpandedPanelView.swift)
builds **only the selected tab**:

```swift
switch controller.activeTab {
case .builtin(let id): builtinTab(id).id(id)   // ← .id() forces rebuild
...
}
```

Not a `TabView` (keeps every page alive). Not a `ZStack` of hidden views. A
`switch` inside a `Group`, so SwiftUI destroys the previous tab's view tree and
fires its `.onDisappear`.

The consequence: forgetting to clean up requires actively omitting the
`.onDisappear`, and there is exactly one place per tab to look.

### Things that must be torn down, and are

| Resource | Owner | Released in |
|---|---|---|
| Polling-hub registration | every polling widget | `deactivate()` / `removeConsumer()` |
| `EKEventStore` + its daemon connection | `CalendarService` | `deactivate()` |
| pty + `/bin/zsh` process group | `TerminalSession` | `stop()` (honours keep-alive setting) |
| `WKWebView` content process | `CustomWebTab` | `dismantleNSView` |
| CoreAudio property listener | `SoundLightController` | `deactivate()` |
| In-flight `URLSession` tasks | Weather, Metric, API, LLM | `cancel()` on disappear |
| `AXObserver` run-loop source | `SelectionWatcher` | `disarm()` |

Refcounting is used where two consumers can want the same resource — the
collapsed pill and the Home rings both want `SystemStats`, so it counts
consumers and only unregisters when the last one leaves.

---

## 6. Notch arbitration

[`NotchArbiter`](../Sources/NotchBuddy/Core/NotchArbiter.swift)

Subsystems do not write to the pill. They submit **claims**, keyed by id so a
monitor can re-assert idempotently on every event without diffing anything
itself. An identical re-claim is dropped, which stops a notification storm from
becoming a SwiftUI invalidation storm.

| Priority | Examples | Behaviour |
|---|---|---|
| `.persistent` | running timer, blocked CLI | **holds** the pill until withdrawn |
| `.transient` | "Copied", "Converted 3 files" | one rotating slot, newest wins, TTL |
| `.ambient` | battery, stats, now playing | the floor |

- A transient **overlays** a persistent claim rather than replacing it in the
  model, so when it expires the persistent claim reappears with no bookkeeping.
- Transients never stack or queue. A queue would mean a burst of five copies
  makes the notch unusable for ten seconds.
- Among equal-priority persistent claims, **lowest `rank` wins**. Timers set
  `rank = secondsRemaining`, producing "closest to completion" without the
  arbiter knowing what a timer is. The approval badge sets `rank = 0`, because
  nothing is more urgent than a process stopped dead waiting for you.
- `allPersistent` exposes every one of them, which the expanded header renders —
  satisfying the requirement that all active persistent items are visible on
  expand, not just the winner.

---

## 7. Data flow

```
                    ┌──────────────┐
  user action ─────▶│  SwiftUI     │
                    │  view        │
                    └──────┬───────┘
                           │ calls
                    ┌──────▼───────┐
                    │  Store /     │  @MainActor ObservableObject
                    │  Engine      │  (SnippetStore, TimeEngine, ...)
                    └──┬────────┬──┘
                       │        │
          debounced    │        │  claims
          JSON write   │        ▼
                       │   ┌─────────────┐      ┌──────────────┐
                       │   │ NotchArbiter│─────▶│ collapsed    │
                       │   └─────────────┘      │ pill         │
                       ▼                        └──────────────┘
    ~/Library/Application Support/NotchBuddy/*.json
```

### Persistence

[`JSONStore<T>`](../Sources/NotchBuddy/Support/JSONStore.swift) — a debounced,
atomic, off-main-thread JSON file per domain.

Not SQLite, not Core Data. The largest collection in this app is clipboard
history, capped at a few hundred rows — kilobytes. A database engine's
connection, page cache and background threads would cost more RAM than the data
does, and a Core Data stack would keep a persistent container and a managed
object context resident for the whole process lifetime, for data that is only
read when a tab is open.

Writes are debounced (0.4–5s depending on domain) and coalesced, moved to a
utility queue, and written with `.atomic` so a crash mid-write cannot truncate.
`applicationWillTerminate` hard-flushes every store, because a pending 1.5s
write must not be lost because the user quit 200ms after typing.

Files: `settings.json`, `snippets.json`, `time.json`, `notes.json`,
`screentime.json`, `api-requests.json`, `teleprompter.json`.

### Secrets

Never in those files. `Keychain` with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, fetched at the moment of the
request. `SettingsData` stores only the provider enum. There is a test asserting
the encoded settings contain no secret-shaped material.

---

## 8. Concurrency model

Swift 5 language mode, `@MainActor` on anything that owns UI-facing state.

Work leaves the main actor in exactly four places, all of them genuinely
blocking or CPU-bound:

| Work | Where it runs | Why |
|---|---|---|
| JSON encode + file write | utility `DispatchQueue` | disk IO |
| Image conversion | utility `DispatchQueue`, **sequential** | CPU-bound; parallel batches spike memory into GB |
| Docker socket IO | `userInitiated` queue via continuation | blocking `read`/`write` on AF_UNIX |
| pty reads | `userInitiated` `DispatchSourceRead` | continuous stream; hops to main to feed the emulator |
| Approval socket accept/handle | dedicated serial queue | a hung client must not block the accept loop |

Callbacks from C APIs (IOKit, CoreAudio, Accessibility, Carbon) are bare
function pointers with a `void *` context. Each trampolines through an
unretained pointer to a singleton, which is safe because the singleton outlives
the source by construction. `MainActor.assumeIsolated` is used — rather than a
`Task` hop — where a `DispatchSource` is already scheduled on `.main` and an
async hop would let a frame render with stale state.

---

## 9. The approval subsystem

The one feature whose *interface* was designed before its implementations.

```
        ┌──────────────────────────────────────────┐
        │            PendingApproval               │
        │  source · toolName · prompt · detail     │
        │  respond: (ApprovalDecision) -> Void     │
        └──────────────────────────────────────────┘
             ▲              ▲                 ▲
   ┌─────────┴───┐  ┌───────┴────────┐  ┌────┴──────────────┐
   │ HookServer  │  │ OwnedPTY       │  │ StdoutLogWatcher  │
   │ unix socket │  │ Detector       │  │ FSEvents on a log │
   │ EXACT       │  │ pattern+pty    │  │ pattern only      │
   └─────────────┘  └────────────────┘  └───────────────────┘
             │              │                 │
             └──────────────┼─────────────────┘
                            ▼
                    ┌───────────────┐
                    │ApprovalCenter │ ← applies always-allow rules first
                    └───────┬───────┘
                            │ persistent claim, rank 0
                            ▼
                    NotchArbiter → pill badge → ApprovalView
```

The UI **never branches on transport**. Transport affects only (a) how the
response is routed back and (b) a confidence label shown to the user, because a
"best-effort" pattern match deserves a closer look before you click Approve.

Adding a fourth transport means constructing a `PendingApproval` with an
appropriate `respond` closure. Nothing else changes.

Detail per transport is in the README and in each file's header comment.

---

## 10. Terminal rendering

The most performance-sensitive surface in the app, and the one where the obvious
SwiftUI approach fails hardest.

A 100×28 grid is 2,800 cells. A view per cell — or even per styled run — means
diffing thousands of view identities on every frame of output from a chatty
build. Instead:

- **`Canvas`**, one drawing pass, no view tree.
- Cells are **grouped into runs of identical styling** before drawing, so a line
  of plain text is one `draw` call rather than 100.
- Backgrounds are painted only when non-default; painting black on black for
  every cell doubles the draw calls for nothing.
- The emulator is a **plain class**, not `@Published` per mutation. It exposes a
  `generation` counter, and the `Canvas` observes only that.
- Redraws are **coalesced to 30fps** while the model is fed immediately, so
  output stays correct while rendering stays bounded.

Scrollback is hard-capped at 2,000 lines. A terminal with unlimited history is a
memory leak with a user interface — `cat bigfile` would grow the process without
bound.

---

## 11. Module map

| Path | Responsibility |
|---|---|
| `Core/NotchPanel` | the `NSPanel` subclass and its style decisions |
| `Core/ScreenGeometry` | notch detection and panel placement |
| `Core/NotchPanelController` | collapsed/expanded state machine; **only** caller of `setActive` |
| `Core/WidgetPollingHub` | the one timer |
| `Core/NotchArbiter` | pill contention |
| `Core/Settings` | the persisted config model (no secrets) |
| `Core/Theme` · `Core/Motion` | visual and animation vocabulary |
| `Core/HotKeyCenter` · `Core/LaunchAtLogin` | system integration |
| `Core/AppDelegate` · `Core/main` | lifecycle and startup ordering |
| `Tier1/*` | event-driven monitors + the collapsed pill view |
| `Tier2/ExpandedPanelView` | tab host; enforces teardown via the view lifecycle |
| `Tier2/Tabs/*` | one file per tab |
| `Features/Approval/*` | the approval primitive and its three transports |
| `Features/Terminal/*` | pty, VT100 emulator, session, `Canvas` renderer |
| `Features/Time/TimeEngine` | timers, alarms, pomodoro, stopwatch |
| `Features/Snippets/*` | the unified store + clipboard watcher |
| `Features/LLM/LLMClient` | shared streaming client |
| `Features/Selection/*` | AX-driven selection assist |
| `Features/Widgets/*` | screen time, weather, sound & light, metrics |
| `Support/*` | logging, JSON store, Keychain |

---

## 12. Extension points

**A new tab.** Add a `TabID` case (string-backed — the raw value is persisted),
a `switch` arm in `ExpandedPanelView.builtinTab`, and a view with the
`.onAppear`/`.onDisappear` pair. If it polls, register with the hub; never
create a `Timer`.

**A new Home widget.** Add a `HomeWidgetKind` case and a `switch` arm in
`HomeTabView.widget`. Same lifecycle rule.

**A new Tier-1 item.** Publish a `PillClaim` with the right priority and rank.
Do not touch the pill view. If it needs a timer, ask hard whether an
event-driven API exists first — the answer is yes more often than people expect.

**A new approval transport.** Construct a `PendingApproval` with a `respond`
closure. Nothing in the UI changes.

**A new LLM provider.** Add an `LLMProvider` case and a branch in `buildRequest`
and `parseStreamChunk`. Nothing else is vendor-aware.

**A new custom-tab type.** Add a `CustomTabKind` case, a `switch` arm in
`CustomTabView`, and configuration fields on `CustomTabConfig`. Note that custom
tabs are *configuration, never code* — see
[ADR 0010](decisions/0010-config-driven-custom-tabs.md).

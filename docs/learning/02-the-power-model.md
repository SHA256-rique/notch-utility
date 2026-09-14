# 02 — The power model

**This is the document to read before writing any feature.** Almost every review
comment on this codebase traces back to it.

---

## The claim

Collapsed and idle, this app uses **0.0004% of one core and 0.9 wakeups per
second**, and 0.7 of those 0.9 are the clipboard watcher. Turn clipboard capture
off and the entire app costs 0.2 wakeups/sec, which is AppKit's own floor.

That number is not the result of optimisation. It is the result of an
architecture where *there is nothing to optimise* — while collapsed, almost
nothing is scheduled to run.

## The one invariant

> **No widget may own a `Timer`. Anything periodic registers with
> `WidgetPollingHub`, which the panel controller switches off when the panel is
> not being looked at.**

If you internalise one thing, make it that.

## Why wakeups, not CPU%

On Apple Silicon, the cost of a periodic task is dominated by the **wakeup**,
not by the work inside the callback. Pulling a core out of an idle state costs
roughly the same whether the callback does one thing or nothing at all.

So this:

```swift
// Ten widgets, each doing "almost nothing", on their own timers.
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    self.value = readOneInteger()     // trivially cheap!
}
```

is **not** cheap. It is ten wakeups per second. The callback's cost is
irrelevant; the scheduling is the cost. `powermetrics` reports wakeups/sec as a
first-class metric for exactly this reason, and it is much harder to game than
CPU% — an app can look excellent on CPU% by doing tiny amounts of work very
often, which is precisely the pattern that ruins battery life.

## How the hub works

```
 widget A  register(interval: 1.0) ─┐
 widget B  register(interval: 2.0) ─┼──▶  ONE DispatchSourceTimer
 widget C  register(interval: 5.0) ─┘     tick = gcd(1,2,5) = 1.0s
                                          leeway = 25%
```

Each registration is invoked when *its own* interval has elapsed. Ten widgets
produce one wakeup per second, not ten.

Three details that are load-bearing:

**Quantisation to 250ms.** A raw GCD of `[0.75, 2.0]` is `0.25`. Of `[1/3, 2]`,
it approaches zero. Intervals are quantised to quarter-seconds and floored, so
no combination can produce a pathological tick rate.

**25% leeway.** Probably the highest-leverage line in the file. Leeway lets the
kernel coalesce our wakeup with one it was already going to perform. Nothing
here needs millisecond precision — it is a CPU gauge and a countdown label.

**`setActive(false)` cancels the source.** Not "sets a flag and keeps ticking".
The source is destroyed. There is genuinely nothing scheduled.

## The one place background work is enabled

```swift
// NotchPanelController.updateHubActivation() — the ONLY caller of setActive.
let attended = (state == .expanded) || (isPinned && s.pinnedCountsAsAttended)
WidgetPollingHub.shared.setActive(attended || !s.batterySaver)
```

That is the entire power policy. You can verify the app's headline claim by
reading one method, which is the point. **Do not add a second caller.** If you
need the hub active in a new situation, extend the definition of "attended"
here.

## Prefer event-driven, always

Before adding a hub registration, ask whether macOS already has a notification.
It does more often than people expect:

| Instead of polling | Use |
|---|---|
| battery percentage | `IOPSNotificationCreateRunLoopSource` |
| low power mode | `NSProcessInfoPowerStateDidChange` |
| now playing | MediaRemote's change notification |
| frontmost app | `NSWorkspace.didActivateApplicationNotification` |
| sleep / wake | `NSWorkspace.willSleep` / `didWake` |
| screen lock | `com.apple.screenIsLocked` (distributed) |
| selected text | `AXObserver` + `kAXSelectedTextChangedNotification` |
| a file changing | `DispatchSourceFileSystemObject` |
| system volume | `AudioObjectAddPropertyListener` |
| calendar changes | `.EKEventStoreChanged` |

Every one of those is used in this codebase, and every one replaced a poll loop
that the naive implementation would have had.

## The one place we do poll, and why we admit it

`ClipboardWatcher` polls `NSPasteboard.changeCount` at 1.2s. macOS has never
offered a pasteboard-change notification, so every clipboard manager on the
platform polls.

What makes it acceptable is *what* is polled. `changeCount` is a single
monotonic integer maintained by the pasteboard server. Reading it does **not**
deserialise the pasteboard contents.

The version that seems equivalent and is not:

```swift
// WRONG: forces the OWNING app to re-render its data on every poll.
if let text = NSPasteboard.general.string(forType: .string) { ... }
```

`string(forType:)` asks the application that owns the pasteboard to produce its
data in that type. Poll a 20MB image at 1Hz that way and you make some other app
do real work 3,600 times an hour.

It is also exempt from the hub — clipboard history that only records while you
are hovering the notch is useless — and so its cost is *included* in the
published idle figure rather than hidden from it. That is why the benchmark
table has a "clipboard off" row.

## Teardown is enforced by the view lifecycle

`ExpandedPanelView` builds **only** the selected tab: a `switch` in a `Group`,
never a `TabView` (keeps every page alive), never hidden views. SwiftUI destroys
the previous tab's tree on switch and fires `.onDisappear`.

So every resource-holding tab looks like:

```swift
.onAppear    { thing.activate() }
.onDisappear { thing.deactivate() }
```

and forgetting to clean up requires actively omitting the second line.

**Do not put teardown in `deinit`.** SwiftUI view lifetimes are not what you
expect, `@StateObject` deinit timing is not guaranteed to be prompt, and the
resource may outlive the moment it should have been released.

**Do not defer teardown to app quit.** The whole point is that a closed tab
costs nothing *while the app keeps running*.

## The checklist for a new feature

- [ ] Is there an event-driven API for this? Look harder before answering no.
- [ ] If it must poll, is it registered with the hub? (Not a `Timer`.)
- [ ] Is the registration released in `.onDisappear`?
- [ ] Is every other resource released too — socket, watcher, task, buffer?
- [ ] Does it show up in Settings → Power while active, and vanish after close?
- [ ] Did you run `bench-idle.sh` collapsed before and after? Did wakeups move?

That last one is the real test. If the collapsed number changed, something is
running that should not be.

## How to catch a leak

```sh
open dist/NotchBuddy.app --args --bench-tab yourtab
./Scripts/bench-idle.sh 10 2          # expanded cost
# now collapse the panel (Esc, or click the x), then:
./Scripts/bench-idle.sh 10 2          # must return to ~0.9 wakeups/s, ~13.6MB
```

Footprint that does not come back down, or wakeups that stay elevated, means
something did not tear down. That is the failure this architecture exists to
prevent, and it is the highest-value thing to check before merging.

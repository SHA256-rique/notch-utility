# 04 — Where SwiftUI meets AppKit

This app is AppKit at the window layer and SwiftUI inside. Most of the sharp
edges are at that boundary.

---

## Why the split

SwiftUI's `App` protocol wants to own window creation. The central object here
is an `NSPanel` with a borderless non-activating style mask, `.statusBar` level,
a custom collection behaviour and a runtime-toggled `sharingType`. `WindowGroup`
exposes almost none of that, and `MenuBarExtra` — the nearest equivalent —
produces a status-item popover that cannot be positioned under the notch.

So: AppKit owns lifecycle and windows, SwiftUI owns content inside
`NSHostingView`. See [ADR 0006](../decisions/0006-appkit-lifecycle-over-swiftui-app.md).

---

## Traps at the boundary

### `NSApplication` does not retain its delegate

```swift
let delegate = AppDelegate()
application.delegate = delegate   // weak!
application.run()
```

In `main.swift` top-level code, the local is the only strong reference, and it
can be released. Keep an explicit static reference. This produces bewildering
"my delegate methods stopped firing" behaviour.

### `main.swift` top-level code is nonisolated

`AppDelegate` is `@MainActor`, so constructing it from top-level code is an
isolation error. The right answer is `MainActor.assumeIsolated` — this *is* the
main thread, and it is the process entry point:

```swift
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    AppDelegate.retain(delegate)
    application.delegate = delegate
}
application.run()
```

An async `Task` hop would let the run loop start before the delegate is
installed.

### Hover needs `contentShape`

A mostly-transparent SwiftUI view has no hit area over its transparent pixels.
`.onHover` will fire only over drawn content, which makes the notch feel broken.

```swift
.contentShape(Rectangle())
.onHover { controller.hoverChanged($0) }
```

### Hover must be debounced in *both* directions

Expanding on the raw event fires every time the cursor crosses the top of the
screen on its way to a menu. Collapsing on the raw event makes the panel flicker
shut when the cursor grazes the gap between two tab buttons.

Both directions get a `DispatchWorkItem` that the opposite event cancels.
Defaults: 0.18s to open, 0.45s to close.

### Raw key events need an NSView

SwiftUI cannot receive arrow keys, control characters or `performKeyEquivalent`
inside a non-activating panel. The terminal uses a zero-size
`NSViewRepresentable` whose only job is to be first responder and forward
`NSEvent`s.

Re-take first responder in `updateNSView` — after a tab switch the view is
rebuilt and loses it:

```swift
DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
```

`performKeyEquivalent` must be overridden separately: ⌘V and friends are
swallowed by the responder chain before `keyDown` sees them.

### `dismantleNSView` is where NSViewRepresentable cleanup goes

```swift
static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
    nsView.stopLoading()
    nsView.loadHTMLString("", baseURL: nil)
}
```

A `WKWebView` that is merely released keeps its content process — tens of
megabytes plus its own timers — alive longer than you expect. Stop it explicitly.

---

## SwiftUI patterns that matter here

### `switch`, not `TabView`

```swift
switch controller.activeTab {
case .builtin(let id): builtinTab(id).id(id)
...
}
```

`TabView` keeps every page alive. A `ZStack` of views at opacity 0 keeps every
page alive. A `switch` in a `Group` destroys the previous tree and fires
`.onDisappear`, which is where every teardown in this app lives. The `.id()`
forces a rebuild across switches rather than letting SwiftUI reuse the tree.

This is not a style preference. It is what makes the power model enforceable.

### Do not make a hot model `@Published` per mutation

The terminal emulator is a plain class. Publishing on every cell write during a
build's output would invalidate SwiftUI thousands of times a second.

Instead it exposes a `generation` counter, bumped once per feed, and the
renderer observes only that — with redraws coalesced to 30fps.

### `Canvas` for dense grids

A 100×28 terminal is 2,800 cells. A view per cell — or even per styled run —
means diffing thousands of view identities per frame. `Canvas` draws into one
context with no view tree.

Group cells into runs of identical styling first, so a line of plain text is one
`draw` call rather than 100. Skip the background fill when it is the default;
painting black over black for every cell doubles the draw calls for nothing.

### Idempotent published updates

Tier-1 monitors re-assert their state on every event. Without a guard, a
notification burst becomes a SwiftUI invalidation burst:

```swift
guard next != state else { return }   // do not invalidate for a no-op
state = next
```

`NotchArbiter` does the same for claims. This pattern is everywhere in `Tier1/`
and it is deliberate.

### `@StateObject` vs `@ObservedObject`

`@StateObject` for something the view owns and whose lifetime should match the
view (`CalendarService`, `MetricFetcher`, `APITesterModel`). `@ObservedObject`
for a singleton the view merely watches (`SnippetStore.shared`,
`TimeEngine.shared`).

Getting this backwards on a singleton is mostly harmless; getting it backwards
on a per-view model means the object is recreated on every render.

---

## C interop patterns

Several APIs here take a bare C function pointer plus a `void *` context.
Callbacks cannot capture, so the shape is always:

```swift
let context = Unmanaged.passUnretained(self).toOpaque()

SomeAPICreate({ ctx in
    guard let ctx else { return }
    let me = Unmanaged<MyClass>.fromOpaque(ctx).takeUnretainedValue()
    DispatchQueue.main.async { me.handle() }
}, context)
```

`passUnretained` is safe **only** because every owner here is a singleton that
outlives the source. If you apply this pattern to a non-singleton, use
`passRetained` and balance it in the cancel handler.

For `dlsym` results:

```swift
private typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
let fn = unsafeBitCast(symbol, to: Fn.self)
```

Get the signature wrong and you get memory corruption, not a type error. Check
the header.

---

## Concurrency notes

Swift 5 language mode. `@MainActor` on anything owning UI-facing state.

**`MainActor.assumeIsolated` vs `Task { @MainActor in }`.** When a
`DispatchSource` is already scheduled on `.main`, `assumeIsolated` is correct and
synchronous. A `Task` hop defers to the next runloop turn, which for a timer
firing means a frame can render with stale state — visible as a countdown that
shows `0:00` for one frame before disappearing.

**Pure statics on `@MainActor` types should be `nonisolated`.**
`TimeEngine.format`, `MetricFetcher.value(at:in:)` and
`OwnedPTYDetector.stripANSI` are pure functions that were isolated only by
accident of living on an isolated type. Marking them `nonisolated` is correct
independently of the tests that surfaced it.

**Closures crossing a queue boundary need `@Sendable`.** A `@MainActor` class is
implicitly `Sendable`, so `[weak self]` capture is fine — it is the closure
*annotation* that must be right.

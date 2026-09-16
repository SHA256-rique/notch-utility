# 01 — Orientation

## What this app is

A macOS menu-bar-less utility that draws a panel under the MacBook notch. It has
two states: a **collapsed pill** showing urgent glance info, and an **expanded
panel** with a tab bar of tools.

The interesting part is not the features. It is that the whole thing is
architected around one constraint — *it must cost approximately nothing while
you are not looking at it* — and that constraint shapes decisions you would
otherwise find strange.

If something in this codebase looks like more work than it needed to be, the
answer is almost always "because the easy version costs something at idle". See
[02-the-power-model.md](02-the-power-model.md).

## Build and run

You need macOS 14+ and Command Line Tools. **Not Xcode.**

```sh
./Scripts/build-app.sh release   # -> dist/NotchScotch.app
open dist/NotchScotch.app

./Scripts/test.sh                # 55 tests
./Scripts/bench-idle.sh 10 3     # idle benchmark; app must be running
```

For a fast iteration loop while working on non-UI logic:

```sh
swift build && ./Scripts/test.sh
```

You cannot meaningfully run the app from `swift build` alone — an accessory app
with TCC permissions needs the bundle and the ad-hoc signature. Use
`build-app.sh`.

### Seeing what it is doing

There is no `print` anywhere. Everything goes through `os.Logger`:

```sh
log stream --predicate 'subsystem == "com.notchscotch.app"' --level debug
```

Categories: `panel`, `pollinghub`, `tier1`, `tabs`, `approval`, `terminal`,
`llm`, `store`. `log stream` is instant; `log show` is slow, so prefer stream.

### Driving it without the UI

```sh
open dist/NotchScotch.app --args --bench-tab terminal
```

Opens and pins a tab at launch. Added for reproducible benchmarking, useful
whenever you need a specific tab open from a script.

## Where things live

```
Sources/NotchScotch/
  Core/        window, geometry, the polling hub, the arbiter, settings, theme
  Tier1/       always-on monitors + the collapsed pill
  Tier2/       the expanded panel + one file per tab
  Features/    the substantial subsystems
  Support/     logging, JSON persistence, Keychain
```

Four files carry most of the design. Read them first, in this order:

1. **`Core/WidgetPollingHub.swift`** — the invariant everything else obeys.
2. **`Core/NotchPanelController.swift`** — the state machine, and the only place
   that turns background work on.
3. **`Core/NotchArbiter.swift`** — what the pill shows and why.
4. **`Tier2/ExpandedPanelView.swift`** — how teardown is enforced by the view
   lifecycle rather than by discipline.

After those, `Features/Approval/` is the most interesting subsystem and
`Features/Terminal/` is the densest.

## House style

**Comments explain *why*, never *what*.** If a comment restates the code, delete
it. The comments that earn their place are the ones recording a decision, a
rejected alternative, or a trap. There are a lot of them, deliberately — this
codebase makes a lot of non-obvious choices.

**No `print`.** `os.Logger` only. It is lazy: the interpolation is not evaluated
unless someone is collecting, which matters on the hot paths.

**No `Timer` in a widget.** Ever. See [02](02-the-power-model.md).

**Every resource has a matching teardown**, and it lives in `.onDisappear`, not
in `deinit` and not at app quit.

**Secrets go to `Keychain`, never to `SettingsData`.** There is a test enforcing
this.

## Your first change

A good starter task: add a Home widget.

1. Add a case to `HomeWidgetKind` in `Core/Settings.swift` (display name,
   symbol, `isWide`).
2. Add a `switch` arm in `HomeTabView.widget(_:)`.
3. Write the widget view. If it needs periodic refresh, register with
   `WidgetPollingHub` in `.onAppear` and unregister in `.onDisappear`.

The picker in "Edit widgets" is driven by `HomeWidgetKind.allCases`, so it
appears automatically.

Then run `./Scripts/bench-idle.sh` with the Home tab open before and after your
change. If the wakeups-per-second number moved, understand why before you
proceed. That habit is the single most useful one to build here.

## A warning about the shape of this repo

This was built in one pass against a detailed brief. The foundation — two-tier
model, polling hub, arbitration — and the three tabs the brief asked to
prioritise (system stats, Time, Snippets) are solid and tested. The remaining
tabs follow the same patterns but have had less use.

[06-known-limitations.md](06-known-limitations.md) is an honest list. Read it
before you assume something is finished.

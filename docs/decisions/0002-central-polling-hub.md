# 0002 — One central polling hub, not N independent timers

**Status:** Accepted · **Date:** 2026-09-15

## Context

The app has a dozen widgets. Several want periodic refresh: system stats, a
countdown redraw, custom metrics. The natural object-oriented answer is that
each widget owns its own `Timer`, starts it in `onAppear` and invalidates it in
`onDisappear`.

## Decision

**No widget in this app may own a `Timer`.** Widgets register
`(interval, closure)` with `WidgetPollingHub`, which runs exactly one
`DispatchSourceTimer` at the GCD of all registered intervals.

## Why

**The cost is the wakeup, not the work.** On Apple Silicon, waking a core out of
an idle state costs roughly the same whether the callback does one thing or
nothing. Ten widgets on independent timers produce ten wakeups where one would
do. `powermetrics` reports wakeups per second as a first-class metric precisely
because it predicts battery impact better than CPU% does.

**It creates a single kill switch.** With N timers, "stop polling when
collapsed" is a rule every widget author must remember, and one that fails
silently when forgotten. With one hub, it is one method call — and there is
exactly one caller of it in the codebase
(`NotchPanelController.updateHubActivation`). The power guarantee becomes
something you can verify by reading one method rather than auditing twelve.

**It makes the claim inspectable.** `diagnostics()` returns the live
registration list, which Settings → Power renders. A user chasing battery drain
can see exactly what is scheduled instead of trusting a README.

**Leeway becomes free.** With one timer we can afford generous (25%) leeway so
the kernel coalesces our wakeup with one it was already performing. Applying
that per-widget would be error-prone and inconsistent.

## Alternatives considered

**N timers with a shared "should I run" flag.** Rejected: the timers still fire,
so the wakeups still happen. This is the version that looks like it works and
does not.

**`NSBackgroundActivityScheduler`.** Correct for deferrable maintenance work,
wrong for a 2-second UI gauge — it gives no interval guarantees.

**Combine `Timer.publish`.** Ergonomic, but each publisher is a real `Timer`
underneath. Same problem with nicer syntax.

**Ticking off `CADisplayLink`.** Ties widget refresh to the display refresh rate,
which is 120Hz for a CPU gauge that changes once every 2 seconds. Absurd.

## Costs we accepted

- **Intervals are quantised to 250ms** and effectively snapped to a GCD. A
  widget asking for 0.75s alongside one asking for 2s gets a 0.25s tick, which
  is why the quantum exists. Nothing in this app needs finer.
- **A slow callback delays its neighbours** — the hub dispatches serially on the
  main queue. Acceptable because callbacks read a counter or format a string;
  anything genuinely slow belongs on a queue of its own.
- **Registrations must be balanced.** A leaked token keeps the hub alive. This
  is mitigated by the view lifecycle (see ARCHITECTURE §5) and by refcounting
  for shared resources, and it is visible in the diagnostics view.

## Revisit if

A future feature genuinely needs sub-100ms periodic work. It should get its own
source with an explicit justification in code, not be forced through the hub.

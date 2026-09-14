# 0013 — Private APIs resolved via `dlopen`, never linked

**Status:** Accepted · **Date:** 2026-09-15

## Context

Two features have no public API and no acceptable public substitute:

- **Now Playing.** `MPNowPlayingInfoCenter` only *publishes* your own app's
  state. There has never been a public way to read what the system is playing.
  Every app in this category uses private `MediaRemote.framework`.
- **Display brightness.** There is no public setter.
  `IODisplaySetFloatParameter` works on Intel and external displays but returns
  nothing on Apple Silicon internal panels; `DisplayServices.framework` is
  private and is what actually works there.

## Decision

Resolve every private symbol at runtime with `dlopen`/`dlsym`. Never add a
private framework to `linkedFramework`. Degrade visibly when resolution fails.

## Why

**A link-time dependency on a private framework is how apps in this category die
after an OS update.** If the framework moves, is renamed, or is removed, the
dynamic linker fails and the app will not launch *at all* — not "the feature is
missing", but "the app is broken", with no way for the user to diagnose it.
`dlopen` returning `nil` is a branch we handle.

**Apple has already tightened one of these.** As of macOS 15.4,
`MRMediaRemoteGetNowPlayingInfo` is gated behind a private entitlement;
unentitled callers get nothing back. The code distinguishes "framework absent"
from "framework present but returning nothing on every call", and reports the
second as the entitlement case specifically.

**Graceful degradation has to be real, not theoretical.** When Now Playing is
unavailable, the pill omits the item — it does not show a broken placeholder.
When brightness is unavailable, the row is hidden — not a dead slider. Settings
→ About lists which capabilities resolved on *this* system, including the
failures, so a user can see why a feature is missing instead of filing a bug.

## The rule we follow

For anything private:

1. `dlopen` with `RTLD_LAZY`, checking the result.
2. `dlsym` each symbol, checking each result.
3. `unsafeBitCast` to a `@convention(c)` function type.
4. Publish an `isAvailable` flag the UI branches on.
5. Never let failure propagate as a crash or a silent no-op.

## What we refused to do

**No AppleScript fallback for Now Playing.** Driving Music.app or Spotify via
Apple Events would mean a permission prompt and per-app special-casing for a
cosmetic feature. The fallback is deliberately *nothing*, not something worse.

**No shelling out for brightness.** Same reasoning as
[ADR 0003](0003-darwin-apis-over-subprocesses.md).

**No private APIs for anything load-bearing.** Now Playing and brightness are
both nice-to-haves. Nothing the app depends on to function goes through a
private symbol.

## Costs

- These features may stop working on a future macOS with no warning. Accepted,
  because the failure mode is a missing widget rather than a broken app.
- Unavoidably ugly code: `unsafeBitCast` of a `dlsym` result to a C function
  pointer.
- It is not App Store distributable — already true for other reasons
  ([ADR 0012](0012-unsandboxed-with-hardened-runtime.md)).

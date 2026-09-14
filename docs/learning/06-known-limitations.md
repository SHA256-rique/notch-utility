# 06 — Known limitations

An honest list. Written so nobody has to rediscover these by filing a bug.

Ordered roughly by how likely you are to hit them.

---

## Platform limits we cannot fix

### Now Playing may not work at all

macOS 15.4 gated `MRMediaRemoteGetNowPlayingInfo` behind a private Apple
entitlement. On such systems the framework loads, the call returns nothing, and
the pill omits the item.

The code distinguishes "framework missing" from "framework present but always
empty" and reports the second as the entitlement case in Settings → About.

There is **no workaround** that is worth taking. AppleScripting Music.app or
Spotify would mean an Apple Events prompt plus per-app special-casing for a
cosmetic feature. The fallback is deliberately nothing.

### Brightness control is unavailable on some displays

No public API exists. We try `DisplayServices` (works on Apple Silicon internal
panels) then `IODisplaySetFloatParameter` (works on Intel and many external
displays). Where neither resolves, the brightness row is hidden rather than
shown as a dead slider.

Most affected: external displays over DisplayPort that do not expose DDC/CI
brightness.

### Selection assist does not work in every app

`kAXSelectedTextChangedNotification` is not implemented by every application.
Where it is missing, `AXObserverAddNotification` fails and the affordance never
appears in that app. This is normal and not a bug in NotchBuddy.

Electron apps and some Java apps are the usual gaps.

### You cannot read another process's stdout

The log-watching approval transport requires the user to pipe their session to a
file (`claude 2>&1 | tee ~/agent.log`). There is no supported way to attach to a
running process's file descriptors without disabling SIP or running as root.

This is why that transport is last-resort and off by default.

---

## Things that are incomplete

### The terminal emulator is partial

Documented in its own header and in
[ADR 0008](../decisions/0008-hand-rolled-terminal-emulator.md). Not implemented:

- sixel / iTerm2 inline graphics
- mouse reporting (so mouse-driven TUIs will not respond to clicks)
- double-width / double-height lines
- bracketed paste
- most DEC private modes beyond cursor visibility and alternate screen
- text selection in the rendered view (⌘C currently sends `^C`, which is what a
  user pressing it in a terminal usually wants, but it is a compromise)

`vim`, `htop` and `less` render and are usable; they are not pixel-correct.

### No universal binary

`swift build --arch arm64 --arch x86_64` fails under this toolchain.
`build-app.sh` detects that and falls back to the host architecture, printing
the fallback rather than hiding it. A real universal build needs two passes and
`lipo`. This is the most obvious next build-system task.

### No key recorder for the hotkey

Settings offers a fixed list of keys rather than "press your shortcut". A
recorder needs a `CGEventTap`, which needs Accessibility permission — the exact
permission [ADR 0014](../decisions/0014-carbon-hotkey-over-event-tap.md) exists
to avoid spending on a hotkey. A deliberately worse UI.

### Tab reordering is not implemented

Built-in tabs can be hidden and shown; they cannot be dragged into a new order,
despite `enabledTabs` being an ordered array that would support it. The array
order *is* respected — there is just no drag UI.

### Screen Time has no history before install

We track usage ourselves rather than reading Apple's database
([ADR 0015](../decisions/0015-self-tracked-screen-time.md)), so the 7-day chart
is empty on day one and fills in over a week.

Our numbers will also differ from Apple's, which has better idle detection.
Leaving an app frontmost while reading a book credits that app.

---

## Things that are fragile by construction

### Approval pattern matching

`ApprovalPatterns.swift` carries a prominent warning and exists in its own
logic-free file so it can be updated without thinking. Matching a CLI's prompt
by looking at its output is inherently unstable — wording, punctuation and
box-drawing are presentation details authors change freely between releases.

**Prefer the hook transport.** It is exact and version-proof. The pattern list
is only for tools that do not offer a hook.

Symptoms of drift: the badge stops appearing for a tool it used to work with.
Fix: add a pattern.

### The response keystroke for pattern-detected prompts

When a prompt is detected by pattern rather than by hook, we guess the reply: a
numbered menu gets `1`, a y/n prompt gets `y`. If a CLI changes its option
order, the wrong option gets selected.

This is why the approval UI for that transport shows the terminal alongside,
rather than declaring success — the user can see what actually happened.

### `--bench-tab`

A debug affordance. It is not a stable interface and may change.

---

## Things that are untested by machine

The 55 tests cover pure logic. These are verified by running the app and reading
its log, and would benefit from automation:

- Panel positioning across display configurations (external monitor, hot-plug,
  resolution change, notchless Mac).
- Hover debounce feel.
- TCC permission flows.
- The full approval round trip including the user clicking Approve. Socket
  behaviour, blocking, disconnect handling and fail-open **are** verified by
  hand and documented in the README; the click is not automatable without a
  backdoor, and adding an auto-approve backdoor to this specific feature would
  be a security liability, so it is deliberately absent.
- Long-running memory behaviour. **This is the highest-value gap** — see below.

---

## The test we most want

A soak that opens every tab in rotation for an hour and asserts that footprint
returns to ~13.6 MB and wakeups to ~0.9/sec after collapsing.

A teardown leak is precisely the failure this architecture is designed to
prevent, and precisely the kind that would not show up in any current test or in
the published benchmark table.

Manual version, worth running before any release:

```sh
open dist/NotchBuddy.app --args --bench-tab terminal
./Scripts/bench-idle.sh 10 2      # expanded
# collapse the panel, then:
./Scripts/bench-idle.sh 10 2      # must return to ~0.9/s and ~13.6MB
```

---

## Smaller rough edges

- The AI chat scroll follows the stream unconditionally; scrolling up mid-stream
  fights it. SwiftUI gives no scroll offset to detect user intent here.
- `insertCharacters` (ICH) in the emulator is correct but untested — it is rare
  in practice.
- Weather has no manual city search UI; coordinates come from CoreLocation or
  are set programmatically.
- The custom-metric widget supports only a single scalar value, not a series.
- No localisation. All strings are English and inline.
- `Scripts/build-app.sh` does not verify that the Info.plist and the built
  binary agree on the bundle identifier; a mismatch would break TCC persistence
  confusingly.

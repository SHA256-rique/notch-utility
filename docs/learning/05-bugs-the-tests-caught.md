# 05 — Two bugs the tests caught

Both were found within minutes of writing the test suite. Both were silent. Both
would have been extremely annoying to diagnose from a user report. They are
written up here because the *shape* of each mistake is more instructive than the
fix.

---

## Bug 1 — `Double.nan` cannot be JSON-encoded

### The code

```swift
struct SettingsData: Codable {
    var weatherLatitude: Double = .nan       // "no location set"
    var weatherLongitude: Double = .nan
    ...
}
```

Using NaN as an "absent" sentinel for a coordinate looks reasonable. It reads
well at the use site (`if settings.weatherLatitude.isNaN`) and avoids optional
unwrapping.

### What actually happens

`JSONEncoder` **throws** on non-finite doubles by default:

```
EncodingError.invalidValue: nan (Double). Path: weatherLatitude.
Unable to encode Double.nan directly in JSON.
```

### Why it was catastrophic

`SettingsData` is one struct encoded as one file. The throw does not lose the
weather coordinate — **it aborts the entire write**. No `settings.json` at all.

So: theme, battery-saver, hotkey, enabled tabs, home widget layout, clipboard
limit, LLM provider — everything — silently failed to persist, for every user
who had not set a weather location. Which is every user, on first run, forever,
until they happened to grant location access.

And it fails *silently*, because the encode happens on a background queue inside
`JSONStore.save` and the error is logged rather than surfaced:

```swift
} catch {
    Log.store.error("encode/write failed: ...")   // nobody is watching
}
```

### How it surfaced

A round-trip test, three lines long:

```swift
@Test("Settings round-trip through Codable")
func roundTrip() throws {
    var data = SettingsData()
    data.theme = .neon
    let decoded = try JSONDecoder().decode(SettingsData.self,
                                           from: JSONEncoder().encode(data))
    #expect(decoded.theme == .neon)
}
```

It never reached the assertion. `encode` threw.

### The fix

```swift
var weatherLatitude: Double? = nil
var weatherLongitude: Double? = nil
```

Optional is how Swift spells "absent". NaN is how IEEE-754 spells "this
arithmetic went wrong". They are not the same idea, and only one of them
survives a JSON round trip.

### What to take from it

- **Sentinel values inside a serialised type are a trap.** The sentinel has to
  survive every format the type is encoded into. `Optional` always does.
- **A whole-struct encode makes one bad field fatal for every field.** If the
  settings model had been seven files, this would have lost one.
- **Errors logged on a background queue are errors nobody sees.** The log line
  was there the whole time.
- **Round-trip tests are cheap and find real bugs.** Encode it, decode it,
  compare. Three lines.

---

## Bug 2 — `\u{1B}` in a raw string literal is not an escape

### The code

```swift
static func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#,
                              with: "", options: .regularExpression)
}
```

That looks like a regex matching ESC followed by a CSI sequence. It compiles. It
runs. It returns a plausible-looking string.

### What actually happens

Inside a **raw** string literal (`#"..."#`), backslash escapes are not
interpreted. `\u{1B}` is not the escape character — it is the six literal
characters `\`, `u`, `{`, `1`, `B`, `}`.

As a regex, `\u{1B}` then means "the letter `u`, repeated between 1 and B
times"… except `B` is not a number, so `NSRegularExpression` treats the whole
construct as a literal match for `u{1B}`.

The function stripped **nothing**. Ever.

### Why it mattered

`stripANSI` exists so the owned-pty approval detector can match a plain-text
prompt pattern against terminal output. Every CLI colours its prompts. So a
prompt arriving as:

```
\u{1B}[33mDo you want to proceed?\u{1B}[0m
```

never matched `(?i)do you want to proceed`, because the escape codes were still
sitting in the middle of the string.

The result: **the entire owned-pty approval transport silently did nothing** for
any CLI that colours its output — which is all of them. No crash, no log, no
error. The badge simply never appeared, and you would have concluded the feature
was flaky rather than completely inert.

### How it surfaced

```swift
@Test("ANSI is stripped before matching")
func ansiStripping() {
    let coloured = "\u{1B}[33mDo you want to proceed?\u{1B}[0m"
    let clean = OwnedPTYDetector.stripANSI(coloured)
    #expect(clean == "Do you want to proceed?")
}
```

Failure output:

```
(clean → "[33mDo you want to proceed?[0m") == "Do you want to proceed?"
```

The actual value made it obvious in one read: the escape *character* had been
consumed by the terminal rendering the test output, but the `[33m` remained —
proof that the pattern had not matched.

### The fix

Interpolate the escape character instead of writing it inside a raw literal:

```swift
let esc = "\u{1B}"                              // regular literal: real ESC
return text
    .replacingOccurrences(of: "\(esc)\\[[0-9;?]*[ -/]*[@-~]",
                          with: "", options: .regularExpression)
```

The CSI final-byte class was widened to `[ -/]*[@-~]` at the same time, which is
the actual ECMA-48 grammar rather than an approximation.

### What to take from it

- **Raw strings and escape sequences do not mix.** Raw literals are for regexes
  full of backslashes; the moment you need a real control character, build it
  outside and interpolate.
- **A function that silently returns its input is the worst failure mode.** No
  exception, no log, no visible symptom — just a feature that never fires. Test
  the transformation, not just the caller.
- **This is exactly the class of bug a dependency would not have had.** It is
  the honest cost of [ADR 0004](../decisions/0004-zero-dependencies.md), and
  worth stating plainly.

---

## The meta-lesson

Neither bug was in complex code. One was a default value; the other was a string
literal. Both were in code that *looked obviously correct* and that a code
review would very likely have passed.

Both were found by tests that do the least interesting possible thing: encode
and decode a struct; call a pure function and check its output.

The suite deliberately does not mock AppKit or IOKit — asserting "we called
`IOPSCopyPowerSourcesInfo`" proves nothing. It targets pure, consequential logic
where being wrong is invisible. That focus is why 55 small tests found two real
bugs in the first run.

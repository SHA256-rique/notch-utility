# 0017 — swift-testing over XCTest

**Status:** Accepted · **Date:** 2026-09-15

## Context

The test suite needed a framework. XCTest is the established default.

## Decision

swift-testing (`import Testing`, `@Test`, `#expect`).

## Why

**XCTest is not available without Xcode.** `XCTest.framework` ships inside
Xcode; the Command Line Tools install has only `XCTestSupport` (a private
framework, not the testing API). `Testing.framework` *does* ship with the CLT
toolchain. Given [ADR 0005](0005-swiftpm-over-xcode-project.md), XCTest was
simply not an option.

**It would have been the right choice anyway.** swift-testing is where Apple is
taking Swift testing, and it is better for this suite specifically: `@Suite`
groups by concern with readable names, `#expect` gives structured failure output
showing the actual value, `#require` handles optionals without
`XCTUnwrap` ceremony, and `.serialized` expresses the singleton-isolation
requirement declaratively.

The failure messages are noticeably better. When the arbitration tests failed
during development, the output read
`(arbiter.focus?.id → "transient") == "pasta"` — the actual value inline, which
pointed straight at the leaking transient slot.

## The CLT wrinkle, and how it is handled

Two flags, wrapped in `Scripts/test.sh` and explained in its header:

**`-F $(xcode-select -p)/Library/Developer/Frameworks`** — `Testing.framework`
lives outside the default framework search path.

**`-Xfrontend -disable-cross-import-overlays`** — `import Testing` alongside
`import Foundation` triggers the `_Testing_Foundation` cross-import overlay. CLT
ships that framework's dylib but **not** its `.swiftmodule`, so the implicit
import fails with `no such module '_Testing_Foundation'`. The overlay only adds
Foundation-flavoured conveniences we do not use, so it is switched off.

Under full Xcode, plain `swift test` works and both flags are harmless.

## Costs

- Two non-obvious flags, which is why they are documented at length in the
  script rather than left as folklore.
- Smaller ecosystem than XCTest; no `XCTestExpectation` equivalent for the
  async-waiting patterns (not needed here).
- Some tooling still assumes XCTest.

## Note on scope

The suite deliberately does not mock AppKit, IOKit or the window server. A test
asserting "we called `IOPSCopyPowerSourcesInfo`" proves nothing about battery
reporting. Those paths are verified by running the app and reading its log; the
55 tests target logic that is pure, consequential, and invisible when wrong —
the hub's coalescing maths, the arbitration rule, the VT parser, the JSON-path
resolver, retention rules, and alarm scheduling.

That focus paid for itself immediately: writing the suite surfaced two real
production bugs. See
[learning/05-bugs-the-tests-caught.md](../learning/05-bugs-the-tests-caught.md).

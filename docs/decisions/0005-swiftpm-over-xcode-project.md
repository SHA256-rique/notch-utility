# 0005 — A Swift Package, not an Xcode project

**Status:** Accepted · **Date:** 2026-09-15

## Context

A macOS app is normally an `.xcodeproj` with an app target: Info.plist wired to
the target, entitlements, signing, asset catalogs, and `xcodebuild` in CI.

The build environment for this project has **Command Line Tools only** —
`xcodebuild` reports `tool 'xcodebuild' requires Xcode`.

## Decision

A SwiftPM executable package plus `Scripts/build-app.sh`, which assembles the
`.app` bundle by hand.

## Why

**It builds with what is actually installed.** `swift build` works under CLT;
`xcodebuild` does not. Requiring a 15 GB Xcode install to build a 5 MB utility
is a poor trade.

**`.xcodeproj` is a terrible thing to review.** It is a generated pbxproj file
where a one-line change produces a 40-line diff of UUIDs. `Package.swift` is 40
lines of readable Swift, and adding a file to the build is "create the file".

**Bundle assembly is not complicated.** What Xcode does for an unsandboxed
accessory app is: copy the binary into `Contents/MacOS`, copy `Info.plist`, write
`PkgInfo`, codesign. That is fifteen lines of shell, and now it is visible
instead of hidden behind a build-settings UI.

## Costs we accepted

- **No SwiftUI previews.** This hurt during UI work.
- **No Instruments integration**, which is why the benchmark is a script reading
  `proc_pid_rusage` rather than a Time Profiler trace.
- **The bundling step is ours to maintain.** If a future feature needs an asset
  catalog, a Metal shader or a localised `.strings` bundle, the script grows.
- **`swift test` needs extra flags** under CLT, wrapped in `Scripts/test.sh`
  (see [ADR 0017](0017-swift-testing-over-xctest.md)).
- **No universal binary yet.** `swift build --arch arm64 --arch x86_64` fails in
  this toolchain; the script detects that and falls back to the host arch, with
  the fallback printed rather than silent. A universal build needs `lipo` over
  two passes and is the obvious next improvement.

## Notes on the bundling script

Ad-hoc code signing (`codesign --sign -`) is **not cosmetic**. macOS keys TCC
grants — Accessibility, Calendars, Location — to a code-signing identity. An
unsigned binary gets a fresh identity on every rebuild, so the user would have
to re-grant Accessibility after *every single build*. Ad-hoc signing with a
stable bundle identifier keeps the grant across rebuilds.

It does **not** satisfy Gatekeeper for distribution. That needs a Developer ID
certificate and notarisation, which is a distribution concern rather than a
build one.

## Revisit if

The app needs asset catalogs, app extensions, or App Store distribution. Any of
those tips it back toward a real Xcode project.

#!/bin/bash
#
# Assembles NotchScotch.app from the SwiftPM build product.
#
# Why this script exists: the build machine has Command Line Tools, not Xcode,
# so `xcodebuild` is unavailable and SwiftPM produces a bare executable. A bare
# executable cannot be an LSUIElement app, cannot carry usage strings, and cannot
# be granted Accessibility permission persistently. So we build the binary with
# SwiftPM and wrap it in a bundle by hand -- which is all Xcode would have done.
#
# Usage:  Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/NotchScotch.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
# Universal binary so the app runs natively on both Apple Silicon and Intel,
# which the brief requires.
swift build -c "$CONFIG" --arch arm64 --arch x86_64 2>/dev/null \
  || { echo "    universal build unavailable, falling back to host arch"; swift build -c "$CONFIG"; }

BIN="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | tail -1)/NotchScotch"
if [ ! -f "$BIN" ]; then
  echo "!! binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchScotch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc signing is not cosmetic here. macOS keys TCC grants (Accessibility,
# Calendars, Location) to a code-signing identity. An unsigned binary gets a new
# identity on every rebuild, so the user would have to re-grant Accessibility
# after every single build. Ad-hoc signing with a stable bundle id keeps the
# grant. It does NOT satisfy Gatekeeper for distribution -- that needs a Developer
# ID and notarisation.
codesign --force --deep \
  --entitlements "$ROOT/Resources/NotchScotch.entitlements" \
  --sign - "$APP" 2>&1 | sed 's/^/    /'

echo "==> Verifying"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

SIZE=$(du -sh "$APP" | cut -f1)
echo ""
echo "    Built: $APP  ($SIZE)"
echo "    Run:   open $APP"
echo "    Logs:  log stream --predicate 'subsystem == \"com.notchscotch.app\"' --level debug"

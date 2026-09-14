#!/bin/bash
#
# Runs the test suite.
#
# The extra flags exist because this project is built with Command Line Tools
# rather than full Xcode:
#
#   -F <CLT>/Library/Developer/Frameworks
#       swift-testing ships as Testing.framework in the CLT toolchain, outside
#       the default framework search path. (XCTest is NOT available at all
#       without Xcode, which is why the suite uses swift-testing.)
#
#   -Xfrontend -disable-cross-import-overlays
#       `import Testing` + `import Foundation` in one file triggers the
#       `_Testing_Foundation` cross-import overlay. CLT ships that framework's
#       dylib but not its .swiftmodule, so the import fails. We do not need the
#       overlay -- it only adds Foundation-flavoured conveniences -- so it is
#       switched off.
#
# Under full Xcode, plain `swift test` works and these flags are harmless.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
FW="$(xcode-select -p)/Library/Developer/Frameworks"

exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  "$@"

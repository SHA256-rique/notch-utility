# Architecture Decision Records

One file per decision that was genuinely contested — where a reasonable
engineer would have picked differently, or where the obvious choice was rejected
for a non-obvious reason.

Each record states the alternatives that were actually considered, what they
would have cost, and what would make us revisit. A decision with no credible
alternative is not an ADR; it is just code, and it is documented in the source
file's header instead.

| # | Decision | Status |
|---|---|---|
| [0001](0001-native-appkit-over-electron.md) | Native Swift/AppKit over Electron or a web view | Accepted |
| [0002](0002-central-polling-hub.md) | One central polling hub, not N timers | Accepted |
| [0003](0003-darwin-apis-over-subprocesses.md) | Direct Darwin APIs over shelling out | Accepted |
| [0004](0004-zero-dependencies.md) | Zero third-party dependencies | Accepted |
| [0005](0005-swiftpm-over-xcode-project.md) | Swift Package over an Xcode project | Accepted |
| [0006](0006-appkit-lifecycle-over-swiftui-app.md) | AppKit lifecycle, SwiftUI content | Accepted |
| [0007](0007-unix-socket-for-approval-hook.md) | Unix socket, not a loopback port, for approvals | Accepted |
| [0008](0008-hand-rolled-terminal-emulator.md) | Hand-rolled VT100 over SwiftTerm | Accepted |
| [0009](0009-json-files-over-coredata.md) | Debounced JSON files over Core Data/SQLite | Accepted |
| [0010](0010-config-driven-custom-tabs.md) | Config-driven custom tabs, not a plugin runtime | Accepted |
| [0011](0011-lsuielement-accessory-app.md) | Accessory app with a status item | Accepted |
| [0012](0012-unsandboxed-with-hardened-runtime.md) | Unsandboxed, ad-hoc signed | Accepted |
| [0013](0013-private-apis-via-dlopen.md) | Private APIs via `dlopen`, never linked | Accepted |
| [0014](0014-carbon-hotkey-over-event-tap.md) | Carbon hotkeys over `CGEventTap` | Accepted |
| [0015](0015-self-tracked-screen-time.md) | Track screen time ourselves, not `knowledgeC.db` | Accepted |
| [0016](0016-open-meteo-over-weatherkit.md) | Open-Meteo over WeatherKit | Accepted |
| [0017](0017-swift-testing-over-xctest.md) | swift-testing over XCTest | Accepted |
| [0018](0018-named-widgets-over-generic-metric.md) | Named widgets over one generic metric tile | Accepted |
| [0019](0019-claude-usage-from-local-transcripts.md) | Claude usage from local transcripts, not an API | Accepted |
| [0020](0020-google-oauth-loopback-over-eventkit-only.md) | Direct Google OAuth, not EventKit alone | Accepted |
| [0021](0021-embedded-word-packs.md) | Embedded word packs, derived word of the day | Accepted |
| [0022](0022-detail-tabs-over-permanent-ones.md) | Detail tabs over permanent ones | Accepted |
| [0023](0023-lay-out-around-the-notch.md) | Lay out around the camera housing, never under it | Accepted |
| [0024](0024-orb-for-notchless-displays.md) | An orb on displays without a notch | Accepted |
| [0025](0025-disk-scan-one-level-at-a-time.md) | Scan one level at a time, and never delete | Accepted |
| [0026](0026-fixed-terminal-layouts.md) | Fixed pane layouts, not a pane tree | Accepted |
| [0027](0027-one-panel-size.md) | One panel size for every tab | Accepted |
| [0028](0028-window-mode.md) | A window mode, as a second window | Accepted |
| [0029](0029-pill-shape-and-presence.md) | The pill is notch-shaped, and absent when idle | Accepted |

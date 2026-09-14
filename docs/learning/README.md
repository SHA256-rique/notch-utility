# Learning / knowledge transfer

Written for a developer who has just been handed this codebase. Not API
documentation — the source comments do that. These are the things that are
**not** obvious from reading the code, that took real effort to work out, and
that you would otherwise have to rediscover.

Read in order if you are new:

| | | |
|---|---|---|
| [01](01-orientation.md) | **Orientation** | What this app is, how to build it, where things live, your first change |
| [02](02-the-power-model.md) | **The power model** | The one invariant that governs everything. Read before adding any feature |
| [03](03-macos-apis-field-notes.md) | **macOS API field notes** | Hard-won specifics: IOKit, mach, pty, AX, CoreAudio, pasteboard, TCC |
| [04](04-swiftui-appkit-integration.md) | **SwiftUI ↔ AppKit** | Where the two frameworks meet and what goes wrong there |
| [05](05-bugs-the-tests-caught.md) | **Bugs the tests caught** | Two real production bugs, why they were invisible, what to learn |
| [06](06-known-limitations.md) | **Known limitations** | What does not work, what is fragile, what to fix next |
| [07](07-how-to-add-a-tab.md) | **How to add a tab** | A worked walkthrough with the traps marked |

If you only read one, read [02](02-the-power-model.md). Almost every review
comment on this codebase will be about it.

# 2026-09-16 09:00 — Orb drag, AI context, disk access, teleprompter, logging

## What was asked

1. *"while dragging the floating window icon, its flicker very hard"*
2. *"add a section of adding context for ai tab and make sure it hold
   conversation and has option of starting new conversation and has history
   option, an option to add files, another option screenshot and add to
   context"*
3. *"anything else i can add in discview since i am not able to see documents
   folder and other stuff maybe i missed something"*
4. *"when i click open window in teleprompter the notch window should disappear
   and only teleprompter window should be seen and if i have to open the window
   to play it, there is not point in adding play option in the notch
   teleprompter tab"*
5. *"setup claude file and put context about everytime something is done it
   outputs the logs and the output to a .md file in say output_logs folder
   (make this), and also commit it to github"*

---

## What changed

### 1. Orb drag flicker — `OrbView.swift`, `NotchPanelController.swift`

Replaced the SwiftUI `DragGesture` with an AppKit `NSViewRepresentable`
(`OrbDragHandle`) that calls `NSWindow.performDrag(with:)`.

**Root cause.** `DragGesture` reports a *cumulative* translation measured
relative to the view, and therefore relative to the window the view is in.
Moving the window in response changes the origin the next event is measured
from, so every event is partly stale. Applying only the delta reduced it but
could not fix it — the events and the window moves are on different clocks, so
each frame the window landed slightly wrong and was corrected on the next. That
correction at 60Hz *is* the flicker.

`performDrag` is the API for this: AppKit tracks the mouse at the window-server
level and moves the window in lockstep, the same mechanism that drags a title
bar. SwiftUI is not in the loop, so there is no loop.

Side effect handled: `performDrag` consumes the mouse-down and blocks until
mouse-up, so `onTapGesture` never fires once this view is in front. The same
handler now decides — if the window did not move more than 1pt, it was a click.

`commitOrbPosition()` reads the position back off the window instead of
accumulating deltas, because `performDrag` is the only thing that knows where it
ended up.

### 2. AI tab — `ChatStore.swift` (new), `AIChatTabView.swift`, `LLMClient.swift`

- **Persistent conversations.** `ChatStore` holds conversations on disk
  (`chats.json`), so a chat survives a tab switch, a collapse and a relaunch.
  Capped at 60 — images are base64 in the same file.
- **History sidebar**, most-recently-updated first, with delete. Titles are
  derived from the first user message rather than asked for; nobody names a
  conversation, and an untitled list is unsearchable.
- **New conversation** reuses an existing empty one rather than stacking blanks.
- **Context panel**, attached to the *conversation* not the message: attach a
  file once and ask three questions about it. Files, an interactive screenshot,
  and paste-from-clipboard. Shows an approximate token cost so a forgotten 80k
  attachment is visible rather than silently riding every turn.
- **Images through to the model.** `LLMMessage` gained an `images` array and
  `LLMClient` builds vision content blocks per provider — Anthropic's
  `source/base64`, OpenAI's `image_url` data URI, Ollama's sibling `images`
  array. Images go before text in the block list, which both vendors recommend.
- Screenshots downscale to 1568px on the long edge before encoding, because both
  vendors downscale above that anyway and sending more is paying to transmit
  pixels that get discarded.

### 3. Disk Map — `DiskScanner.swift`, `DiskMapModel.swift`, `DiskMapTabView.swift`

**The Documents problem was permissions, and the tab was lying about it.**
TCC gates Documents/Desktop/Downloads for every app, sandboxed or not, and a
denial surfaces as `NSFileReadNoPermissionError`. The scanner swallowed that
with `try?` and reported 0 bytes, so a protected folder looked *empty* — a
confident, wrong answer.

- `DiskScanner.canRead(_:)` distinguishes "nothing here" from "not allowed to
  look", and triggers the system prompt at the moment the user asks for the
  folder.
- `DiskEntry.isUnreadable` marks such folders, rendered as an orange **no
  access** badge instead of a size.
- A banner above the listing when the current folder itself is blocked, with
  buttons to Files & Folders and Full Disk Access.
- **Go to** shortcut row: Home, Documents, Desktop, Downloads, Pictures, Movies,
  Music, Library, Applications.
- **Largest files** — a third view mode. Recursive, on demand, keeping only the
  top *k* against a running minimum rather than sorting two million entries.
  This is the question a disk tool is actually for: not which folder is big (you
  usually know) but which *file* is, which is never where you would look.

### 4. Teleprompter — `TeleprompterWindow.swift`, `TeleprompterTabView.swift`

- `open()` now collapses the notch panel. You open a prompter because you are
  about to talk to a camera; leaving a settings panel over it is exactly wrong.
- Removed Play/Pause/Top from the tab. They were controls on a surface that
  closes as the thing they control opens — unreachable by construction. They
  live in the prompter window, on hover, where they already were.
- The button is now "Start prompting", disabled until there is a script.

### 5. Logging — `CLAUDE.md` (new), `output_logs/` (new)

Working agreement covering the session-log requirement, the ten non-negotiable
engineering constraints, house rules for comments/ADRs/tests, the verification
chain, commit conventions, and a "things that bite" list of platform traps
already hit in this project.

---

## Commands run and their output

```
$ swift build
Build complete! (0.08s)

$ ./Scripts/test.sh
✔ Test run with 153 tests in 28 suites passed after 0.031 seconds.

$ ./Scripts/build-app.sh
    Built: /Users/shams/Documents/notch-utility/dist/NotchScotch.app  ( 11M)

$ open dist/NotchScotch.app && sleep 12 && ps -o %cpu=,rss= -p $(pgrep -x NotchScotch)
  0.0  41264
$ # after 24s
  0.0  42896
```

Idle CPU 0.0%, RSS ~42MB, stable across 24s.

Permission probe run before changing anything, to confirm the diagnosis:

```
$ ./probe          # from a terminal that already has Full Disk Access
Documents: OK, 42 items
Desktop: OK, 528 items
Downloads: OK, 227 items
Library: OK, 88 items
```

All readable from a *granted* process — which is what pointed at TCC rather than
at the scanner logic. The app bundle is a separate TCC subject and, since the
rename to `com.notchscotch.app`, holds none of the old grants.

---

## Decisions and trade-offs

- **`performDrag` over a tuned gesture.** Considered damping or predicting the
  translation; both are compensation for a feedback loop rather than removal of
  it. The AppKit path has no loop to compensate for.
- **Context on the conversation, not the message.** Per-message context would
  re-send the same bytes for every follow-up, or make follow-ups unanswerable if
  it did not. The cost is that a stale attachment rides along silently — hence
  the visible token estimate.
- **`screencapture` as a deliberate exception to the no-subprocess rule.** The
  alternative is ScreenCaptureKit plus a whole selection UI (overlay window,
  drag rectangle, escape handling, multi-display coordinates) to reimplement
  something every Mac user has muscle memory for — and it would additionally
  require the screen-recording permission this path does not.
- **Largest-files is opt-in, not automatic.** It is a full recursive walk with
  no early exit, which is the exact cost the rest of the tab is designed to
  avoid on open.
- **Truncate attached files at the head, keep the tail.** The top of a file is
  imports and front matter; the end is usually what you are asking about.

---

## What is still open

- **The AI context features are not verified end to end.** Build, tests and
  launch all pass, but sending a real request with an attached image needs an
  API key and a live call, which I did not make. The request-shaping code is
  covered by reading the vendor docs, not by a round trip.
- **Screenshot capture is not verified interactively.** It shells out to
  `/usr/sbin/screencapture -i`, which needs a human to drag a rectangle.
- **Folder permissions must be granted by hand.** The rename dropped every TCC
  grant. The app now asks and points at the right pane, but nothing can restore
  the grants programmatically — expect to allow Documents/Desktop/Downloads
  again, or give Full Disk Access once.
- **No tests were added this round.** The changes are overwhelmingly UI and
  system-integration, which this project deliberately does not mock. The
  testable arithmetic (largest-files top-*k* selection) is worth covering and is
  not yet.
- **The orb drag fix is not visually confirmed** — it needs a pointer on the
  hardware. The mechanism is the documented one, but "no longer flickers" is the
  user's call.

---

## Commits

| Hash | Subject |
|---|---|
| `98c934c` | fix(orb): drag with AppKit instead of a SwiftUI gesture |
| `d8032e7` | fix(teleprompter): get out of the way, and drop the unreachable controls |
| `5586ee5` | fix(storage): your Documents folder was not empty, we were not allowed to look |
| `639604b` | feat(ai): conversations that persist, history, and attachable context |
| *(this)* | chore: working agreement and session logs |

One note on process: the first attempt put all five concerns in a single commit
because `git add` had staged everything. Reset and split by path before pushing
— the changes were cleanly separable by file, so there was no excuse for a
commit message that described a fifth of its own contents.

# 07 — How to add a tab

A worked walkthrough. The traps are marked ⚠.

We will add a hypothetical **Git** tab that shows the status of a repository.

---

## 1. Declare the identity

`Sources/NotchScotch/Tier2/TabRegistry.swift`:

```swift
enum TabID: String, Codable, CaseIterable, Identifiable, Hashable {
    case home, time, snippets, notes, calendar, files
    case api, docker, terminal, ai, message, settings
    case git                                            // ← new
    ...
}
```

⚠ **The raw value is persisted** in `settings.json` as part of `enabledTabs`.
Never rename a case's raw value — users who have customised their tab list will
silently lose that tab.

Add the three properties:

```swift
var title: String  { case .git: return "Git" }
var symbol: String { case .git: return "arrow.triangle.branch" }   // SF Symbol
var tint: ModuleTint { case .git: return .custom }
```

⚠ `needsKeyboardFocus` defaults to `false` via the `switch`'s default arm.
Return `true` only if the tab has a text field — it makes the app activate and
take focus from whatever the user was typing in, which is intrusive if
unnecessary.

Add a `ModuleTint` case if the tab deserves its own colour; otherwise reuse one.

---

## 2. Register it in the panel

`Sources/NotchScotch/Tier2/ExpandedPanelView.swift`:

```swift
@ViewBuilder
private func builtinTab(_ id: TabID) -> some View {
    switch id {
    ...
    case .git: GitTabView()
    }
}
```

The tab bar itself needs no change — it iterates
`settings.data.enabledTabs`, and `TabID.defaultOrder` is derived from
`allCases`.

⚠ Existing users have an `enabledTabs` array written before your case existed,
so the new tab will **not** appear for them until they enable it in
Settings → Tabs. That is correct behaviour (we do not silently rearrange
someone's UI), but it will confuse you during testing. Delete
`~/Library/Application Support/NotchScotch/settings.json` to see it.

---

## 3. Write the view, with the lifecycle contract

```swift
struct GitTabView: View {
    @EnvironmentObject private var themes: ThemeManager
    @StateObject private var model = GitModel()

    var body: some View {
        let theme = themes.theme
        VStack(spacing: 6) {
            ...
        }
        .onAppear    { model.activate() }
        .onDisappear { model.deactivate() }      // ← not optional
    }
}
```

⚠ **Teardown goes in `.onDisappear`, never in `deinit` and never at app quit.**
SwiftUI object lifetimes are not what you expect, and the whole point is that a
closed tab costs nothing *while the app keeps running*.

⚠ Use `@StateObject` for a model the view owns. `@ObservedObject` on a
per-view model recreates it on every render.

---

## 4. If it needs periodic refresh

**Do not create a `Timer`.** Register with the hub:

```swift
@MainActor
final class GitModel: ObservableObject {
    @Published private(set) var status: String = ""
    private var token: UUID?

    func activate() {
        refresh()
        token = WidgetPollingHub.shared.register(label: "git-status", interval: 5) {
            [weak self] in self?.refresh()
        }
    }

    func deactivate() {
        WidgetPollingHub.shared.unregister(token)
        token = nil
        task?.cancel()                 // and anything else in flight
    }
}
```

⚠ The `label` shows up in Settings → Power. Make it something a user chasing
battery drain would understand.

⚠ **Before adding a registration at all**, check whether there is an
event-driven alternative. For a Git tab there is:
`DispatchSourceFileSystemObject` on `.git/HEAD` and `.git/index` would be
strictly better than polling. See the table in
[02-the-power-model.md](02-the-power-model.md) — the answer is "yes, there is an
event API" far more often than people expect.

---

## 5. If it needs to surface something in the notch

Publish a claim; do not touch the pill view:

```swift
NotchArbiter.shared.claim(PillClaim(
    id: "git", priority: .ambient, module: .custom,
    symbol: "arrow.triangle.branch", text: "3 changes", detail: branchName,
    rank: 30, expiresAt: nil, progress: nil))
```

Pick the priority honestly:

- `.ambient` — background info. Loses to everything. Almost certainly what you
  want.
- `.persistent` — ongoing user-initiated state that must stay visible until it
  resolves. A running timer. A blocked CLI. **Not** "my tab has data".
- `.transient` — a momentary confirmation, via `NotchArbiter.shared.flash(...)`.

⚠ **Withdraw it.** `NotchArbiter.shared.withdraw("git")` in `deactivate()`, or
the claim outlives the tab.

⚠ Re-claiming with identical content is a no-op by design, so you can assert it
on every refresh without causing SwiftUI churn.

---

## 6. If it does network or subprocess work

- Network: `URLSession`, and **cancel the task** in `deactivate()`.
- Never spawn a process for data an API provides
  ([ADR 0003](../decisions/0003-darwin-apis-over-subprocesses.md)). For Git
  specifically there is no API, so a one-shot `Process` on user action is
  acceptable — but never on a timer.
- Anything blocking (a socket read) goes on a queue and hops back to the main
  actor, like `DockerClient`.

---

## 7. Verify it

```sh
./Scripts/test.sh
./Scripts/build-app.sh release
open dist/NotchScotch.app --args --bench-tab git
./Scripts/bench-idle.sh 10 2          # cost while open
# collapse the panel, then:
./Scripts/bench-idle.sh 10 2          # MUST return to ~0.9 wakeups/s, ~13.6MB
```

That second measurement is the real acceptance test. If the collapsed numbers do
not return to baseline, something did not tear down.

Also check Settings → Power: your registration should appear while the tab is
open and be gone after it closes.

---

## The checklist

- [ ] `TabID` case added; raw value will never change
- [ ] `title`, `symbol`, `tint` set
- [ ] `needsKeyboardFocus` only if there is a text field
- [ ] `switch` arm in `ExpandedPanelView.builtinTab`
- [ ] `.onAppear` / `.onDisappear` pair present
- [ ] No `Timer` — hub registration if periodic, or event-driven if possible
- [ ] Hub token unregistered in teardown
- [ ] In-flight tasks cancelled in teardown
- [ ] Any arbiter claim withdrawn in teardown
- [ ] Registration visible in Settings → Power while open, absent after close
- [ ] Collapsed benchmark returns to baseline after closing the tab

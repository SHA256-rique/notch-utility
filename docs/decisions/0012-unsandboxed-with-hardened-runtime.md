# 0012 — Unsandboxed, ad-hoc signed

**Status:** Accepted · **Date:** 2026-09-15

## Context

The App Sandbox is the default for new macOS apps and is mandatory for the Mac
App Store.

## Decision

`com.apple.security.app-sandbox = false`. Distributed outside the App Store.

## Why

Three headline features are individually incompatible with the sandbox:

**The Accessibility API.** A sandboxed app cannot use `AXUIElement` to read
another application's selected text, regardless of what the user grants. There
is no entitlement for it. That removes selection-aware Explain/Rewrite/Translate
entirely.

**The Docker socket.** `/var/run/docker.sock` (and the Docker Desktop, Colima
and OrbStack equivalents) is outside any sandbox container. No temporary
exception entitlement covers it.

**Spawning a login shell on a pty.** A sandboxed process cannot `posix_spawn`
`/bin/zsh -l` and have it behave like the user's shell — the child inherits the
sandbox, so their tools do not work. A terminal that cannot run the user's
tooling is not a terminal, and without it the owned-pty approval path disappears
too.

The approval hook socket in `~/.notchbuddy/` would also be inside a container
rather than at a path another process can reach.

## What we do instead

Sandboxing is not the only control available, and the ones that apply are used:

- **Ad-hoc code signing** with a stable bundle identifier, so TCC grants persist
  across rebuilds rather than being re-requested every time.
- **Permissions requested at point of use, never at launch.** Calendar access is
  requested when the Calendar tab opens. Accessibility only when the user enables
  selection assist. Location only when they ask for weather. An app that asks
  for four permissions at first launch trains users to click through prompts.
- **Selection assist is off by default** — the one feature needing the most
  invasive permission is opt-in.
- **Secrets in the Keychain**, `ThisDeviceOnly`.
- **The approval socket is `0600` in a `0700` directory**, not a loopback port
  ([ADR 0007](0007-unix-socket-for-approval-hook.md)).
- **Nothing is transmitted** except the user's own LLM calls and a rounded
  weather coordinate, and Settings → About states this in the app.
- **Zero dependencies**, so the answer to "what other code runs with these
  privileges" is "none" ([ADR 0004](0004-zero-dependencies.md)).

## Costs

- **No Mac App Store.** Accepted; the App Store was never viable for a notch
  utility that needs Accessibility.
- **Distribution needs Developer ID + notarisation.** Ad-hoc signing satisfies
  TCC persistence but not Gatekeeper. Users building from source are unaffected;
  a released binary would need real signing.
- **More trust is asked of the user**, which is why the transparency measures
  above exist and why Settings → About enumerates capabilities — including the
  ones that failed to resolve.

## Revisit if

Apple ships an entitlement that makes the Accessibility API available to
sandboxed apps. Nothing else moves the needle.

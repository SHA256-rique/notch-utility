# 0010 — Config-driven custom tabs, not a plugin runtime

**Status:** Accepted · **Date:** 2026-09-15

## Context

Users want tabs the app does not ship. The ambitious answer is a plugin system:
load bundles, or embed JavaScriptCore, or expose a scripting API, and let people
write their own.

## Decision

A fixed catalogue of four tab **types** — pinned web page, shortcut launcher,
snippet list, custom metric — which users *configure* instances of. No bundle
loading, no script engine, no `dlopen` of user code.

The brief called for this explicitly, and it was right.

## Why

**A plugin runtime is a security surface, and this process is a bad place for
one.** NotchBuddy reads the clipboard, holds LLM API keys in the Keychain, talks
to the Docker socket, spawns a login shell, and answers "may this agent run this
command". Loading third-party code into *that* process — even sandboxed —
changes the app's threat model completely. The honest answer to "what else runs
in there" stops being "nothing".

**Every plugin has a RAM floor.** A JS runtime is megabytes before it executes
anything. A loaded bundle is resident for the process lifetime. Three plugins
and the footprint story is gone.

**Plugin APIs are permanent.** Whatever surface is exposed in v1 has to keep
working, which constrains every future refactor of the internals. That is a
large commitment to make before knowing whether anyone wants it.

**Configuration covers the realistic cases.** "Show me this dashboard", "launch
these five apps", "show my saved SSH commands", "show today's revenue from our
API" are the things people actually ask for, and all four are configuration.

## Costs we accepted

- Genuinely novel tab types require a code change and a release.
- The four types are a guess at what people want. That guess may be wrong, which
  is exactly what would make this worth revisiting.

## Notes

The web-view type uses a **non-persistent** `WKWebsiteDataStore` and explicitly
tears the view down in `dismantleNSView` (`stopLoading`, then load about:blank).
A resident `WKWebView` keeps its own content process alive at tens of megabytes
with its own timers — leaving one alive would undo a large part of the memory
story on its own. A pinned dashboard also has no business accumulating cookies
and tracking state inside a utility app.

## Revisit if

Config-driven tabs prove insufficient *in practice* — i.e. real users ask for
specific things that cannot be expressed as configuration. The right next step
would then be a fifth *type* covering that need, and only after several such
requests would a sandboxed extension point (an App Extension, not in-process
code) be worth designing.

# 0007 — A unix domain socket for the approval bridge, not a loopback port

**Status:** Accepted · **Date:** 2026-09-15

## Context

The approval hook needs an IPC channel: a short-lived hook process, spawned by a
CLI agent, must send a request to the running app and block until the user
answers. The obvious options are a loopback HTTP server, a unix domain socket, a
file-based mailbox, or an XPC service.

The payload is *"may this agent run `rm -rf build/`"*, and the reply grants or
denies it. This is a security-relevant channel, not a convenience one.

## Decision

A unix domain socket at `~/.notchbuddy/approval.sock`, created `0600` inside a
`0700` directory.

## Why

**A loopback port has no access control.** `127.0.0.1:PORT` is reachable by
every process and every user account on the machine. It is reachable by any
sandboxed app. It is reachable by a web page the user visits, via a
cross-origin request to `http://127.0.0.1` — which is a real, repeatedly-exploited
class of attack against apps that bind loopback ports. A unix socket is a
filesystem object governed by file permissions: nothing that cannot read the
path can send us a decision.

For a channel whose semantics are "approve arbitrary shell commands", that
difference is decisive.

**It blocks naturally.** The hook process sits in `read()` on the socket —
descheduled entirely, no timer, no polling, no busy loop — until we write a
reply. A file-based mailbox would require the hook to poll for a response file.

**Disconnect is detectable.** If the agent is killed mid-prompt, the socket EOFs
and we withdraw the badge, rather than leaving a question nobody is waiting on
the answer to. A file mailbox gives no such signal.

**`nc -U` ships with macOS**, so the bridge script needs no compiled helper and
no installed tooling.

## Alternatives considered

**Loopback HTTP.** Rejected above. Would also have needed a token, which means
storing and distributing a token, which is more machinery for a worse result.

**XPC service.** The correct macOS answer for privileged IPC, and genuinely
better on identity: XPC can verify the peer's code signature. Rejected because
the client is `/bin/sh`, not a signed Mach service — a shell script cannot
connect to an XPC service without a compiled helper, and shipping an opaque
helper binary would undercut the "read the 20 lines before you trust it"
property that matters most here.

**A named pipe (FIFO).** Simpler, but a FIFO is one-directional. Two FIFOs
reintroduce the framing and lifetime problems a socket solves.

## Costs we accepted

- Hand-written `socket`/`bind`/`listen`/`accept` in Swift, plus the
  `sockaddr_un.sun_path` fixed-array dance. `URLSession` cannot do this.
- A stale socket file after a crash; handled by `unlink` before `bind`.
- Each connection is handled on a serial queue, so one wedged client cannot
  block the accept loop — deliberate, and worth stating because getting it wrong
  would hang the feature.
- `sun_path` is 104 bytes. A pathological home directory path would not fit; we
  reject rather than truncate.

## Design notes worth keeping

**The bridge script is generated, not shipped.** It is written to disk on
startup with this user's socket path baked in. A user can `cat` the whole thing
— it is 20 lines of `sh` — before wiring it into a tool that runs commands on
their machine. Shipping an opaque binary for this would be exactly backwards.

**It fails open.** No socket means NotchBuddy is not running, and the script
exits 0 immediately (measured: 31ms) so the agent falls back to its normal
prompting. An approval bridge that hangs your agent when the UI app is closed
would be worse than no bridge.

**We do not edit `~/.claude/settings.json`.** The snippet is displayed with a
copy button. Writing into another tool's config behind the user's back is
exactly what you should not accept from a utility app, and it would be clobbered
the moment they hand-edit it.

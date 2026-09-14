# 0003 — Direct Darwin APIs over shelling out

**Status:** Accepted · **Date:** 2026-09-15

## Context

Most of the system data this app displays has a well-known command-line source:
`top` or `ps` for CPU and memory, `pmset -g batt` for battery, `docker ps` for
containers, `osascript` for volume, `brightness` for display brightness. Parsing
those is quick to write and easy to debug.

## Decision

Never spawn a process for data an API can provide.

| Data | Used | Rejected |
|---|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` | `top -l 1` |
| Memory | `host_statistics64(HOST_VM_INFO64)` | `vm_stat` |
| Disk | `volumeAvailableCapacityForImportantUsage` | `df -h` |
| Battery | `IOPSNotificationCreateRunLoopSource` | `pmset -g batt` |
| Volume | `AudioObjectSetPropertyData` | `osascript set volume` |
| Brightness | DisplayServices / IODisplay | a `brightness` binary |
| Docker | HTTP over the daemon's unix socket | `docker ps` |

The exception is developer tooling — `Scripts/bench-idle.sh` shells out freely,
because the rule is about the app's runtime behaviour on a timer, not about a
script that runs a few dozen times.

## Why

**Spawn cost dominates.** `posix_spawn` plus dynamic linking plus the tool's own
startup is on the order of **10–30ms of CPU per sample**. At a 2-second interval
that is 0.5–1.5% of a core, burned continuously, to display a number — the
measurement would cost more than everything else the app does combined. A Mach
trap costs microseconds. For an app whose headline claim is 0.0004% idle CPU,
this single decision is the difference between the claim being true and being
absurd.

**Output formats are not APIs.** `top`'s column layout has changed between
releases. `docker ps` truncates and pads for humans. Neither carries a
compatibility promise; the Mach interfaces and the Docker Engine API both do.

**Localisation breaks naive parsing.** In a locale using a decimal comma,
`"1,5%"` parses to `1` in `Double(_:)`. Silently. This class of bug is
undetectable in testing on an en_US machine.

**`PATH` is not what you think it is.** GUI apps do not inherit the shell
environment. A Docker Desktop install that works perfectly in Terminal is
invisible to an app spawning `/usr/bin/env docker`. Talking to the socket
directly removes an entire category of "works in my terminal" bug report.

**Process spawning is a security surface.** It widens the process tree and
inherits environment in ways that are easy to get subtly wrong.

## Costs we accepted

- More code, and more of it C-interop-shaped: `withUnsafeMutablePointer`,
  `memory_rebind`, `sockaddr_un`, manual HTTP framing.
- Some data is genuinely harder to get. Brightness has no public API at all,
  which is why it goes through `dlopen` (see
  [ADR 0013](0013-private-apis-via-dlopen.md)) and degrades visibly when
  unavailable rather than shelling out to a helper binary.
- CPU percentage needs two samples for a delta, so the first reading after a tab
  opens is blank. A `top` call would have given an immediate (if expensive)
  number.

## Revisit if

Never for polled data. A one-shot user-initiated action where no API exists is a
different question and would be judged on its own merits.

#!/bin/bash
#
# Idle-cost benchmark. The numbers this prints are the ones quoted in the README.
#
# ---------------------------------------------------------------------------
# WHY NOT `ps -o %cpu`
# ---------------------------------------------------------------------------
# The obvious implementation is wrong on macOS, and wrong in the flattering
# direction. Darwin's ps reports %cpu as total CPU time over total elapsed time
# *since the process started* -- a lifetime average. An app that burned a core
# for one second and then slept for an hour reports ~0%. Any app looks good on
# that metric given enough uptime, so it proves nothing.
#
# `ps -o cputime` measures a real interval but only has 10ms resolution, which
# for this app bottoms out at "0" and tells you nothing about how close to zero
# it actually is.
#
# ---------------------------------------------------------------------------
# WHAT THIS MEASURES INSTEAD
# ---------------------------------------------------------------------------
# proc_pid_rusage(PROC_PID_RUSAGE, RUSAGE_INFO_V4), sampled at the start and end
# of each window. It gives:
#
#   CPU time        user + system, in NANOSECONDS. Fine enough to distinguish
#                   "genuinely idle" from "quietly busy".
#
#   Wakeups         ri_interrupt_wkups. This is the metric that actually
#                   predicts battery impact on Apple Silicon, and it is the one
#                   this app's architecture is built around. The cost of a timer
#                   is the wakeup, not the work in the callback -- a core pulled
#                   out of an idle state costs the same whether the callback
#                   does one thing or nothing. It is also harder to game than
#                   CPU%, which is why it is reported first-class here.
#
#   Memory          ri_phys_footprint, which is what Activity Monitor shows in
#                   its "Memory" column. RSS is reported too, but footprint is
#                   the honest number: RSS counts shared framework pages that
#                   every AppKit app maps and that would be resident anyway.
#
# Yes, this shells out. The no-subprocess rule governs the app's runtime
# behaviour on a timer, not a dev tool that runs a few dozen times. Measuring
# from outside the app is also the point -- a benchmark an app reports about
# itself is not evidence.
#
# Usage:  Scripts/bench-idle.sh [seconds-per-window] [windows]
set -euo pipefail

WINDOW="${1:-10}"
RUNS="${2:-3}"
PROC="NotchScotch"

PID=$(pgrep -x "$PROC" | head -1 || true)
if [ -z "$PID" ]; then
  echo "NotchScotch is not running. Start it first:  open dist/NotchScotch.app" >&2
  exit 1
fi

exec python3 - "$PID" "$WINDOW" "$RUNS" <<'PY'
import ctypes, subprocess, sys, time

pid, window, runs = int(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

# struct rusage_info_v4 from <libproc.h>. Only the leading fields are read, but
# the whole layout must be declared so the struct is the right size.
_U64 = ctypes.c_uint64
class RUsageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, _U64) for name in (
            "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups",
            "ri_interrupt_wkups", "ri_pageins", "ri_wired_size",
            "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
            "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time",
            "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
            "ri_child_pageins", "ri_child_elapsed_abstime",
            "ri_diskio_bytesread", "ri_diskio_byteswritten",
            "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
            "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility",
            "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
            "ri_cpu_time_qos_user_interactive", "ri_billed_system_time",
            "ri_serviced_system_time", "ri_logical_writes",
            "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
            "ri_billed_energy", "ri_serviced_energy",
            "ri_interval_max_phys_footprint", "ri_runnable_time", "ri_flags")
    ]

RUSAGE_INFO_V4 = 4

def sample():
    buf = RUsageInfoV4()
    if libc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(RUSAGE_INFO_V4),
                            ctypes.byref(buf)) != 0:
        sys.exit("proc_pid_rusage failed -- did the process exit?")
    return buf

def sysctl(key):
    return subprocess.run(["sysctl", "-n", key], capture_output=True,
                          text=True).stdout.strip()

print("NotchScotch idle benchmark")
print(f"  pid            {pid}")
print(f"  window         {window:g}s x {runs}")
print(f"  machine        {sysctl('machdep.cpu.brand_string')} ({sysctl('hw.ncpu')} cores)")
print(f"  macOS          {subprocess.run(['sw_vers','-productVersion'],capture_output=True,text=True).stdout.strip()}")
print( "  method         proc_pid_rusage deltas (ns CPU time, interrupt wakeups)")
print()
print(f"{'window':<8}{'cpu (ms)':>10}{'% of core':>11}{'wakeups/s':>11}{'footprint':>11}{'rss':>9}")
print(f"{'------':<8}{'--------':>10}{'---------':>11}{'---------':>11}{'---------':>11}{'---':>9}")

cpu_pcts, wake_rates = [], []
for run in range(1, runs + 1):
    a, t0 = sample(), time.monotonic()
    time.sleep(window)
    b, t1 = sample(), time.monotonic()

    elapsed = t1 - t0
    cpu_ns = (b.ri_user_time + b.ri_system_time) - (a.ri_user_time + a.ri_system_time)
    cpu_ms = cpu_ns / 1e6
    pct = (cpu_ns / 1e9) / elapsed * 100
    wakes = (b.ri_interrupt_wkups - a.ri_interrupt_wkups) / elapsed
    footprint = b.ri_phys_footprint / 1024 / 1024
    rss = b.ri_resident_size / 1024 / 1024

    cpu_pcts.append(pct)
    wake_rates.append(wakes)
    print(f"{run:<8}{cpu_ms:>10.3f}{pct:>11.4f}{wakes:>11.1f}{footprint:>10.1f}M{rss:>8.1f}M")

print()
print(f"  mean CPU:      {sum(cpu_pcts)/len(cpu_pcts):.4f}% of one core")
print(f"  mean wakeups:  {sum(wake_rates)/len(wake_rates):.1f} per second")
print()
print("Record all three states in docs/BENCHMARKS.md:")
print("  1. panel collapsed, nothing open      <- the number that matters")
print("  2. panel expanded on the Home tab     <- stats rings polling at 2s")
print("  3. panel expanded on the Terminal tab <- pty alive, idle shell")
PY

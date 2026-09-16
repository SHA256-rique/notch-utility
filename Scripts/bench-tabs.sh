#!/bin/bash
#
# Per-tab resource cost. Companion to bench-idle.sh, which measures the app
# doing nothing; this measures it doing one specific thing.
#
# ---------------------------------------------------------------------------
# WHY ONE LAUNCH PER TAB
# ---------------------------------------------------------------------------
# Switching tabs inside one process would be faster and would measure the wrong
# thing. Memory is the number people care about here, and a long-lived process
# that has opened six tabs carries the high-water mark of all six -- allocators
# do not return freed pages to the OS promptly, so "Terminal costs 90MB" would
# really mean "Terminal plus whatever Disk Map left behind".
#
# A fresh process per tab is the only way to attribute footprint honestly. It is
# slow (about 20s per tab) and that is fine for something run by hand.
#
# The app is driven by NOTCHSCOTCH_BENCH_TAB, which opens one tab in the
# standalone window at launch.
#
# Usage:  Scripts/bench-tabs.sh [seconds-per-tab]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
WINDOW="${1:-8}"
APP="dist/NotchScotch.app"
PROC="NotchScotch"

if [ ! -d "$APP" ]; then
  echo "Build the bundle first:  Scripts/build-app.sh" >&2
  exit 1
fi

TABS=(collapsed home time snippets notes calendar files diskMap api terminal ai message teleprompter settings)

printf '%-14s %10s %10s %12s %12s\n' "TAB" "CPU ms/s" "WAKEUPS/s" "FOOTPRINT" "RSS"
printf '%-14s %10s %10s %12s %12s\n' "---" "--------" "---------" "---------" "---"

for tab in "${TABS[@]}"; do
  pkill -x "$PROC" 2>/dev/null || true
  sleep 1

  NOTCHSCOTCH_BENCH_TAB="$tab" open -a "$APP" --env NOTCHSCOTCH_BENCH_TAB="$tab" 2>/dev/null \
    || NOTCHSCOTCH_BENCH_TAB="$tab" "$APP/Contents/MacOS/$PROC" &

  # Settle: window creation, first paint, and any on-open scan.
  sleep 5
  PID=$(pgrep -x "$PROC" | head -1 || true)
  if [ -z "$PID" ]; then
    printf '%-14s %10s\n' "$tab" "NOT RUNNING"
    continue
  fi

  python3 - "$PID" "$WINDOW" "$tab" <<'PY'
import ctypes, sys, time

pid, window, tab = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

_U64 = ctypes.c_uint64
class RUsageInfoV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (n, _U64) for n in (
            "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups",
            "ri_interrupt_wkups", "ri_pageins", "ri_wired_size",
            "ri_resident_size", "ri_phys_footprint",
            "ri_proc_start_abstime", "ri_proc_exit_abstime",
            "ri_child_user_time", "ri_child_system_time",
            "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
            "ri_child_pageins", "ri_child_elapsed_abstime",
            "ri_diskio_bytesread", "ri_diskio_byteswritten",
            "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
            "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility",
            "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
            "ri_cpu_time_qos_user_interactive", "ri_billed_system_time",
            "ri_serviced_system_time", "ri_logical_writes",
            "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
            "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
            "ri_runnable_time", "ri_flags")]

def sample():
    info = RUsageInfoV4()
    if libc.proc_pid_rusage(pid, 4, ctypes.byref(info)) != 0:
        return None
    return info

a = sample()
if a is None:
    print(f"{tab:<14} {'GONE':>10}")
    raise SystemExit
time.sleep(window)
b = sample()
if b is None:
    print(f"{tab:<14} {'EXITED':>10}")
    raise SystemExit

cpu_ns = (b.ri_user_time + b.ri_system_time) - (a.ri_user_time + a.ri_system_time)
wk = b.ri_interrupt_wkups - a.ri_interrupt_wkups
print(f"{tab:<14} {cpu_ns / 1e6 / window:>10.2f} {wk / window:>10.1f} "
      f"{b.ri_phys_footprint / 1048576:>10.1f}MB {b.ri_resident_size / 1048576:>10.1f}MB")
PY
done

pkill -x "$PROC" 2>/dev/null || true
echo
echo "CPU ms/s: milliseconds of CPU per wall-clock second. 10 ms/s is 1% of one core."
echo "Wakeups/s: the metric that predicts battery impact on Apple Silicon."
echo "Footprint: what Activity Monitor shows. RSS includes shared framework pages."

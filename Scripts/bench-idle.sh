#!/bin/bash
#
# Idle-CPU benchmark. The numbers this prints are the ones quoted in the README.
#
# Method, stated so the figures can be reproduced and argued with:
#   * Samples `ps -o %cpu` for the NotchBuddy process every second for N seconds.
#     %cpu from ps is a per-process average since the last sample, normalised to
#     one core, which is the same basis Activity Monitor uses.
#   * Runs several windows and reports each, because a single 10-second window
#     can be dominated by one unlucky wakeup.
#   * Also reports RSS (resident memory) via `ps -o rss`, in MB.
#
# Yes, this shells out -- and that is fine. The rule about not spawning processes
# applies to the *app's* runtime behaviour on a timer, not to a developer tool
# that runs a few dozen times total. Using ps here also means the figures are
# produced by something outside the app, which is the point: a benchmark the app
# reports about itself is not evidence.
#
# Usage:  Scripts/bench-idle.sh [seconds-per-window] [windows]
set -euo pipefail

WINDOW="${1:-10}"
RUNS="${2:-3}"
PROC="NotchBuddy"

PID=$(pgrep -x "$PROC" | head -1 || true)
if [ -z "$PID" ]; then
  echo "NotchBuddy is not running. Start it first:  open dist/NotchBuddy.app" >&2
  exit 1
fi

echo "NotchBuddy idle benchmark"
echo "  pid            $PID"
echo "  window         ${WINDOW}s"
echo "  windows        $RUNS"
echo "  machine        $(sysctl -n machdep.cpu.brand_string)"
echo "  macOS          $(sw_vers -productVersion)"
echo ""
printf "%-8s %10s %10s %10s\n" "window" "mean%cpu" "peak%cpu" "rss(MB)"
printf "%-8s %10s %10s %10s\n" "------" "--------" "--------" "-------"

TOTAL=0
for run in $(seq 1 "$RUNS"); do
  SUM=0; PEAK=0; COUNT=0; RSS=0
  for _ in $(seq 1 "$WINDOW"); do
    sleep 1
    READ=$(ps -o %cpu=,rss= -p "$PID" 2>/dev/null || echo "0 0")
    CPU=$(echo "$READ" | awk '{print $1}')
    RSS=$(echo "$READ" | awk '{print $2}')
    SUM=$(echo "$SUM + $CPU" | bc -l)
    PEAK=$(echo "if ($CPU > $PEAK) $CPU else $PEAK" | bc -l)
    COUNT=$((COUNT + 1))
  done
  MEAN=$(echo "scale=3; $SUM / $COUNT" | bc -l)
  RSSMB=$(echo "scale=1; $RSS / 1024" | bc -l)
  TOTAL=$(echo "$TOTAL + $MEAN" | bc -l)
  printf "%-8s %10s %10s %10s\n" "$run" "$MEAN" "$PEAK" "$RSSMB"
done

OVERALL=$(echo "scale=3; $TOTAL / $RUNS" | bc -l)
echo ""
echo "  overall mean:  ${OVERALL}% of one core"
echo ""
echo "Run this three ways and record all three in docs/BENCHMARKS.md:"
echo "  1. panel collapsed, nothing open      <- the number that matters"
echo "  2. panel expanded on the Home tab     <- stats rings polling at 2s"
echo "  3. panel expanded on the Terminal tab <- pty alive, idle shell"

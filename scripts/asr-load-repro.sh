#!/bin/bash
# Make a slow dictation happen on purpose.
#
# The most useful thing this investigation produced. Slow dictations were once
# something you waited days to catch; under this load they appear within a
# minute, which turns every claim about dictation speed into something checkable
# instead of something argued.
#
# Saturates every core and keeps the disk busy, for a bounded time, then stops
# by itself. Nothing is left running — a load generator that outlives its
# experiment is how a machine ends up mysteriously slow.
#
#   ./scripts/asr-load-repro.sh 90 both
#   ./scripts/asr-load-repro.sh 90 cpu
#   ./scripts/asr-load-repro.sh 90 disk
#
# Dictate while it runs, then read the result with ./scripts/asr-profile.sh 5m

set -euo pipefail
SECONDS_TO_RUN="${1:-90}"
MODE="${2:-both}"
CORES=$(sysctl -n hw.ncpu)

case "$MODE" in
  cpu|disk|both) ;;
  *) echo "usage: $0 [seconds] [cpu|disk|both]" >&2; exit 2 ;;
esac

cleanup() {
  pkill -f "openramble-load-cpu" 2>/dev/null || true
  pkill -f "openramble-load-disk" 2>/dev/null || true
  rm -f /tmp/openramble-load.bin
}
trap cleanup EXIT INT TERM

echo "Applying $MODE pressure for ${SECONDS_TO_RUN}s ($CORES logical cores)."
echo "Dictate now — several phrases, short and long."
echo

if [ "$MODE" = cpu ] || [ "$MODE" = both ]; then
  for _ in $(seq 1 "$CORES"); do
    ( exec -a openramble-load-cpu timeout "$SECONDS_TO_RUN" yes > /dev/null 2>&1 ) &
  done
fi

# Disk pressure as well: the stalls were never explained by CPU alone, and a
# reproduction that only presses one resource proves less than it appears to.
if [ "$MODE" = disk ] || [ "$MODE" = both ]; then
  (
    exec -a openramble-load-disk timeout "$SECONDS_TO_RUN" sh -c '
      while :; do
        dd if=/dev/zero of=/tmp/openramble-load.bin bs=4m count=40 2>/dev/null
        sync
      done
    '
  ) &
fi

sleep 3
echo "load average now: $(uptime | sed -E 's/.*averages?: //')"
wait
echo
echo "Load stopped. Read the result:"
echo "  ./scripts/asr-profile.sh 5m"

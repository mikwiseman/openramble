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
#   ./scripts/asr-load-repro.sh          # 90 seconds
#   ./scripts/asr-load-repro.sh 180
#
# Dictate while it runs, then read the result with ./scripts/asr-profile.sh 5m

set -euo pipefail
SECONDS_TO_RUN="${1:-90}"
CORES=$(sysctl -n hw.ncpu)

cleanup() {
  pkill -f "openramble-load-cpu" 2>/dev/null || true
  rm -f /tmp/openramble-load.bin
}
trap cleanup EXIT INT TERM

echo "Loading $CORES cores and the disk for ${SECONDS_TO_RUN}s."
echo "Dictate now — several phrases, short and long."
echo

for _ in $(seq 1 "$CORES"); do
  ( exec -a openramble-load-cpu timeout "$SECONDS_TO_RUN" yes > /dev/null 2>&1 ) &
done

# Disk pressure as well: the stalls were never explained by CPU alone, and a
# reproduction that only presses one resource proves less than it appears to.
(
  exec -a openramble-load-cpu timeout "$SECONDS_TO_RUN" sh -c '
    while :; do
      dd if=/dev/urandom of=/tmp/openramble-load.bin bs=4m count=40 2>/dev/null
      sync
    done
  '
) &

sleep 3
echo "load average now: $(uptime | sed -E 's/.*averages?: //')"
wait
echo
echo "Load stopped. Read the result:"
echo "  ./scripts/asr-profile.sh 5m"

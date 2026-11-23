#!/bin/bash
# Peak memory footprint of one 30-second recognition in the iOS Simulator,
# read from the host with footprint(1) while the tool runs.
set -u
cd "$(dirname "$0")"
UDID=$(cat sim-udid)
M=$HOME/.openramble/release-models/parakeet-ultra-gguf/a1539be1b849ea7463b88343e5277b373d0c4ea9/parakeet-ultra-gguf/parakeet-ultra-Q4_K_M.gguf
CLIP=$HOME/.openramble/polish-loop/fleurs/en_us/1904-000.wav
for tool in ore-cli tcpp-probe; do
  while [ -e ~/.openramble/release-window ]; do sleep 30; done
  xcrun simctl spawn "$UDID" "$PWD/build/ore-sim/$tool.app/$tool" time "$M" "$CLIP" 4 5 30 > /dev/null 2>&1 &
  last="not seen"
  for _ in $(seq 1 100); do ps -axo pid=,comm= | awk -v t="$tool.app/$tool" 'index($2, t)' | grep -q . && break; sleep 0.1; done
  for _ in $(seq 1 600); do
    pid=$(ps -axo pid=,comm= | awk -v t="$tool.app/$tool" 'index($2, t) {print $1; exit}')
    [ -z "$pid" ] && break
    value=$(footprint -p "$pid" 2>/dev/null | awk '/phys_footprint_peak/ {print $2, $3}')
    [ -n "$value" ] && last="$value"
    sleep 0.2
  done
  wait
  echo "$tool peak footprint, 30 s clip, 4 threads: $last"
done

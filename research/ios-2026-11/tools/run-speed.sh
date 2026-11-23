#!/bin/bash
# Whole recognitions in the iOS Simulator, our engine against transcribe.cpp
# (CPU), interleaved round by round; best of 3 per round. Stops while another
# chat ships a release.
set -u
cd "$(dirname "$0")"
UDID=$(cat sim-udid)
M=$HOME/.openramble/release-models/parakeet-ultra-gguf/a1539be1b849ea7463b88343e5277b373d0c4ea9/parakeet-ultra-gguf/parakeet-ultra-Q4_K_M.gguf
CLIP=$HOME/.openramble/polish-loop/fleurs/en_us/1904-000.wav
for round in 1 2 3; do
  for threads in 2 4; do
    while [ -e ~/.openramble/release-window ]; do sleep 30; done
    echo "## round $round ore threads $threads $(date +%T) load $(sysctl -n vm.loadavg)"
    xcrun simctl spawn "$UDID" "$PWD/build/ore-sim/ore-cli.app/ore-cli" time "$M" "$CLIP" $threads 3 2 8 30
    while [ -e ~/.openramble/release-window ]; do sleep 30; done
    echo "## round $round tcpp threads $threads $(date +%T) load $(sysctl -n vm.loadavg)"
    xcrun simctl spawn "$UDID" "$PWD/build/ore-sim/tcpp-probe.app/tcpp-probe" time "$M" "$CLIP" $threads 3 2 8 30
  done
done
echo SPEED-DONE

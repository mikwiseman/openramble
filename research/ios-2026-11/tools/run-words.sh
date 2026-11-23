#!/bin/bash
# FLEURS word dumps inside the iOS Simulator: our engine on every clip, then
# transcribe.cpp (CPU) on the 200-clip English subset the ledger used.
set -u
cd "$(dirname "$0")"
UDID=$(cat sim-udid)
M=$HOME/.openramble/release-models/parakeet-ultra-gguf/a1539be1b849ea7463b88343e5277b373d0c4ea9/parakeet-ultra-gguf/parakeet-ultra-Q4_K_M.gguf
for l in en_us ru_ru; do
  xcrun simctl spawn "$UDID" "$PWD/build/ore-sim/ore-cli.app/ore-cli" dump "$M" "$PWD/data/$l.list" 4 > "data/$l.ore-ios.tsv" 2> "data/$l.ore-ios.err"
  echo "$l done $(date +%T)"
done
xcrun simctl spawn "$UDID" "$PWD/build/ore-sim/tcpp-probe.app/tcpp-probe" dump "$M" "$PWD/data/en200.list" 4 > "data/en200.tcpp-ios.tsv" 2> "data/en200.tcpp-ios.err"
echo "WORDS-DONE $(date +%T)"

#!/bin/bash
# The stress lab: the shipping dictation path under load, one command.
#
#   ./scripts/stress-lab.sh <label> [conditions]      e.g. ./scripts/stress-lab.sh after quiet,cpu
#
# Runs OpenRambleTests/StressLab, which builds the real AppState with the real
# microphone, model, HUD and paste, presses the key in code and replaces the
# microphone's samples with a recorded sentence (nothing the room says is kept).
# Conditions: quiet, cpu (one busy process per logical CPU), memory (a bounded
# 8 GB hog of hot, incompressible pages), both, idle (the hog, then a take after
# each 240 s of rest). Results: $STRESS_LAB_OUT (research/stress-lab-2026-10/data
# by default), one JSON line per take and a summary table per label.
#
# It opens the built-in microphone (the menu bar shows it) and loads the Mac for
# several minutes. It never asks for a permission: without microphone access for
# this terminal it skips.
set -euo pipefail
cd "$(dirname "$0")/.."

label="${1:?usage: stress-lab.sh <label> [conditions]}"
conditions="${2:-quiet,cpu,memory,both,idle}"
out="${STRESS_LAB_OUT:-$PWD/research/stress-lab-2026-10/data}"
engine="${STRESS_LAB_ENGINE:-$HOME/Library/Application Support/OpenRamble/Models/parakeet-ultra-gguf/a1539be1b849ea7463b88343e5277b373d0c4ea9/parakeet-ultra-gguf}"
[[ -f "$engine/parakeet-ultra-Q4_K_M.gguf" ]] || { echo "No installed model at $engine; set STRESS_LAB_ENGINE."; exit 69; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -O2 -o "$work/hog" research/idle-swap-2026-10/hog.c

short="Please move the meeting to Thursday afternoon and send the notes to the team."
long="I went through the release notes this morning and most of them read well. [[slnc 900]] The part about the microphone needs one more sentence on what changed for people with headsets. [[slnc 900]] Then we should check the translation before Friday, because the Russian page is still behind. [[slnc 900]] Last thing, please remind me to call the printer about the invoice from last week."
say -o "$work/short.wav" --data-format=LEF32@48000 "$short"
say -o "$work/long.wav" --data-format=LEF32@48000 "$long"
long_text=$(sed 's/\[\[slnc [0-9]*\]\]//g' <<<"$long")

./scripts/build-ffi.sh > /dev/null
(cd apps/macos && "$(../../scripts/pinned-xcodegen.sh)" generate > /dev/null \
  && xcodebuild -project OpenRamble.xcodeproj -scheme OpenRamble -destination 'platform=macOS,arch=arm64' \
       CODE_SIGNING_ALLOWED=NO build-for-testing > "$work/build.log" 2>&1) \
  || { grep -E "error:" "$work/build.log" | head; exit 1; }
products=$(cd apps/macos && xcodebuild -project OpenRamble.xcodeproj -scheme OpenRamble \
  -destination 'platform=macOS,arch=arm64' -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
mkdir -p "$out"
# xctest is started from here rather than by xcodebuild: the test runner xcodebuild
# launches does not inherit this terminal's microphone access, and the lab skips
# rather than ask.
echo "load before: $(uptime)"
STRESS_LAB_LABEL="$label" \
STRESS_LAB_OUT="$out" \
STRESS_LAB_ENGINE="$engine" \
STRESS_LAB_SHORT="$work/short.wav" \
STRESS_LAB_SHORT_TEXT="$short" \
STRESS_LAB_LONG="$work/long.wav" \
STRESS_LAB_LONG_TEXT="$long_text" \
STRESS_LAB_HOG="$work/hog" \
STRESS_LAB_CONDITIONS="$conditions" \
STRESS_LAB_TAKES="${STRESS_LAB_TAKES:-12}" \
STRESS_LAB_IDLE_TAKES="${STRESS_LAB_IDLE_TAKES:-3}" \
STRESS_LAB_IDLE_SECONDS="${STRESS_LAB_IDLE_SECONDS:-240}" \
  xcrun xctest -XCTest OpenRambleTests.StressLab/testDictationUnderStress "$products/OpenRambleTests.xctest" 2>&1 \
  | grep -E "stress-lab |^\||^###|error:|skipped|Executed" || true
echo "Takes: $out/$label-takes.jsonl"

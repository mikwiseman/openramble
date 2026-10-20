#!/usr/bin/env bash
# Measure first-word capture through the shipping MicrophoneCapture.
#
#   ./run.sh                      # default input (what the app uses with no choice)
#   ./run.sh --device AirPods     # a named input, as if picked in Settings
#   ./run.sh --breakdown 10       # where the start-up time goes, no playback
#
# The Mac speaks a short TTS sentence through its built-in speakers about 100
# times over ten minutes, so keep the room quiet and the output volume as it
# is. Results are numbers only, appended under results/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
label="${LABEL:-$(date +%Y%m%d-%H%M%S)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift build -c release --package-path "$here/onset-harness" >/dev/null
harness="$here/onset-harness/.build/release/first-word-onset"

say -v Samantha -o "$work/clip.wav" --file-format=WAVE --data-format=LEF32@48000 \
    "Hello, please send the report to Maria."

mkdir -p "$here/results"
"$harness" --clip "$work/clip.wav" --out "$here/results/$label.jsonl" "$@"
python3 "$here/summarize.py" "$here/results/$label.jsonl"

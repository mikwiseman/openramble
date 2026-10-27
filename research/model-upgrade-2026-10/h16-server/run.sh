#!/bin/bash
# H16 rules 9 and 10: the Linux server on its old and new runtime, in an arm64
# container held to wai-stt's size (4 CPUs, 8 GB).
#
#   research/model-upgrade-2026-10/h16-server/run.sh <before-commit> <after-commit>
#
# Builds `openramble` at both commits, transcribes two public hour files in
# file mode with four workers, then loads `serve` with four engines and sends it
# one of them. Results land in out/; score.py turns them into results.json.
set -euo pipefail
cd "$(dirname "$0")"
root=${SCORECARD_ROOT:-$HOME/Library/Caches/OpenRambleScorecard}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for pair in "before:$1" "after:$2"; do
  mkdir -p "$work/${pair%%:*}"
  git -C ../../.. archive "${pair#*:}" | tar -x -C "$work/${pair%%:*}"
done
mkdir -p out

docker build --platform linux/arm64 -t openramble-h16 .
docker run --rm --platform linux/arm64 -v "$work:/src:ro" -v "$PWD/out:/out" \
  -v openramble-h16-target:/target -v openramble-h16-cargo:/usr/local/cargo/registry \
  openramble-h16 /measure.sh build
docker run --rm --platform linux/arm64 --cpus 4 --memory 8g -v "$PWD/out:/out" \
  -v "$root/models/parakeet-ultra-Q4_K_M:/models:ro" -v "$root/corpus/composite:/audio:ro" \
  openramble-h16 /measure.sh run
uv run --quiet --with jiwer==4.0.0 python -I score.py "$root" out results.json

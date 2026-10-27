#!/bin/bash
# H16 rules 9 and 10: the Linux server on its old and new runtime, in an arm64
# container held to wai-stt's size (4 CPUs, 8 GB).
#
#   research/model-upgrade-2026-10/h16-server/run.sh build <before-commit> <after-commit>
#   research/model-upgrade-2026-10/h16-server/run.sh measure
#
# `build` compiles `openramble` at both commits into out/bin. `measure`
# transcribes two public hour files in file mode with four workers, then loads
# `serve` with four engines and sends it one of them, and score.py writes
# results.json. Two steps, so the compiling never overlaps a timed run.
set -euo pipefail
cd "$(dirname "$0")"
root=${SCORECARD_ROOT:-$HOME/Library/Caches/OpenRambleScorecard}
mkdir -p out

case "${1:?usage: run.sh build <before> <after> | measure}" in
  build)
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    for pair in "before:${2:?}" "after:${3:?}"; do
      mkdir -p "$work/${pair%%:*}"
      git -C ../../.. archive "${pair#*:}" | tar -x -C "$work/${pair%%:*}"
    done
    docker build --platform linux/arm64 -t openramble-h16 .
    docker run --rm --platform linux/arm64 -v "$work:/src:ro" -v "$PWD/out:/out" \
      -v openramble-h16-target:/target -v openramble-h16-cargo:/usr/local/cargo/registry \
      openramble-h16 /measure.sh build
    ;;
  measure)
    docker run --rm --platform linux/arm64 --cpus 4 --memory 8g -v "$PWD/out:/out" \
      -v "$root/models/parakeet-ultra-Q4_K_M:/models:ro" -v "$root/corpus/composite:/audio:ro" \
      openramble-h16 /measure.sh run
    uv run --quiet --with jiwer==4.0.0 python -I score.py "$root" out results.json
    ;;
esac

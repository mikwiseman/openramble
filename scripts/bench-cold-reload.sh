#!/bin/bash
# Reload-economics measurement harness (dev-only, no network).
#
# Produces JSONL for the scenarios the residency work must move:
#   warm-reload    in-process unload→prepare→warm cycles (keep-worker-alive cost)
#   fresh-process  re-executed single-load per iteration (respawn cost on top)
#   clone-cold     single-load against an APFS clone at a fresh path — a new
#                  absolute path is a new CoreML/ANE specialization cache key,
#                  so this reproduces the eviction cliff WITHOUT purging any
#                  host cache. Built-in A/B/B2 validation: clone-first must be
#                  far slower than clone-second and original.
#   placements     fresh-process single-load across automatic|neuralEngine|gpu
#
# Usage: scripts/bench-cold-reload.sh [--iterations N] [--pressure warn|critical]
#                                     [--scenario all|warm-reload|fresh-process|clone-cold|placements]
# Requires: the model installed (asr-bench status), release build tolerated.
set -euo pipefail

ITERATIONS=3
PRESSURE=""
SCENARIO="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --pressure) PRESSURE="$2"; shift 2 ;;
    --scenario) SCENARIO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/Packages/LocalASR/.build/release/asr-bench"

echo "→ building asr-bench (release)" >&2
swift build --package-path "$ROOT/Packages/LocalASR" -c release --product asr-bench >&2

MODEL_DIR="$("$BENCH" status | sed -n 's/^Model ready: //p' | head -1)"
if [ -z "$MODEL_DIR" ]; then
  echo "model is not installed; run: asr-bench install" >&2
  exit 69
fi
# `status` prints the installed revision root; the engine bundle the loader
# validates lives one level deeper.
if [ -d "$MODEL_DIR/parakeet-tdt-0.6b-v3" ]; then
  MODEL_DIR="$MODEL_DIR/parakeet-tdt-0.6b-v3"
fi
echo "→ engine bundle: $MODEL_DIR" >&2

# The probe measures the engine alone; the vocabulary phase is a separate,
# much smaller reload and would blur the per-phase attribution.
export WAI_VOCAB=off

PRESSURE_PID=""
cleanup() {
  if [ -n "$PRESSURE_PID" ] && kill -0 "$PRESSURE_PID" 2>/dev/null; then
    kill "$PRESSURE_PID" 2>/dev/null || true
    wait "$PRESSURE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -n "$PRESSURE" ]; then
  echo "→ simulating memory pressure: $PRESSURE" >&2
  memory_pressure -S -l "$PRESSURE" >/dev/null 2>&1 &
  PRESSURE_PID=$!
  export WAI_BENCH_PRESSURE="$PRESSURE"
  sleep 2
fi

meta() {
  local chip build
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
  build="$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
  printf '{"meta":true,"chip":"%s","os_build":"%s","iterations":%s,"pressure":"%s"}\n' \
    "$chip" "$build" "$ITERATIONS" "${PRESSURE:-none}"
}
meta

run_warm_reload() {
  echo "→ warm-reload ×$ITERATIONS" >&2
  "$BENCH" cold-reload --scenario warm-reload --iterations "$ITERATIONS"
}

run_fresh_process() {
  echo "→ fresh-process ×$ITERATIONS" >&2
  local i=0
  while [ "$i" -lt "$ITERATIONS" ]; do
    "$BENCH" cold-reload --scenario single-load \
      | sed "s/\"iteration\":0/\"iteration\":$i/; s/\"scenario\":\"single-load\"/\"scenario\":\"fresh-process\"/"
    i=$((i + 1))
  done
}

run_clone_cold() {
  local clone
  clone="$(mktemp -d /tmp/openramble-cold-reload.XXXXXX)/engine"
  echo "→ clone-cold: APFS clone at $clone" >&2
  cp -c -R "$MODEL_DIR" "$clone" 2>/dev/null || cp -R "$MODEL_DIR" "$clone"

  echo "→ A: original path (specialization cache warm)" >&2
  "$BENCH" cold-reload --scenario single-load \
    | sed 's/"scenario":"single-load"/"scenario":"clone-cold-A-original"/'
  echo "→ B: clone first load (expected slow: fresh cache key)" >&2
  WAI_ASR_MODEL_DIR="$clone" "$BENCH" cold-reload --scenario single-load \
    | sed 's/"scenario":"single-load"/"scenario":"clone-cold-B-first"/'
  echo "→ B2: clone second load (expected fast again)" >&2
  WAI_ASR_MODEL_DIR="$clone" "$BENCH" cold-reload --scenario single-load \
    | sed 's/"scenario":"single-load"/"scenario":"clone-cold-B2-second"/'

  rm -rf "$(dirname "$clone")"
}

run_placements() {
  for placement in automatic neuralEngine gpu; do
    echo "→ placement $placement (fresh process)" >&2
    WAI_ASR_ENCODER_PLACEMENT="$placement" "$BENCH" cold-reload --scenario single-load \
      | sed 's/"scenario":"single-load"/"scenario":"placement"/'
  done
}

case "$SCENARIO" in
  all)
    run_warm_reload
    run_fresh_process
    run_clone_cold
    run_placements
    ;;
  warm-reload) run_warm_reload ;;
  fresh-process) run_fresh_process ;;
  clone-cold) run_clone_cold ;;
  placements) run_placements ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 64 ;;
esac

#!/bin/bash
# Unsandboxed recognition with a DYLD interposer that records process-attributed
# DNS/connect/send calls. The control and ASR process share the same runner path.
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="${1:-.build-zero-network/probe.wav}"
EXPECTED="${WAI_EXPECTED_TEXT:-Проверка работы без интернета}"
BENCH=".build-zero-network/asr-bench"
TRACE_DYLIB=".build-zero-network/network-trace.dylib"
RUNNER=".build-zero-network/network-trace-runner"
TRACE=".build-zero-network/network.trace"

[[ -x "$BENCH" ]] || {
  swift build -c release --package-path Packages/LocalASR --product asr-bench >/dev/null
  mkdir -p .build-zero-network
  cp Packages/LocalASR/.build/release/asr-bench "$BENCH"
}
[[ -f "$FIXTURE" ]] || {
  say -v Milena -o .build-zero-network/probe.aiff "Проверка работы без интернета."
  afconvert -f WAVE -d LEI16@16000 -c 1 .build-zero-network/probe.aiff "$FIXTURE"
}

clang -Wall -Wextra -Werror -dynamiclib scripts/network-trace/interpose.c -o "$TRACE_DYLIB"
clang -Wall -Wextra -Werror scripts/network-trace/runner.c -o "$RUNNER"

: > "$TRACE"
WAI_NET_TRACE="$TRACE" DYLD_INSERT_LIBRARIES="$TRACE_DYLIB" "$RUNNER" --control
grep -q 'call=connect' "$TRACE" || {
  echo "ПРОВАЛ: tracer не увидел control-connect." >&2
  exit 1
}

: > "$TRACE"
OUTPUT=$(WAI_NET_TRACE="$TRACE" DYLD_INSERT_LIBRARIES="$TRACE_DYLIB" \
  "$RUNNER" "$BENCH" transcribe "$FIXTURE")
if [[ -s "$TRACE" ]]; then
  echo "ПРОВАЛ: recognition сделал сетевые вызовы:" >&2
  sed 's/^/  /' "$TRACE" >&2
  exit 1
fi
echo "$OUTPUT" | grep -Fqi "$EXPECTED" || {
  echo "ПРОВАЛ: recognition не вернул ожидаемую фразу: $EXPECTED" >&2
  exit 1
}
echo "Пройдено: tracer увидел control-connect и ноль DNS/connect/send у recognition."

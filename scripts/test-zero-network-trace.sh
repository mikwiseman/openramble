#!/bin/bash
# Prove recognition attempts no DNS/connect/send calls, with a positive control.
set -euo pipefail
cd "$(dirname "$0")/.."

PINNED_CARGO=$(rustup which --toolchain 1.97.1 cargo)
PINNED_RUSTC=$(rustup which --toolchain 1.97.1 rustc)
RUSTC="$PINNED_RUSTC" "$PINNED_CARGO" test --locked -p ramble-engine \
  --test transcribes_real_speech --no-run >/dev/null
TEST_BINARY=$(find target/debug/deps -type f -perm -111 -name 'transcribes_real_speech-*' \
  ! -name '*.d' -print | head -1)
[[ -x "$TEST_BINARY" ]] || { echo "The Rust recognition test binary is missing." >&2; exit 1; }

TEMP_DIRECTORY=$(mktemp -d -t openramble-network-trace)
cleanup() { rm -rf -- "$TEMP_DIRECTORY"; }
trap cleanup EXIT
TRACE_DYLIB="$TEMP_DIRECTORY/network-trace.dylib"
RUNNER="$TEMP_DIRECTORY/network-trace-runner"
TRACE="$TEMP_DIRECTORY/network.trace"
SUPPORT_ROOT="$TEMP_DIRECTORY/support"
MODELS_ROOT="${WAI_MODELS_ROOT:-$HOME/Library/Application Support/OpenRamble/Models}"
[[ -d "$MODELS_ROOT" ]] || { echo "No installed model at $MODELS_ROOT" >&2; exit 69; }
mkdir -p "$SUPPORT_ROOT"
ln -s "$MODELS_ROOT" "$SUPPORT_ROOT/Models"

clang -Wall -Wextra -Werror -dynamiclib scripts/network-trace/interpose.c -o "$TRACE_DYLIB"
clang -Wall -Wextra -Werror scripts/network-trace/runner.c -o "$RUNNER"
: > "$TRACE"
WAI_NET_TRACE="$TRACE" DYLD_INSERT_LIBRARIES="$TRACE_DYLIB" "$RUNNER" --control
grep -q 'call=connect' "$TRACE" || { echo "The network tracer missed its control call." >&2; exit 1; }

: > "$TRACE"
OUTPUT=$(OPENRAMBLE_SUPPORT_ROOT="$SUPPORT_ROOT" WAI_NET_TRACE="$TRACE" \
  DYLD_INSERT_LIBRARIES="$TRACE_DYLIB" "$RUNNER" "$TEST_BINARY" \
  --exact spoken_words_come_back_as_text --nocapture 2>&1)
[[ ! -s "$TRACE" ]] || {
  echo "Recognition attempted network calls:" >&2
  sed 's/^/  /' "$TRACE" >&2
  exit 1
}
printf '%s\n' "$OUTPUT" | grep -Fq 'heard:' || { echo "Recognition was skipped." >&2; exit 1; }
echo "Passed: the tracer saw its control connect and zero network calls from recognition."

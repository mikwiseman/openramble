#!/bin/bash
# Proof of the main promise: recognition works without a network.
#
# Checking the sources with grep shows only what we ourselves do not call
# network functions. It doesn't say anything about what dependencies do internally.
# Here the recognition is run in a sandbox with a completely denied network:
# if something tries to come out, it will fall.
#
# Run:
# ./scripts/test-zero-network.sh [.wav file]

set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE="${1:-}"
EXPECTED="${WAI_EXPECTED_TEXT:-Checking work without the Internet}"
BENCH=".build-zero-network/asr-bench"

echo "→ Assembling the tool"
swift build -c release --package-path Packages/LocalASR --product asr-bench 2>&1 | tail -1
mkdir -p .build-zero-network
cp "Packages/LocalASR/.build/release/asr-bench" "$BENCH"

# The model must already be installed: loading it is the only one allowed
# network operation, and we check what happens after it.
if ! "$BENCH" status >/dev/null 2>&1; then
  echo "Model not installed. First: Packages/LocalASR/.build/release/asr-bench install" >&2
  exit 69
fi

# If the recording was not sent, we make a short one ourselves.
if [[ -z "$FIXTURE" ]]; then
  FIXTURE=".build-zero-network/probe-en.wav"
  if [[ ! -f "$FIXTURE" ]]; then
    echo "→ Preparing a test recording"
    say -v Samantha -o ".build-zero-network/probe-en.aiff" "Checking work without the Internet."
    afconvert -f WAVE -d LEI16@16000 -c 1 ".build-zero-network/probe-en.aiff" "$FIXTURE"
  fi
fi

if [[ -n "${1:-}" && -z "${WAI_EXPECTED_TEXT:-}" ]]; then
  echo "For native WAV, set WAI_EXPECTED_TEXT - the check does not simply accept non-empty output." >&2
  exit 64
fi

echo "→ Running recognition in a sandbox without a network"

PROFILE=".build-zero-network/no-network.sb"
cat > "$PROFILE" <<'PROFILE_END'
(version 1)
(allow default)
;; Exactly what all this is for: any attempt to go online is prohibited.
(deny network*)
PROFILE_END

# Positive control: gate is not considered running until unified log
# assigned the real network deny to a specific curl process.
CONTROL_LOG=".build-zero-network/sandbox-control.log"
: > "$CONTROL_LOG"
/usr/bin/log stream --style compact --level debug \
  --predicate 'subsystem == "com.apple.sandbox.reporting" OR senderImagePath CONTAINS[c] "sandbox"' \
  > "$CONTROL_LOG" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT
sleep 1
sandbox-exec -f "$PROFILE" /usr/bin/curl --silent --show-error --connect-timeout 1 \
  https://example.com >/dev/null 2>&1 || true
sleep 1
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true
trap - EXIT
if ! grep -Eq 'Sandbox: curl\([0-9]+\) deny\([0-9]+\) network-' "$CONTROL_LOG"; then
  echo "FAIL: sandbox positive control did not appear in the process-attributed deny log." >&2
  exit 1
fi

set +e
OUTPUT=$(sandbox-exec -f "$PROFILE" "$BENCH" transcribe "$FIXTURE" 2>&1)
STATUS=$?
set -e

echo "$OUTPUT" | sed 's/^/  /'

if [[ $STATUS -ne 0 ]]; then
  echo ""
  echo "FAIL: recognition does not work without a network (code $STATUS)."
  echo "So something in the chain still goes online."
  exit 1
fi

# The `===` header proves nothing. We require the expected phrase.
if ! echo "$OUTPUT" | grep -Fqi "$EXPECTED"; then
  echo ""
  echo "FAIL: The result is no expected phrase: $EXPECTED"
  exit 1
fi

echo ""
echo "Passed: speech recognized on a completely restricted network."

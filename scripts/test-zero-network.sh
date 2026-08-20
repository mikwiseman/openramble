#!/bin/bash
# Prove the shipping Rust recognizer works while macOS denies all networking.
set -euo pipefail
cd "$(dirname "$0")/.."

PINNED_CARGO=$(rustup which --toolchain 1.97.1 cargo)
PINNED_RUSTC=$(rustup which --toolchain 1.97.1 rustc)
RUSTC="$PINNED_RUSTC" "$PINNED_CARGO" test --locked -p ramble-engine \
  --test transcribes_real_speech --no-run >/dev/null
TEST_BINARY=$(find target/debug/deps -type f -perm -111 -name 'transcribes_real_speech-*' \
  ! -name '*.d' -print | head -1)
[[ -x "$TEST_BINARY" ]] || { echo "The Rust recognition test binary is missing." >&2; exit 1; }

TEMP_DIRECTORY=$(mktemp -d -t openramble-offline-rust)
cleanup() { rm -rf -- "$TEMP_DIRECTORY"; }
trap cleanup EXIT
SUPPORT_ROOT="$TEMP_DIRECTORY/support"
mkdir -p "$SUPPORT_ROOT"
MODELS_ROOT="${WAI_MODELS_ROOT:-$HOME/Library/Application Support/OpenRamble/Models}"
[[ -d "$MODELS_ROOT" ]] || { echo "No installed model at $MODELS_ROOT" >&2; exit 69; }
ln -s "$MODELS_ROOT" "$SUPPORT_ROOT/Models"

PROFILE='(version 1) (allow default) (deny network*)'
sandbox-exec -p "$PROFILE" /usr/bin/python3 -c \
  'import errno,socket,sys
try: socket.socket().connect(("127.0.0.1", 9))
except PermissionError as error: sys.exit(0 if error.errno == errno.EPERM else 2)
except OSError: sys.exit(3)
sys.exit(4)'

set +e
OUTPUT=$(OPENRAMBLE_SUPPORT_ROOT="$SUPPORT_ROOT" sandbox-exec -p "$PROFILE" \
  "$TEST_BINARY" --exact spoken_words_come_back_as_text --nocapture 2>&1)
STATUS=$?
set -e
printf '%s\n' "$OUTPUT"
[[ $STATUS -eq 0 ]] || { echo "Recognition failed with network denied." >&2; exit "$STATUS"; }
printf '%s\n' "$OUTPUT" | grep -Fq 'heard:' || { echo "Recognition was skipped." >&2; exit 1; }
for word in checking work internet; do
  printf '%s\n' "$OUTPUT" | grep -Fqi "$word" || {
    echo "The transcript did not contain '$word'." >&2
    exit 1
  }
done
echo "Passed: the Rust recognizer returned the expected speech with networking denied."

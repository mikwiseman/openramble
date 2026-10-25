#!/bin/bash
# Build and install the OpenRamble transcription server on this machine.
#
# Run as root from a checkout: apps/cli/deploy/install.sh
#
# It builds here because ggml tunes itself to the processor it is built on.
# The new binary must pass --check-model (the model's size and SHA-256)
# before it replaces the old one, the old one is kept as .prev, and the
# service restarts only once no job is running, so no caller is told to come
# back. transcribe-stdin is replaced last, once the new server answers.
set -euo pipefail

PREFIX=/opt/openramble
BIN="$PREFIX/bin"
MODELS="$PREFIX/models/parakeet-ultra-gguf"
UNIT=/etc/systemd/system/openramble.service
HEALTH=http://127.0.0.1:8080/health

cd "$(dirname "$0")/../../.." || exit 1

fail() {
  echo "install.sh: $1" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || fail "run this as root"
[[ -f /etc/openramble/keys ]] || fail "/etc/openramble/keys is missing; docs/server.md says how to make it"
command -v ffmpeg > /dev/null || fail "ffmpeg is missing: apt-get install ffmpeg"
command -v curl > /dev/null || fail "curl is missing: apt-get install curl"
command -v cargo > /dev/null || fail "cargo is missing: install Rust with rustup"

cargo build --release --locked -p openramble-cli

install -d "$BIN"
install -m 0755 target/release/openramble "$BIN/openramble.new"
"$BIN/openramble.new" --check-model --model-dir "$MODELS" || {
  rm -f "$BIN/openramble.new"
  fail "the new build could not check the model; nothing was replaced"
}
if [[ -e "$BIN/openramble" ]]; then
  cp -p "$BIN/openramble" "$BIN/openramble.prev"
fi
mv "$BIN/openramble.new" "$BIN/openramble"

# One owner of the engines on this machine (apps/cli/src/engines.rs): the
# server holds this lock while its engines are loaded, and a file-mode run
# refuses to load engines next to them, since both would not fit in memory.
install -d -m 0755 /var/lib/openramble
[[ -e /var/lib/openramble/engines.lock ]] || install -m 0644 /dev/null /var/lib/openramble/engines.lock

install -m 0644 apps/cli/deploy/openramble.service "$UNIT"
systemctl daemon-reload
systemctl enable openramble.service

idle() {
  curl -fsS --max-time 5 "$HEALTH" 2> /dev/null | grep -qE '"jobs":0[,}]'
}

if curl -fsS --max-time 5 "$HEALTH" > /dev/null 2>&1; then
  echo "waiting up to 30 minutes for the running jobs to finish..."
  for _ in $(seq 360); do
    idle && break
    sleep 5
  done
fi
systemctl restart openramble.service

echo "waiting for the new server to load its engines..."
up=0
for _ in $(seq 180); do
  if curl -fsS --max-time 5 "$HEALTH" > /dev/null 2>&1; then
    up=1
    break
  fi
  sleep 1
done
[[ $up -eq 1 ]] || fail "the server did not answer /health; see journalctl -u openramble"
curl -fsS "$HEALTH"
echo

if [[ -e "$BIN/transcribe-stdin" ]]; then
  cp -p "$BIN/transcribe-stdin" "$BIN/transcribe-stdin.prev"
fi
install -m 0755 apps/cli/deploy/transcribe-stdin "$BIN/transcribe-stdin"
[[ -f /etc/openramble/ssh.header ]] \
  || echo "note: /etc/openramble/ssh.header is missing, so transcribe-stdin will get 401 until it exists"
echo "installed; the previous binary and transcribe-stdin are kept as .prev"

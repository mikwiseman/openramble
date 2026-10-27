#!/bin/bash
# Build and install the OpenRamble transcription server on this machine.
#
# Run as root from a checkout: apps/cli/deploy/install.sh
#
# It builds here because ggml tunes itself to the processor it is built on.
# The new binary must pass --check-model (the model's size and SHA-256)
# before it replaces the old one, the old one is kept as .prev, and the
# service restarts only once no job is running, so no caller is told to come
# back.
#
# The server becomes the only process here that keeps engines loaded: a
# second set would compete with its four for the same cores. The ssh transports
# that ran the command-line tool themselves, WaiWeb's transcribe-stdin and
# the school's stt-ssh, become clients of the server in the same step, while
# the lock they share is held, so none of their jobs runs next to the new
# server's engines. transcribe-stdin is replaced once it has carried a
# second of silence through the new server as the ssh user.
set -euo pipefail

PREFIX=/opt/openramble
BIN="$PREFIX/bin"
MODELS="$PREFIX/models/parakeet-ultra-gguf"
UNIT=/etc/systemd/system/openramble.service
HEALTH=http://127.0.0.1:8080/health
# The ssh path: the key file curl sends, the user the forced commands run as,
# the lock both transports take around a job, and the school's transport.
SSH_HEADER=/etc/openramble/ssh.header
SSH_USER=${SSH_USER:-stt}
SSH_LOCK=/var/lib/stt/engine.lock
SCHOOL_ENV=/etc/openramble-stt.env
STT_SSH=/opt/openramble-stt/bin/stt-ssh

fail() {
  echo "install.sh: $1" >&2
  exit 1
}

# Refuse, before anything is built or replaced, an ssh path that could not be
# finished: both transports need the key file once they go through the
# server, and the key file must go to the user their forced commands run as.
check_ssh_path() {
  if [[ -e "$BIN/transcribe-stdin" || -e "$STT_SSH" || -f "$SCHOOL_ENV" ]] && [[ ! -f "$SSH_HEADER" ]]; then
    fail "an ssh transport is installed but $SSH_HEADER is missing; make the ssh key first (docs/server.md, Keys)"
  fi
  if [[ -f "$SSH_HEADER" ]] && ! id -u "$SSH_USER" > /dev/null 2>&1; then
    fail "there is no user $SSH_USER; set SSH_USER to the user the ssh forced commands run as"
  fi
}

# The school's stt-ssh runs its engine as BIN, by default the command-line
# tool, which would load three engines next to the server's. Point it at
# transcribe-stdin, which sends the file to the server; stt-ssh keeps its
# lock, limits and clean-up. An engine this script does not know is left.
switch_school_transport() {
  [[ -f "$SCHOOL_ENV" || -e "$STT_SSH" ]] || return 0
  local current=""
  if [[ -f "$SCHOOL_ENV" ]]; then
    current=$(sed -n 's/^BIN=//p' "$SCHOOL_ENV" | tail -n 1)
  fi
  case "$current" in
    "$BIN/transcribe-stdin") return 0 ;;
    "" | /opt/openramble/bin/openramble) ;;
    *)
      echo "note: $SCHOOL_ENV runs BIN=$current, which this script does not know; left as it is"
      return 0
      ;;
  esac
  {
    if [[ -f "$SCHOOL_ENV" ]]; then
      cp -p "$SCHOOL_ENV" "$SCHOOL_ENV.prev"
      grep -v '^BIN=' "$SCHOOL_ENV" || true
    fi
    echo "BIN=$BIN/transcribe-stdin"
  } > "$SCHOOL_ENV.new"
  # stt-ssh reads only a root-owned file that nobody else can write
  chown root:root "$SCHOOL_ENV.new"
  chmod 0644 "$SCHOOL_ENV.new"
  mv "$SCHOOL_ENV.new" "$SCHOOL_ENV"
  echo "the school's stt-ssh now sends its audio to the server (BIN in $SCHOOL_ENV)"
}

idle() {
  curl -fsS --max-time 5 "$HEALTH" 2> /dev/null | grep -qE '"jobs":0[,}]'
}

main() {
  cd "$(dirname "$0")/../../.." || exit 1

  [[ $EUID -eq 0 ]] || fail "run this as root"
  [[ -f /etc/openramble/keys ]] || fail "/etc/openramble/keys is missing; docs/server.md says how to make it"
  for tool in ffmpeg curl cargo python3 flock runuser; do
    command -v "$tool" > /dev/null || fail "$tool is missing"
  done
  check_ssh_path

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
  # refuses to load engines next to them, since both would compete for the cores.
  install -d -m 0755 /var/lib/openramble
  [[ -e /var/lib/openramble/engines.lock ]] || install -m 0644 /dev/null /var/lib/openramble/engines.lock

  install -m 0644 apps/cli/deploy/openramble.service "$UNIT"
  systemctl daemon-reload
  systemctl enable openramble.service

  # Held until this script exits: an ssh job that is running finishes first,
  # and none starts until both transports go through the new server.
  if [[ -e "$SSH_LOCK" ]]; then
    exec 9< "$SSH_LOCK"
    echo "waiting up to 2 hours for a running ssh job to finish..."
    flock -w 7200 9 || fail "an ssh job still holds $SSH_LOCK; nothing was restarted"
  fi

  if curl -fsS --max-time 5 "$HEALTH" > /dev/null 2>&1; then
    echo "waiting up to 30 minutes for the running jobs to finish..."
    for _ in $(seq 360); do
      idle && break
      sleep 5
    done
  fi
  systemctl restart openramble.service

  echo "waiting for the new server to load its engines..."
  local up=0
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

  if [[ ! -f "$SSH_HEADER" ]]; then
    echo "installed; no $SSH_HEADER, so no ssh path (docs/server.md, Keys)"
    return
  fi
  # The forced commands run as $SSH_USER, and curl reads the key itself.
  chown "root:$(id -gn "$SSH_USER")" "$SSH_HEADER"
  chmod 0640 "$SSH_HEADER"
  install -m 0755 apps/cli/deploy/transcribe-stdin "$BIN/transcribe-stdin.new"
  local answer
  if ! answer=$(ffmpeg -v error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -f wav - \
    | runuser -u "$SSH_USER" -- "$BIN/transcribe-stdin.new") \
    || [[ $answer != *'"segments"'* ]]; then
    rm -f "$BIN/transcribe-stdin.new"
    fail "transcribe-stdin could not reach the server as $SSH_USER; the ssh path was not switched"
  fi
  if [[ -e "$BIN/transcribe-stdin" ]]; then
    cp -p "$BIN/transcribe-stdin" "$BIN/transcribe-stdin.prev"
  fi
  mv "$BIN/transcribe-stdin.new" "$BIN/transcribe-stdin"
  switch_school_transport
  echo "installed; the previous binary and transcribe-stdin are kept as .prev"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

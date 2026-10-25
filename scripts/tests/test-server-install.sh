#!/bin/bash
# install.sh makes the server the only process on the machine with engines:
# it refuses an ssh path it cannot finish, and it points the school's
# stt-ssh at the server. Checked on temporary files, without root, by
# sourcing the script's functions; the root-only steps (building, systemd,
# running the smoke test as the ssh user) run on the server itself.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# shellcheck source=../../apps/cli/deploy/install.sh
source "$REPOSITORY_ROOT/apps/cli/deploy/install.sh"
set +e
# not root here: ownership is the one thing these tests cannot set
chown() { :; }

BIN="$TEMP_DIRECTORY/bin"
SSH_HEADER="$TEMP_DIRECTORY/ssh.header"
SCHOOL_ENV="$TEMP_DIRECTORY/openramble-stt.env"
STT_SSH="$TEMP_DIRECTORY/stt-ssh"
mkdir -p "$BIN"

# --- the ssh path is checked before anything is built or replaced ----------

refused() {
  ( check_ssh_path ) > /dev/null 2>&1 && return 1
  return 0
}

SSH_USER="$(id -un)"
( check_ssh_path ) > /dev/null 2>&1 || fail_test "no ssh path at all was refused"
touch "$STT_SSH"
refused || fail_test "the school's stt-ssh without the key file was not refused"
rm "$STT_SSH"
touch "$BIN/transcribe-stdin"
refused || fail_test "WaiWeb's transcribe-stdin without the key file was not refused"
printf 'xi-api-key: x\n' > "$SSH_HEADER"
( check_ssh_path ) > /dev/null 2>&1 || fail_test "a key file and an existing ssh user were refused"
SSH_USER=no-such-user-openramble-test
refused || fail_test "a key file for a user that does not exist was not refused"
SSH_USER="$(id -un)"

# --- the school's stt-ssh is pointed at the server --------------------------

cat > "$SCHOOL_ENV" <<'EOF'
BIN=/opt/openramble/bin/openramble
MODEL_DIR=/opt/openramble/models/parakeet-ultra-gguf
WORKERS=3
EOF
cp "$SCHOOL_ENV" "$TEMP_DIRECTORY/original"
switch_school_transport > /dev/null || fail_test "switching the school failed"
grep -qx "BIN=$BIN/transcribe-stdin" "$SCHOOL_ENV" || fail_test "BIN was not pointed at transcribe-stdin"
[[ $(grep -c '^BIN=' "$SCHOOL_ENV") -eq 1 ]] || fail_test "BIN appears twice"
grep -qx 'WORKERS=3' "$SCHOOL_ENV" && grep -qx 'MODEL_DIR=/opt/openramble/models/parakeet-ultra-gguf' "$SCHOOL_ENV" \
  || fail_test "the school's other settings were lost"
cmp -s "$TEMP_DIRECTORY/original" "$SCHOOL_ENV.prev" || fail_test "the old settings were not kept as .prev"
[[ -n $(find "$SCHOOL_ENV" -perm 0644) ]] || fail_test "stt-ssh refuses a settings file that is not 0644"

cp "$SCHOOL_ENV" "$TEMP_DIRECTORY/switched"
switch_school_transport > /dev/null
cmp -s "$TEMP_DIRECTORY/switched" "$SCHOOL_ENV" || fail_test "a second run changed the settings again"

# stt-ssh's default engine, when the file names none
printf 'WORKERS=3\n' > "$SCHOOL_ENV"
switch_school_transport > /dev/null
grep -qx "BIN=$BIN/transcribe-stdin" "$SCHOOL_ENV" || fail_test "the default engine was not replaced"

# an engine this script does not know is the operator's choice
printf 'BIN=/usr/local/bin/something-else\n' > "$SCHOOL_ENV"
switch_school_transport > /dev/null
grep -qx 'BIN=/usr/local/bin/something-else' "$SCHOOL_ENV" || fail_test "an unknown engine was overwritten"

# stt-ssh installed without a settings file runs the default engine
rm -f "$SCHOOL_ENV" "$SCHOOL_ENV.prev"
touch "$STT_SSH"
switch_school_transport > /dev/null
grep -qx "BIN=$BIN/transcribe-stdin" "$SCHOOL_ENV" || fail_test "a missing settings file was not created"

# no school transport: nothing is created
rm -f "$SCHOOL_ENV" "$STT_SSH"
switch_school_transport > /dev/null
[[ ! -e $SCHOOL_ENV ]] || fail_test "settings were created for a transport that is not installed"

echo "install.sh: the ssh path and the school's transport behave"

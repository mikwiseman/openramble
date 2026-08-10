#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIRECTORY="$(mktemp -d)"

cleanup() {
  local exit_code=$?
  find "$TEST_DIRECTORY" -type f -delete 2>/dev/null || true
  find "$TEST_DIRECTORY" -depth -type d -delete 2>/dev/null || true
  exit "$exit_code"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

KEYCHAIN="$TEST_DIRECTORY/release.keychain-db"
PASSWORD_FILE="$TEST_DIRECTORY/release-keychain-password"
SECURITY_LOG="$TEST_DIRECTORY/security.log"
SECURITY_MOCK="$TEST_DIRECTORY/security"
IDENTITY_FINGERPRINT="1234567890ABCDEF1234567890ABCDEF12345678"

printf 'encrypted-keychain-fixture' > "$KEYCHAIN"
printf 'non-secret-test-password' > "$PASSWORD_FILE"
chmod 600 "$KEYCHAIN" "$PASSWORD_FILE"

cat > "$SECURITY_MOCK" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$SECURITY_LOG"
case "$1" in
  unlock-keychain)
    exit 0
    ;;
  list-keychains)
    if [[ "$*" != *" -s "* ]]; then
      printf '    "%s"\n' "$LOGIN_KEYCHAIN"
    fi
    ;;
  find-identity)
    printf '  1) %s "Developer ID Application: WaiWai, LLC (R4A779QVVY)"\n' \
      "$IDENTITY_FINGERPRINT"
    printf '     1 valid identities found\n'
    ;;
  *)
    exit 64
    ;;
esac
MOCK
chmod +x "$SECURITY_MOCK"

export SECURITY_LOG LOGIN_KEYCHAIN="$TEST_DIRECTORY/login.keychain-db"
export IDENTITY_FINGERPRINT
RELEASE_KEYCHAIN_PATH="$KEYCHAIN"
RELEASE_KEYCHAIN_PASSWORD_PATH="$PASSWORD_FILE"
SECURITY_BIN="$SECURITY_MOCK"
DEVELOPER_ID=""

# shellcheck source=../lib/release-keychain.sh
source "$REPOSITORY_ROOT/scripts/lib/release-keychain.sh"
load_release_keychain || fail_test "valid release keychain was rejected"

[[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]] \
  || fail_test "release keychain was not activated"
[[ "$DEVELOPER_ID" == "$IDENTITY_FINGERPRINT" ]] \
  || fail_test "Developer ID was not pinned to the release identity fingerprint"
[[ "${CODESIGN_KEYCHAIN_ARGS[*]}" == "--keychain $KEYCHAIN" ]] \
  || fail_test "codesign keychain arguments are wrong"
[[ "${XCODE_KEYCHAIN_SIGN_ARGS[*]}" == "OTHER_CODE_SIGN_FLAGS=--keychain $KEYCHAIN" ]] \
  || fail_test "Xcode keychain arguments are wrong"
grep -Fq "unlock-keychain -p non-secret-test-password $KEYCHAIN" "$SECURITY_LOG" \
  || fail_test "release keychain was not unlocked"
grep -Fq "list-keychains -d user -s $KEYCHAIN $LOGIN_KEYCHAIN" "$SECURITY_LOG" \
  || fail_test "release keychain was not added to the search list"

chmod 644 "$PASSWORD_FILE"
if load_release_keychain >/dev/null 2>&1; then
  fail_test "insecure password-file permissions were accepted"
fi

printf 'PASS: autonomous release keychain\n'

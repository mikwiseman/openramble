#!/bin/bash
# Non-interactive Developer ID keychain for release builds.
#
# The keychain is deliberately separate from login.keychain: release scripts
# can unlock it from a mode-0600 file without a SecurityAgent prompt, while
# ordinary applications keep using the user's normal keychain.

RELEASE_KEYCHAIN_PATH="${RELEASE_KEYCHAIN_PATH:-$HOME/.openramble/release.keychain-db}"
RELEASE_KEYCHAIN_PASSWORD_PATH="${RELEASE_KEYCHAIN_PASSWORD_PATH:-$HOME/.openramble/release-keychain-password}"
SECURITY_BIN="${SECURITY_BIN:-security}"
RELEASE_KEYCHAIN_ACTIVE=0
CODESIGN_KEYCHAIN_ARGS=()
XCODE_KEYCHAIN_SIGN_ARGS=()

release_keychain_error() {
  printf 'Release keychain: %s\n' "$1" >&2
  return 1
}

release_keychain_mode() {
  stat -f '%Lp' "$1"
}

ensure_release_keychain_in_search_list() {
  local line keychain found=0
  local -a keychains
  keychains=()

  while IFS= read -r line; do
    keychain="${line#*\"}"
    keychain="${keychain%\"*}"
    [[ -n "$keychain" ]] || continue
    [[ "$keychain" == "$RELEASE_KEYCHAIN_PATH" ]] && found=1
    keychains+=("$keychain")
  done < <("$SECURITY_BIN" list-keychains -d user)

  if [[ "$found" == "0" ]]; then
    "$SECURITY_BIN" list-keychains -d user -s \
      "$RELEASE_KEYCHAIN_PATH" "${keychains[@]}"
  fi
}

load_release_keychain() {
  local password identity_output identity_line identity_fingerprint identity_name

  RELEASE_KEYCHAIN_ACTIVE=0
  CODESIGN_KEYCHAIN_ARGS=()
  XCODE_KEYCHAIN_SIGN_ARGS=()

  if [[ ! -e "$RELEASE_KEYCHAIN_PATH" && ! -e "$RELEASE_KEYCHAIN_PASSWORD_PATH" ]]; then
    return 0
  fi

  [[ -f "$RELEASE_KEYCHAIN_PATH" ]] \
    || release_keychain_error "no $RELEASE_KEYCHAIN_PATH." || return 1
  [[ -f "$RELEASE_KEYCHAIN_PASSWORD_PATH" ]] \
    || release_keychain_error "no $RELEASE_KEYCHAIN_PASSWORD_PATH." || return 1
  [[ "$(release_keychain_mode "$RELEASE_KEYCHAIN_PATH")" == "600" ]] \
    || release_keychain_error "$RELEASE_KEYCHAIN_PATH must have mode 0600." || return 1
  [[ "$(release_keychain_mode "$RELEASE_KEYCHAIN_PASSWORD_PATH")" == "600" ]] \
    || release_keychain_error "$RELEASE_KEYCHAIN_PASSWORD_PATH must have mode 0600." || return 1

  IFS= read -r password < "$RELEASE_KEYCHAIN_PASSWORD_PATH"
  [[ -n "$password" ]] \
    || release_keychain_error "password file is empty." || return 1

  "$SECURITY_BIN" unlock-keychain -p "$password" "$RELEASE_KEYCHAIN_PATH" \
    || release_keychain_error "Failed to release keychain." || return 1
  ensure_release_keychain_in_search_list \
    || release_keychain_error "Failed to add keychain to search list." || return 1

  identity_output=$("$SECURITY_BIN" find-identity -v -p codesigning "$RELEASE_KEYCHAIN_PATH") \
    || release_keychain_error "could not read signing identities." || return 1
  identity_line=$(printf '%s\n' "$identity_output" \
    | sed -n '/Developer ID Application:/p' \
    | head -1)
  identity_fingerprint=$(printf '%s\n' "$identity_line" \
    | sed -n 's/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) .*/\1/p')
  identity_name=$(printf '%s\n' "$identity_line" \
    | sed -n 's/^.*"\(Developer ID Application:[^"]*\)".*$/\1/p')
  [[ -n "$identity_fingerprint" && -n "$identity_name" ]] \
    || release_keychain_error "no Developer ID Application identity." || return 1

  if [[ -z "${DEVELOPER_ID:-}" || "$DEVELOPER_ID" == "$identity_name" ]]; then
    DEVELOPER_ID="$identity_fingerprint"
  elif [[ "$DEVELOPER_ID" != "$identity_fingerprint" ]]; then
    release_keychain_error "DEVELOPER_ID does not match the identity in the release keychain." || return 1
  fi

  RELEASE_KEYCHAIN_ACTIVE=1
  CODESIGN_KEYCHAIN_ARGS=(--keychain "$RELEASE_KEYCHAIN_PATH")
  XCODE_KEYCHAIN_SIGN_ARGS=(OTHER_CODE_SIGN_FLAGS="--keychain $RELEASE_KEYCHAIN_PATH")
}

#!/bin/bash
# Prepare local release credentials without printing secrets.
# Sparkle key is recovered from 1Password. App Store Connect is here to stay
# file-based: config.json selects .p8 and two ids.

set -euo pipefail

SECRET_REFERENCE='op://Development/mnt44t2qfcoavybwxokaqxx6se/password'
KEY_PATH="${SPARKLE_KEY_PATH:-$HOME/.openramble/sparkle-key}"
KEY_DIRECTORY=$(dirname "$KEY_PATH")
TEMP_KEY="$KEY_PATH.pending.$$"
APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
RELEASE_KEYCHAIN_PATH="${RELEASE_KEYCHAIN_PATH:-$HOME/.openramble/release.keychain-db}"
RELEASE_KEYCHAIN_PASSWORD_PATH="${RELEASE_KEYCHAIN_PASSWORD_PATH:-$HOME/.openramble/release-keychain-password}"
DEVELOPER_ID_P12_PATH="${DEVELOPER_ID_P12_PATH:-$HOME/.openramble/developer-id.p12}"
DEVELOPER_ID_P12_PASSWORD_PATH="${DEVELOPER_ID_P12_PASSWORD_PATH:-$HOME/.openramble/developer-id-export-password}"
SECURITY_BIN="${SECURITY_BIN:-security}"
TEMP_NOTARY_KEY=""
TEMP_CONFIG=""

cleanup() {
  if [[ -e "$TEMP_KEY" ]]; then
    /bin/rm -f -- "$TEMP_KEY"
  fi
  if [[ -n "$TEMP_NOTARY_KEY" && -e "$TEMP_NOTARY_KEY" ]]; then
    /bin/rm -f -- "$TEMP_NOTARY_KEY"
  fi
  if [[ -n "$TEMP_CONFIG" && -e "$TEMP_CONFIG" ]]; then
    /bin/rm -f -- "$TEMP_CONFIG"
  fi
}
trap cleanup EXIT

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

validate_sparkle_key() {
  local key_size file_mode
  key_size=$(wc -c < "$1" | tr -d ' ')
  [[ "$key_size" == "44" ]] \
    || fail "Sparkle key of unexpected size: $key_size bytes."

  file_mode=$(stat -f '%Lp' "$1")
  [[ "$file_mode" == "600" ]] \
    || fail "Invalid Sparkle key permissions: $file_mode instead of 600."
}

if [[ -e "$KEY_PATH" ]]; then
  validate_sparkle_key "$KEY_PATH"
  echo "Sparkle key is ready: $KEY_PATH (44 bytes, mode 0600)."
else
  command -v op >/dev/null 2>&1 || fail "1Password CLI (op) not found."
  mkdir -p "$KEY_DIRECTORY"
  op read \
    --out-file "$TEMP_KEY" \
    --file-mode 0600 \
    "$SECRET_REFERENCE"

  validate_sparkle_key "$TEMP_KEY"
  mv "$TEMP_KEY" "$KEY_PATH"
  echo "Sparkle key restored: $KEY_PATH (44 bytes, mode 0600)."
fi

# shellcheck source=lib/notary-credentials.sh
source "$(dirname "$0")/lib/notary-credentials.sh"

normalize_appstoreconnect_key() {
  local config_mode raw_key_path source_key_path key_id canonical_directory
  local canonical_key_path canonical_config_path

  [[ -f "$APPSTORECONNECT_CONFIG" ]] \
    || fail "no $APPSTORECONNECT_CONFIG with App Store Connect API credentials."

  config_mode=$(stat -f '%Lp' "$APPSTORECONNECT_CONFIG")
  [[ "$config_mode" == "600" ]] \
    || fail "$APPSTORECONNECT_CONFIG must have mode 0600."

  raw_key_path=$(/usr/bin/plutil -extract key_filepath raw -o - "$APPSTORECONNECT_CONFIG" 2>/dev/null) \
    || fail "there is no key_filepath in $APPSTORECONNECT_CONFIG."
  key_id=$(/usr/bin/plutil -extract key_id raw -o - "$APPSTORECONNECT_CONFIG" 2>/dev/null) \
    || fail "there is no key_id in $APPSTORECONNECT_CONFIG."
  [[ "$key_id" =~ ^[A-Za-z0-9]{10,}$ ]] \
    || fail "key_id in $APPSTORECONNECT_CONFIG is not in the correct format."

  source_key_path=$(expand_notary_path "$raw_key_path") \
    || fail "key_filepath must be absolute or start with ~/."
  [[ -f "$source_key_path" ]] \
    || fail "App Store Connect API key file from config.json not found."

  canonical_directory="$HOME/.appstoreconnect/private_keys"
  canonical_key_path="$canonical_directory/AuthKey_${key_id}.p8"
  canonical_config_path="~/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
  mkdir -p "$canonical_directory"

  if [[ "$source_key_path" != "$canonical_key_path" ]]; then
    if [[ -e "$canonical_key_path" ]]; then
      cmp -s "$source_key_path" "$canonical_key_path" \
        || fail "there is already another API key in the standard directory; I will not overwrite it."
    else
      TEMP_NOTARY_KEY="$canonical_key_path.pending.$$"
      cp "$source_key_path" "$TEMP_NOTARY_KEY"
      chmod 600 "$TEMP_NOTARY_KEY"
      mv "$TEMP_NOTARY_KEY" "$canonical_key_path"
      TEMP_NOTARY_KEY=""
    fi

    TEMP_CONFIG="$APPSTORECONNECT_CONFIG.pending.$$"
    cp "$APPSTORECONNECT_CONFIG" "$TEMP_CONFIG"
    /usr/bin/plutil -replace key_filepath -string "$canonical_config_path" "$TEMP_CONFIG"
    chmod 600 "$TEMP_CONFIG"
    mv "$TEMP_CONFIG" "$APPSTORECONNECT_CONFIG"
    TEMP_CONFIG=""
  fi

  chmod 600 "$canonical_key_path"
}

normalize_appstoreconnect_key

NOTARY_PROFILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_ARGS=()
load_notary_credentials || fail "App Store Connect credentials failed verification."

[[ "$NOTARY_AUTH_SOURCE" == "appstoreconnect-config" ]] \
  || fail "file-based App Store Connect credentials were expected."

bootstrap_release_keychain() {
  local release_password export_password file file_mode created=0

  [[ -e "$RELEASE_KEYCHAIN_PATH" ]] && return 0

  # On a machine without recovery files, save the previous manual fallback. If
  # at least one file has already been transferred, the set must be complete: half-assembled
  # keychain is worse than an obvious error.
  if [[ ! -e "$RELEASE_KEYCHAIN_PASSWORD_PATH" \
     && ! -e "$DEVELOPER_ID_P12_PATH" \
     && ! -e "$DEVELOPER_ID_P12_PASSWORD_PATH" ]]; then
    return 0
  fi

  for file in \
    "$RELEASE_KEYCHAIN_PASSWORD_PATH" \
    "$DEVELOPER_ID_P12_PATH" \
    "$DEVELOPER_ID_P12_PASSWORD_PATH"
  do
    [[ -f "$file" ]] || fail "incomplete Developer ID recovery set: no $file."
    file_mode=$(stat -f '%Lp' "$file")
    [[ "$file_mode" == "600" ]] \
      || fail "$file must have mode 0600."
  done

  IFS= read -r release_password < "$RELEASE_KEYCHAIN_PASSWORD_PATH"
  IFS= read -r export_password < "$DEVELOPER_ID_P12_PASSWORD_PATH"
  [[ -n "$release_password" && -n "$export_password" ]] \
    || fail "Developer ID recovery password is empty."

  "$SECURITY_BIN" create-keychain -p "$release_password" "$RELEASE_KEYCHAIN_PATH"
  created=1
  if ! "$SECURITY_BIN" set-keychain-settings -lut 21600 "$RELEASE_KEYCHAIN_PATH" \
    || ! "$SECURITY_BIN" unlock-keychain -p "$release_password" "$RELEASE_KEYCHAIN_PATH" \
    || ! "$SECURITY_BIN" import "$DEVELOPER_ID_P12_PATH" \
      -k "$RELEASE_KEYCHAIN_PATH" -P "$export_password" \
      -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild \
    || ! "$SECURITY_BIN" set-key-partition-list \
      -S apple-tool:,apple: -s -k "$release_password" "$RELEASE_KEYCHAIN_PATH"
  then
    if [[ "$created" == "1" ]]; then
      "$SECURITY_BIN" delete-keychain "$RELEASE_KEYCHAIN_PATH" >/dev/null 2>&1 || true
    fi
    fail "failed to restore the offline Developer ID keychain."
  fi
  chmod 600 "$RELEASE_KEYCHAIN_PATH"
  echo "Developer ID release keychain recovered from encrypted .p12."
}

bootstrap_release_keychain

# shellcheck source=lib/release-keychain.sh
source "$(dirname "$0")/lib/release-keychain.sh"
load_release_keychain || fail "offline Developer ID keychain failed verification."

trap - EXIT

echo "App Store Connect API key ready in ~/.appstoreconnect/private_keys/; config mode 0600."
if [[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]]; then
  echo "Developer ID release keychain unlocked; codesign works without GUI."
fi

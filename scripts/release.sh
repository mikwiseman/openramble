#!/bin/bash
# Release: image, update signature, write to appcast.
#
# Sparkle updates are verified by the EdDSA signature - the application will only deliver
# the image that is signed with your key. The private key is not included in the repository
# never hits: it is a separate file, the path is passed to a variable
# SPARKLE_KEY_PATH.
#
# On the release machine, run scripts/bootstrap-release-secrets.sh once.
# The Sparkle key for this product is never regenerated.
#
# Run:
#   SPARKLE_KEY_PATH=~/.openramble/sparkle-key \
#   ./scripts/release.sh
#
# The default notarization reads ~/.appstoreconnect/config.json. Explicit
# NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER or NOTARY_PROFILE are supported,
# but the two authentication methods cannot be mixed.
#
# Step by step - docs/release.md.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenRamble"
APPCAST="docs/appcast.xml"
NOTES_DIR="docs/release-notes"
EXPECTED_BUNDLE_ID="is.waiwai.dictation"
EXPECTED_FEED_URL="https://mikwiseman.github.io/openramble/appcast.xml"
EXPECTED_PUBLIC_KEY="9ATQM2BrR8XItn19YR1bHKzPn32SZ2oiyJb3dbqaJOI="
EXPECTED_MIN_OS="14.0"
# Where the images will be located. GitHub releases - regular static from your server
# the product does not have.
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/mikwiseman/openramble/releases/download}"
# How many versions to keep in the feed. Nobody needs the old ones: Sparkle looks
# only for the latest.
KEEP_ITEMS=1

SPARKLE_KEY_PATH="${SPARKLE_KEY_PATH:-}"
DEVELOPER_ID="${DEVELOPER_ID:-}"
RELEASE_KEYCHAIN_PATH="${RELEASE_KEYCHAIN_PATH:-$HOME/.openramble/release.keychain-db}"
RELEASE_KEYCHAIN_PASSWORD_PATH="${RELEASE_KEYCHAIN_PASSWORD_PATH:-$HOME/.openramble/release-keychain-password}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
SPARKLE_BIN="${SPARKLE_BIN:-}"

fail() {
  echo "" >&2
  echo "$1" >&2
  exit 1
}

# shellcheck source=lib/notary-credentials.sh
source scripts/lib/notary-credentials.sh
# shellcheck source=lib/release-keychain.sh
source scripts/lib/release-keychain.sh

# --- One SHA and confirmed CI -------------------------------------------

[[ -z "$(git status --porcelain)" ]] || fail "Release requires a clean tree."
[[ "$(git branch --show-current)" == "main" ]] || fail "Release is allowed only from main."
git fetch --quiet origin main
HEAD_SHA=$(git rev-parse HEAD)
ORIGIN_SHA=$(git rev-parse origin/main)
[[ "$HEAD_SHA" == "$ORIGIN_SHA" ]] || fail "HEAD does not match origin/main."

assert_release_source_unchanged() {
  local checkpoint="$1"
  [[ "$(git rev-parse HEAD)" == "$HEAD_SHA" ]] \
    || fail "HEAD changed $checkpoint; refusing to publish an artifact from a mixed source snapshot."
  [[ -z "$(git status --porcelain)" ]] \
    || fail "Tracked release inputs changed $checkpoint; restart from a clean tree."
}

# Evidence that this commit was verified, from one of two places.
#
# The point of the gate is that the code was tested, not that a particular
# server tested it. Waiting for GitHub adds a queue, a cold runner and a
# network that fails — three releases died today on a TLS handshake with every
# test green. Running the same suites here, on the machine that is about to
# build the artifact, is the same evidence and arrives in minutes.
#
# VERIFY=local runs them now. VERIFY=ci waits for the run on this exact SHA.
# The default tries CI first and falls back to running them, so a release is
# never blocked by a server being slow or unreachable.
VERIFY="${VERIFY:-auto}"

ci_is_green() {
  command -v gh >/dev/null || return 1

  gh_retry() {
    local attempt
    for attempt in 1 2 3; do
      gh "$@" && return 0
      sleep $((attempt * 3))
    done
    return 1
  }

  # Not the whole matrix: the Windows and Linux desktop builds take half an
  # hour and say nothing about the DMG being signed here.
  local required=(
    "Package tests" "Application build" "Release build" "Network surface"
    "Core matches macOS" "Swift calls the core" "Apple Silicon only"
  )
  local run_id
  run_id=$(gh_retry run list --branch main --limit 10 \
    --json databaseId,headSha,workflowName \
    --jq '[.[] | select(.headSha == "'"$HEAD_SHA"'") | select(.workflowName == "CI")][0].databaseId') || return 1
  [[ -n "$run_id" && "$run_id" != "null" ]] || return 1

  local jobs job outcome
  jobs=$(gh_retry run view "$run_id" --json jobs) || return 1
  for job in "${required[@]}"; do
    outcome=$(printf '%s' "$jobs" | jq -r '[.jobs[] | select(.name == "'"$job"'")][0].conclusion // "missing"')
    [[ "$outcome" == "success" ]] || return 1
  done
  return 0
}

verify_locally() {
  echo "→ Verifying this commit here"
  ./scripts/check.sh || fail "The checks did not pass; nothing was released."
}

case "$VERIFY" in
  local)
    verify_locally
    ;;
  ci)
    ci_is_green || fail "No green CI on SHA $HEAD_SHA for the jobs covering this artifact."
    echo "→ CI: the jobs covering this artifact are green"
    ;;
  auto)
    if ci_is_green; then
      echo "→ CI: the jobs covering this artifact are green"
    else
      echo "→ CI is not green yet or is unreachable; verifying here instead"
      verify_locally
    fi
    ;;
  *)
    fail "VERIFY must be auto, local or ci."
    ;;
esac

echo "→ Building the shared core for Swift"
./scripts/build-ffi.sh >/dev/null

echo "→ Checking the network surface"
./scripts/check-network-surface.sh >/dev/null

echo "→ Checking the diagnostics surface"
./scripts/check-diagnostics-surface.sh >/dev/null

echo "→ Running tests"
# Quiet while they pass, loud when they do not. Sending test output straight
# to /dev/null once cost two full release cycles: the script exited 1 with no
# reason anywhere, and the failing assertion was simply gone.
run_quietly() {
  local label="$1"; shift
  local output
  output=$(mktemp -t openramble-release-test)
  if ! "$@" >"$output" 2>&1; then
    echo "✗ $label failed:"
    tail -40 "$output"
    echo "(full output: $output)"
    return 1
  fi
  rm -f "$output"
}

run_quietly "DictationCore tests" swift test --package-path Packages/DictationCore
run_quietly "LocalASR tests" swift test --package-path Packages/LocalASR
XCODEGEN=$(./scripts/pinned-xcodegen.sh)
(cd apps/macos && "$XCODEGEN" generate >/dev/null)
run_quietly "application tests" xcodebuild -project apps/macos/OpenRamble.xcodeproj \
  -scheme OpenRamble -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO test

echo "→ Checking runtime without a network"
./scripts/test-zero-network.sh >/dev/null
./scripts/test-zero-network-trace.sh >/dev/null
assert_release_source_unchanged "before the fresh archive build"

# --- Build the image -------------------------------------------------------------

echo "→ Assembling the image"
DEVELOPER_ID="$DEVELOPER_ID" \
NOTARY_PROFILE="$NOTARY_PROFILE" \
NOTARY_KEY="$NOTARY_KEY" \
NOTARY_KEY_ID="$NOTARY_KEY_ID" \
NOTARY_ISSUER="$NOTARY_ISSUER" \
APPSTORECONNECT_CONFIG="$APPSTORECONNECT_CONFIG" \
RELEASE_KEYCHAIN_PATH="$RELEASE_KEYCHAIN_PATH" \
RELEASE_KEYCHAIN_PASSWORD_PATH="$RELEASE_KEYCHAIN_PASSWORD_PATH" \
REQUIRE_NOTARIZATION=1 \
REQUIRE_OFFLINE_RECOGNITION=1 \
./scripts/build-dmg.sh

VERSION="$MARKETING_VERSION"
BUILD="$EXPECTED_BUILD"
MIN_OS="$EXPECTED_MIN_OS"
FEED_URL="$EXPECTED_FEED_URL"
PUBLIC_KEY="$EXPECTED_PUBLIC_KEY"
DMG_PATH="artifacts/dmg/OpenRamble-$MARKETING_VERSION.dmg"
[[ -f "$DMG_PATH" ]] || fail "No image: $DMG_PATH"
[[ -f "$DMG_PATH.sha256" ]] || fail "No build checksum: $DMG_PATH.sha256"
shasum -a 256 -c "$DMG_PATH.sha256" >/dev/null \
  || fail "The DMG no longer matches the checksum produced by this build."

echo "→ Checking the exact mounted release DMG"
EXPECTED_APP_NAME="$APP_NAME" \
EXPECTED_BUNDLE_ID="$EXPECTED_BUNDLE_ID" \
EXPECTED_VERSION="$VERSION" \
EXPECTED_BUILD="$BUILD" \
EXPECTED_MIN_OS="$MIN_OS" \
EXPECTED_FEED_URL="$FEED_URL" \
EXPECTED_PUBLIC_KEY="$PUBLIC_KEY" \
REQUIRE_DEVELOPER_ID=1 \
REQUIRE_OFFLINE_RECOGNITION=1 \
./scripts/smoke-installed-artifact.sh "$DMG_PATH"
assert_release_source_unchanged "after building and verifying the exact DMG"

xcrun stapler validate "$DMG_PATH" >/dev/null \
  || fail "Staple ticket not confirmed for $DMG_PATH."
spctl --assess --type install --verbose=2 "$DMG_PATH" \
  || fail "Gatekeeper does not accept $DMG_PATH."

echo "version $VERSION, build $BUILD, minimum macOS $MIN_OS"

# --- Update signature ------------------------------------------------------

echo "→ I sign the image with the update key"
SIGNATURE=$("$SIGN_UPDATE" -p --ed-key-file "$SPARKLE_KEY_PATH" "$DMG_PATH")
[[ -n "$SIGNATURE" ]] || fail "sign_update did not issue a signature"

# We check immediately: a signature that has not been verified by anyone is not a signature.
"$SIGN_UPDATE" --verify --ed-key-file "$SPARKLE_KEY_PATH" "$DMG_PATH" "$SIGNATURE" >/dev/null \
  || fail "Signature does not match key $SPARKLE_KEY_PATH"

# And now what the previous check does not do at all.
#
# She checks the signature with the same private key she just signed with -
# that is, it cannot but converge. The real question is: does it fit?
# PUBLIC key hardcoded into the application for this private one. Separated - release
# goes green, the feed is published, but the update is not installed on anyone
# whom and never: the application verifies the signature with its own key, but it is someone else’s.
#
# Sparkle key file is base64 of 32 byte grain ed25519 so
# public is derived from it directly. Cross checked: derived like this
# the key confirms the signature made by sign_update itself.
echo "→ I check the public key in the application with the signing key"
DERIVED_KEY=$(swift - "$SPARKLE_KEY_PATH" <<'SWIFT'
import CryptoKit
import Foundation

let path = CommandLine.arguments[1]
guard let text = try? String(contentsOfFile: path, encoding: .utf8),
      let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("signature key is not read as grain ed25519\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
) || fail "Failed to derive public key from $SPARKLE_KEY_PATH"

if [[ "$DERIVED_KEY" != "$PUBLIC_KEY" ]]; then
  fail "The public key in the application is not from the private key with which the image was signed.

In Info.plist: $PUBLIC_KEY
Corresponds to the key: $DERIVED_KEY

You can’t release it like this: installed copies require the permanent public
key already embedded in the application. Do not change SUPublicEDKey. Recover
the matching permanent private key with ./scripts/bootstrap-release-secrets.sh."
fi

LENGTH=$(stat -f%z "$DMG_PATH")
DMG_URL="$DOWNLOAD_BASE/v$VERSION/$(basename "$DMG_PATH")"

# --- Update feed --------------------------------------------------------

shasum -a 256 -c "$DMG_PATH.sha256" >/dev/null \
  || fail "The verified DMG changed before appcast mutation."
assert_release_source_unchanged "immediately before appcast mutation"
echo "→Updating $APPCAST"
APPCAST="$APPCAST" NOTES_PATH="$NOTES_PATH" KEEP_ITEMS="$KEEP_ITEMS" \
VERSION="$VERSION" BUILD="$BUILD" MIN_OS="$MIN_OS" FEED_URL="$FEED_URL" \
DMG_URL="$DMG_URL" LENGTH="$LENGTH" SIGNATURE="$SIGNATURE" APP_NAME="$APP_NAME" \
python3 scripts/update-appcast.py

# --- What's next --------------------------------------------------------------

cat <<TEXT

Done. All that remains is to put it in its place:

  1. Check the feed: git diff $APPCAST
  2. Create a release and upload the image:
       gh release create v$VERSION "$DMG_PATH" --title "$VERSION" --notes-file "$NOTES_PATH"
     The link in the feed is waiting for the image exactly here:
       $DMG_URL
  3. Commit the feed and description - GitHub Pages distributes them from docs/:
       git add $APPCAST $NOTES_PATH && git commit -m "release: $VERSION"
       git push
  4. After a couple of minutes, make sure the tape is live:
       curl -sSf $FEED_URL | head -20

And only then - “Check for updates...” in the old version of the application.
TEXT

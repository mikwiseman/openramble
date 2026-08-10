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
APP_PATH="artifacts/build/OpenRamble.xcarchive/Products/Applications/$APP_NAME.app"
APPCAST="docs/appcast.xml"
NOTES_DIR="docs/release-notes"
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
REUSE_VERIFIED_ARTIFACT="${REUSE_VERIFIED_ARTIFACT:-0}"

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
command -v gh >/dev/null || fail "Gh not found for required CI check."
CI_CONCLUSION=$(gh run list \
  --workflow CI \
  --commit "$HEAD_SHA" \
  --limit 1 \
  --json conclusion,status,headSha \
  --jq '.[0] | select(.headSha == "'"$HEAD_SHA"'") | select(.status == "completed") | .conclusion')
[[ "$CI_CONCLUSION" == "success" ]] || fail "No green completed CI on SHA $HEAD_SHA."

# --- Update signing key -------------------------------------------------

if [[ -z "$SPARKLE_KEY_PATH" ]]; then
  fail "SPARKLE_KEY_PATH is not specified - the file with the Sparkle private key.

If you don't have the key yet:
  ./scripts/bootstrap-release-secrets.sh

A new Sparkle key cannot be generated for this product: installed
copies need exactly the same key. The public half is already in
apps/macos/project.yml as SUPublicEDKey.

generate_keys itself comes with the Sparkle package:
  ~/Library/Developer/Xcode/DerivedData/OpenRamble-*/SourcePackages/artifacts/sparkle/Sparkle/bin/"
fi

if [[ ! -f "$SPARKLE_KEY_PATH" ]]; then
  fail "There is no key file: $SPARKLE_KEY_PATH
Restore the previous key: ./scripts/bootstrap-release-secrets.sh"
fi

# --- Sparkle Tools -----------------------------------------------------

# sign_update comes inside the Sparkle package. Xcode unpacks it to
# DerivedData during the first build, so there is no need to install anything separately.
find_sparkle_tool() {
  local tool="$1" pattern candidate
  if [[ -n "$SPARKLE_BIN" ]]; then
    [[ -x "$SPARKLE_BIN/$tool" ]] && { printf '%s' "$SPARKLE_BIN/$tool"; return 0; }
    return 1
  fi
  for pattern in "OpenRamble-*" "*"; do
    for candidate in "$HOME/Library/Developer/Xcode/DerivedData"/$pattern/SourcePackages/artifacts/sparkle/Sparkle/bin/"$tool"; do
      [[ -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
  done
  return 1
}

SIGN_UPDATE=$(find_sparkle_tool sign_update) || fail "Couldn't find sign_update.

It's inside the Sparkle package that Xcode unpacks when building:
  ~/Library/Developer/Xcode/DerivedData/OpenRamble-*/SourcePackages/artifacts/sparkle/Sparkle/bin/

Build the application at least once, or specify the path manually:
  SPARKLE_BIN=/path/to/Sparkle/bin ./scripts/release.sh"

# --- Signing and notarization of the application itself ---------------------------------

load_release_keychain || fail "Offline release keychain failed verification."

# An unnotarized Gatekeeper image will not be allowed, and the update will turn into
# Broken application for everyone who installed it. Trial assemblies - separately,
# via scripts/build-dmg.sh.
if [[ -z "$DEVELOPER_ID" ]]; then
  fail "The release is only going to be signed and notarized.

First prepare a standalone keychain:
  ./scripts/bootstrap-release-secrets.sh

Legacy fallback without a separate keychain:
  DEVELOPER_ID=\"Developer ID Application: Name (TEAMID)\"

The default notarization credentials are read from:
  $APPSTORECONNECT_CONFIG

Separate Debug-probe: ./scripts/build-dmg.sh"
fi

if ! load_notary_credentials; then
  fail "Failed to load notarization credentials.

The preferred format is $APPSTORECONNECT_CONFIG with mode 0600:
  key_filepath path to .p8 in ~/.appstoreconnect/private_keys/
  key_id        App Store Connect API Key ID
  issuer_id     App Store Connect API Issuer ID

Alternative: exactly one NOTARY_PROFILE from notarytool store-credentials."
fi

echo "→ Notarization: $NOTARY_AUTH_SOURCE"

# --- Checks before assembly --------------------------------------------------

# We take the version from project.yml before building. Then we’ll check it against the collected
# Info.plist, but a description of the changes must be requested earlier: assembly with
# notarization takes minutes, and runs into a missing text file after
# them - wasted time on each release.
PROJECT_YML="apps/macos/project.yml"
yml_value() {
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$PROJECT_YML" | head -1
}

MARKETING_VERSION=$(yml_value MARKETING_VERSION)
SHORT_VERSION=$(yml_value CFBundleShortVersionString)

[[ -n "$MARKETING_VERSION" ]] || fail "MARKETING_VERSION was not found in $PROJECT_YML"

# Two lines about the same version must match: Sparkle shows the person
# CFBundleShortVersionString, and the image name is taken from it.
#
# A reference to the variable is the better of the two spellings and is accepted
# as-is: it cannot diverge, which is the whole point of this check. A literal
# copy can, and did — the two sat at 0.3.4 and 0.3.3 until CI compared them.
if [[ "$SHORT_VERSION" != "\$(MARKETING_VERSION)" \
   && "$MARKETING_VERSION" != "$SHORT_VERSION" ]]; then
  fail "Versions in $PROJECT_YML have diverged:
  MARKETING_VERSION           = $MARKETING_VERSION
  CFBundleShortVersionString  = $SHORT_VERSION
Both strings must be the same, or CFBundleShortVersionString must reference
\$(MARKETING_VERSION)."
fi

NOTES_PATH="$NOTES_DIR/$MARKETING_VERSION.md"
if [[ ! -f "$NOTES_PATH" ]]; then
  mkdir -p "$NOTES_DIR"
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
  {
    if [[ -n "$LAST_TAG" ]]; then
      git log --no-merges --pretty=format:'- %s' "$LAST_TAG..HEAD"
    else
      git log --no-merges --pretty=format:'- %s'
    fi
  } | grep -vE '^- (chore|docs|test|refactor|wip|ci)[(:]' > "$NOTES_PATH" || true
  echo "" >> "$NOTES_PATH"

  fail "There is no description of the changes - I sketched a draft from the commits:
  $NOTES_PATH

Rewrite it in clear English; everyone offered the update will see it.
Then run the script again. The release stops before the expensive build
and notarization steps."
fi

echo "→ Checking the network surface"
./scripts/check-network-surface.sh >/dev/null

echo "→ Running tests"
swift test --package-path Packages/DictationCore >/dev/null
swift test --package-path Packages/LocalASR >/dev/null
XCODEGEN=$(./scripts/pinned-xcodegen.sh)
(cd apps/macos && "$XCODEGEN" generate >/dev/null)
xcodebuild -project apps/macos/OpenRamble.xcodeproj -scheme OpenRamble \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test >/dev/null

echo "→ Checking runtime without a network"
./scripts/test-zero-network.sh >/dev/null
./scripts/test-zero-network-trace.sh >/dev/null

# --- Build the image -------------------------------------------------------------

echo "→ Assembling the image"
if [[ "$REUSE_VERIFIED_ARTIFACT" == "1" ]]; then
  echo "I'm using an already verified artifact; a new DMG is not created."
elif [[ "$REUSE_VERIFIED_ARTIFACT" == "0" ]]; then
  DEVELOPER_ID="$DEVELOPER_ID" \
  NOTARY_PROFILE="$NOTARY_PROFILE" \
  NOTARY_KEY="$NOTARY_KEY" \
  NOTARY_KEY_ID="$NOTARY_KEY_ID" \
  NOTARY_ISSUER="$NOTARY_ISSUER" \
  APPSTORECONNECT_CONFIG="$APPSTORECONNECT_CONFIG" \
  RELEASE_KEYCHAIN_PATH="$RELEASE_KEYCHAIN_PATH" \
  RELEASE_KEYCHAIN_PASSWORD_PATH="$RELEASE_KEYCHAIN_PASSWORD_PATH" \
  REQUIRE_NOTARIZATION=1 \
  ./scripts/build-dmg.sh
else
  fail "REUSE_VERIFIED_ARTIFACT only accepts 0 or 1."
fi

[[ -d "$APP_PATH" ]] || fail "The build failed the application: $APP_PATH"

echo "→ Checking the installed artifact"
./scripts/smoke-installed-artifact.sh "$APP_PATH"

for resource in \
  LICENSE NOTICE THIRD_PARTY_LICENSES.md model-manifest.json \
  FluidAudio-Apache-2.0.txt FluidAudio-fastcluster-BSD.txt \
  FluidAudio-vbx-Apache-2.0.txt Sparkle-LICENSE.txt \
  Parakeet-CC-BY-4.0.txt
do
  [[ -f "$APP_PATH/Contents/Resources/$resource" ]] \
    || fail "There is no required resource in artifact: $resource"
done

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
}

VERSION=$(plist_value CFBundleShortVersionString)
BUILD=$(plist_value CFBundleVersion)
MIN_OS=$(plist_value LSMinimumSystemVersion)
FEED_URL=$(plist_value SUFeedURL)
PUBLIC_KEY=$(plist_value SUPublicEDKey)

[[ -n "$VERSION" && -n "$BUILD" ]] || fail "There is no version or build number in Info.plist"
[[ -n "$FEED_URL" ]] || fail "Info.plist does not have SUFeedURL - the application will not know where to look for updates"

if [[ -z "$PUBLIC_KEY" ]]; then
  fail "There is no SUPublicEDKey in Info.plist.

Without it, the update is verified only by Apple's signature, which Sparkle considers
outdated and unsafe. Take the public key:
  generate_keys -p
and add it to apps/macos/project.yml:
  SUPublicEDKey: \"<key>\""
fi

DMG_PATH="artifacts/dmg/OpenRamble-$VERSION.dmg"
[[ -f "$DMG_PATH" ]] || fail "No image: $DMG_PATH"

# In reuse mode it is especially important to prove that this is a real Developer ID /
# notarized artifact, not a smoke ad-hoc build.
APP_AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[[ "$APP_AUTHORITY" == Developer\ ID\ Application:* ]] \
  || fail "The application is not signed by Developer ID Application: ${APP_AUTHORITY:-ad-hoc}."
xcrun stapler validate "$DMG_PATH" >/dev/null \
  || fail "Staple ticket not confirmed for $DMG_PATH."
spctl --assess --type install --verbose=2 "$DMG_PATH" \
  || fail "Gatekeeper does not accept $DMG_PATH."

echo "version $VERSION, build $BUILD, minimum macOS $MIN_OS"

# --- What's new --------------------------------------------------------------

# The description was already required before assembly. Here we just check that everything has come together smoothly
# what it says: a discrepancy would mean that xcodegen did not take the version
# from project.yml.
if [[ "$VERSION" != "$MARKETING_VERSION" ]]; then
  fail "The assembled version of $VERSION does not match the $MARKETING_VERSION from $PROJECT_YML.
Regenerate the project: cd apps/macos && xcodegen generate"
fi

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

You can’t release it like this: no one will install the update. Enter in
apps/macos/project.yml is the correct key and rebuild:
  SUPublicEDKey: \"$DERIVED_KEY\""
fi

LENGTH=$(stat -f%z "$DMG_PATH")
DMG_URL="$DOWNLOAD_BASE/v$VERSION/$(basename "$DMG_PATH")"

# --- Update feed --------------------------------------------------------

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

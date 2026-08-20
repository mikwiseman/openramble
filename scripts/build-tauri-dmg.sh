#!/bin/bash
# Build the universal Tauri macOS application and package it for Sparkle.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="artifacts/build"
DMG_DIR="artifacts/dmg"
TAURI_CONFIG="apps/desktop/src-tauri/tauri.conf.json"
APP_ENTITLEMENTS="apps/desktop/src-tauri/Entitlements.plist"
OFFICIAL_FEED_URL="https://mikwiseman.github.io/openramble/appcast.xml"
PERMANENT_PUBLIC_KEY="9ATQM2BrR8XItn19YR1bHKzPn32SZ2oiyJb3dbqaJOI="
EXPECTED_MIN_OS="14.0"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
REQUIRE_OFFLINE_RECOGNITION="${REQUIRE_OFFLINE_RECOGNITION:-0}"
UNSIGNED_RELEASE_TOPOLOGY="${UNSIGNED_RELEASE_TOPOLOGY:-0}"
BUILD_NUMBER_OVERRIDE="${BUILD_NUMBER_OVERRIDE:-}"

# shellcheck source=lib/notary-credentials.sh
source scripts/lib/notary-credentials.sh
# shellcheck source=lib/release-keychain.sh
source scripts/lib/release-keychain.sh

fail() { echo "$1" >&2; exit 1; }
json_value() { jq -er "$1" "$TAURI_CONFIG"; }

VERSION=$(json_value '.version')
BUILD=$(json_value '.bundle.macOS.bundleVersion')
BUNDLE_ID=$(json_value '.identifier')
MIN_OS=$(json_value '.bundle.macOS.minimumSystemVersion')
[[ "$BUNDLE_ID" == "is.waiwai.dictation" ]] || fail "The permanent bundle identifier changed: $BUNDLE_ID"
[[ "$MIN_OS" == "$EXPECTED_MIN_OS" ]] || fail "The macOS floor must remain $EXPECTED_MIN_OS, got $MIN_OS"
[[ "$REQUIRE_NOTARIZATION" =~ ^[01]$ ]] || fail "REQUIRE_NOTARIZATION accepts only 0 or 1."
[[ "$REQUIRE_OFFLINE_RECOGNITION" =~ ^[01]$ ]] || fail "REQUIRE_OFFLINE_RECOGNITION accepts only 0 or 1."
[[ "$UNSIGNED_RELEASE_TOPOLOGY" =~ ^[01]$ ]] || fail "UNSIGNED_RELEASE_TOPOLOGY accepts only 0 or 1."
if [[ "$REQUIRE_NOTARIZATION" == "1" && "$REQUIRE_OFFLINE_RECOGNITION" != "1" ]]; then
  fail "A notarized build requires recognition with network denied."
fi
if [[ "$UNSIGNED_RELEASE_TOPOLOGY" == "1" && "${CI:-}" != "true" ]]; then
  fail "UNSIGNED_RELEASE_TOPOLOGY is a CI-only check."
fi
if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  [[ "$BUILD_NUMBER_OVERRIDE" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER_OVERRIDE must be numeric."
  BUILD="$BUILD_NUMBER_OVERRIDE"
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  load_release_keychain || exit 1
  APP_NAME="OpenRamble"
  EXPECTED_BUNDLE_ID="$BUNDLE_ID"
  DMG_BASENAME="OpenRamble"
elif [[ "$UNSIGNED_RELEASE_TOPOLOGY" == "1" ]]; then
  APP_NAME="OpenRamble"
  EXPECTED_BUNDLE_ID="$BUNDLE_ID"
  DMG_BASENAME="OpenRamble"
else
  APP_NAME="OpenRambleDev"
  EXPECTED_BUNDLE_ID="is.waiwai.dictation.dev"
  DMG_BASENAME="OpenRambleDev"
fi

if [[ -n "$NOTARY_PROFILE" || -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" \
   || -n "$NOTARY_ISSUER" || -f "$APPSTORECONNECT_CONFIG" \
   || "$REQUIRE_NOTARIZATION" == "1" ]]; then
  load_notary_credentials || exit 1
else
  NOTARY_ARGS=()
fi

echo "→ Preparing pinned native dependencies"
./scripts/prepare-tauri-macos.sh

PINNED_CARGO=$(rustup which --toolchain 1.97.1 cargo)
PINNED_RUSTC=$(rustup which --toolchain 1.97.1 rustc)
export PATH="$(dirname "$PINNED_CARGO"):$PATH"
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed --toolchain 1.97.1-aarch64-apple-darwin | grep -qx "$target" \
    || rustup target add "$target" --toolchain 1.97.1-aarch64-apple-darwin
done

echo "→ Building the universal Tauri application"
rm -rf -- "$BUILD_DIR" "$DMG_DIR"
mkdir -p "$BUILD_DIR" "$DMG_DIR"
RUSTC="$PINNED_RUSTC" CARGO="$PINNED_CARGO" \
  "$PINNED_CARGO" tauri build --runner "$PWD/scripts/cargo-locked.sh" \
  --config "$TAURI_CONFIG" --target universal-apple-darwin --bundles app --no-sign

SOURCE_APP="target/universal-apple-darwin/release/bundle/macos/OpenRamble.app"
[[ -d "$SOURCE_APP" ]] || fail "Tauri did not produce $SOURCE_APP"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
ditto "$SOURCE_APP" "$APP_PATH"
PLIST="$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleIdentifier -string "$EXPECTED_BUNDLE_ID" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
[[ "$(plist_value SUFeedURL)" == "$OFFICIAL_FEED_URL" ]] || fail "The built app has the wrong Sparkle feed."
[[ "$(plist_value SUPublicEDKey)" == "$PERMANENT_PUBLIC_KEY" ]] || fail "The built app has the wrong Sparkle public key."
[[ "$(plist_value LSMinimumSystemVersion)" == "$EXPECTED_MIN_OS" ]] || fail "The built app has the wrong macOS floor."
[[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" ]] || fail "The built app has the wrong version."

echo "→ Adding licenses and model provenance"
RESOURCES="$APP_PATH/Contents/Resources"
mkdir -p "$RESOURCES"
cp LICENSE NOTICE THIRD_PARTY_LICENSES.md "$RESOURCES/"
cp Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json "$RESOURCES/"
cp .build-tools/sparkle-2.9.4/LICENSE "$RESOURCES/Sparkle-LICENSE.txt"
cp licenses/CC-BY-4.0.txt "$RESOURCES/Parakeet-CC-BY-4.0.txt"
METADATA=$(RUSTC="$PINNED_RUSTC" CARGO="$PINNED_CARGO" "$PINNED_CARGO" metadata --locked --format-version 1)
TRANSCRIBE_SYS=$(printf '%s' "$METADATA" | jq -er '.packages[] | select(.name == "transcribe-cpp-sys" and .version == "0.2.0") | .manifest_path | sub("/Cargo.toml$"; "")')
cp "$TRANSCRIBE_SYS/LICENSE" "$RESOURCES/transcribe-cpp-MIT.txt"
cp "$TRANSCRIBE_SYS/ggml/LICENSE" "$RESOURCES/ggml-MIT.txt"
cp "$TRANSCRIBE_SYS/src/third_party/miniz/LICENSE" "$RESOURCES/miniz-MIT.txt"

EXECUTABLE="$APP_PATH/Contents/MacOS/openramble-desktop"
[[ -x "$EXECUTABLE" ]] || fail "The Tauri executable is missing."
for arch in arm64 x86_64; do
  vtool -show-build -arch "$arch" "$EXECUTABLE" | grep -q "minos $EXPECTED_MIN_OS" \
    || fail "$arch does not target macOS $EXPECTED_MIN_OS."
done

echo "→ Checking universal code"
while IFS= read -r binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  archs=$(lipo -archs "$binary")
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] \
    || fail "Missing a supported architecture in $binary ($archs)"
done < <(find "$APP_PATH" -type f)

SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/B"
COMPONENTS=(
  "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  "$SPARKLE_VERSION/Autoupdate"
  "$SPARKLE_VERSION/Updater.app"
  "$SPARKLE"
)
for component in "${COMPONENTS[@]}"; do [[ -e "$component" ]] || fail "Missing Sparkle component: $component"; done

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ Signing nested code and application"
  CODESIGN_ARGS=(--force)
  [[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]] && CODESIGN_ARGS+=("${CODESIGN_KEYCHAIN_ARGS[@]}")
  sign() { codesign "${CODESIGN_ARGS[@]}" --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"; }
  sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  sign "$SPARKLE_VERSION/Autoupdate"
  sign "$SPARKLE_VERSION/Updater.app"
  sign "$SPARKLE"
  sign --identifier "$EXPECTED_BUNDLE_ID" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
else
  echo "→ Applying local ad-hoc signatures"
  codesign --force --sign - "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  codesign --force --sign - --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  codesign --force --sign - "$SPARKLE_VERSION/Autoupdate"
  codesign --force --sign - "$SPARKLE_VERSION/Updater.app"
  codesign --force --sign - "$SPARKLE"
  codesign --force --sign - --identifier "$EXPECTED_BUNDLE_ID" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
fi
codesign --verify --strict --verbose=2 "$APP_PATH"
for component in "${COMPONENTS[@]}"; do codesign --verify --strict --verbose=2 "$component"; done

echo "→ Assembling the disk image"
STAGING="$DMG_DIR/staging"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
DMG_PATH="$DMG_DIR/$DMG_BASENAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf -- "$STAGING"
if [[ -n "$DEVELOPER_ID" ]]; then
  codesign "${CODESIGN_ARGS[@]}" --timestamp --sign "$DEVELOPER_ID" "$DMG_PATH"
fi
hdiutil verify "$DMG_PATH" >/dev/null

if [[ -n "$DEVELOPER_ID" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "→ Notarizing"
  NOTARY_RESULT=$(xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait --timeout 30m --output-format json)
  NOTARY_STATUS=$(printf '%s' "$NOTARY_RESULT" | plutil -extract status raw -o - -)
  [[ "$NOTARY_STATUS" == "Accepted" ]] || fail "Notarization was not accepted: $NOTARY_STATUS"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
elif [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
  fail "Notarization is required, but signing credentials are incomplete."
else
  echo "Notarization missing: this is not an installable release."
fi

EXPECTED_APP_NAME="$APP_NAME" EXPECTED_BUNDLE_ID="$EXPECTED_BUNDLE_ID" \
EXPECTED_VERSION="$VERSION" EXPECTED_BUILD="$BUILD" EXPECTED_MIN_OS="$EXPECTED_MIN_OS" \
EXPECTED_FEED_URL="$OFFICIAL_FEED_URL" EXPECTED_PUBLIC_KEY="$PERMANENT_PUBLIC_KEY" \
REQUIRE_DEVELOPER_ID="$([[ -n "$DEVELOPER_ID" ]] && echo 1 || echo 0)" \
REQUIRE_OFFLINE_RECOGNITION="$REQUIRE_OFFLINE_RECOGNITION" \
./scripts/smoke-installed-artifact.sh "$DMG_PATH"

shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
echo "Done: $DMG_PATH"

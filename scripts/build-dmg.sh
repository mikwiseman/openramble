#!/bin/bash
# Build an image for distribution.
#
# Without Developer ID you get only Debug-probe with a separate name and bundle
#id. Production identity is never signed ad-hoc: otherwise every rebuild
# creates a new Accessibility entry, and accumulates in the system settings
# indistinguishable "OpenRamble".
#
#   DEVELOPER_ID   — «Developer ID Application: …»
# NOTARY_PROFILE - notarytool profile, created via `xcrun notarytool store-credentials`
# Defaults to key_filepath, key_id and issuer_id from
# ~/.appstoreconnect/config.json. Profile and API key cannot be mixed.
#
# Run:
#   ./scripts/build-dmg.sh            Debug-probe: OpenRambleDev
#   DEVELOPER_ID="…" ./scripts/build-dmg.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="OpenRamble"
PROJECT="apps/macos/OpenRamble.xcodeproj"
BUILD_DIR="artifacts/build"
DMG_DIR="artifacts/dmg"
APP_ENTITLEMENTS="apps/macos/OpenRamble/OpenRamble.entitlements"

DEVELOPER_ID="${DEVELOPER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
APPSTORECONNECT_CONFIG="${APPSTORECONNECT_CONFIG:-$HOME/.appstoreconnect/config.json}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
BUILD_NUMBER_OVERRIDE="${BUILD_NUMBER_OVERRIDE:-}"
BUILD_OVERRIDES=()

# shellcheck source=lib/notary-credentials.sh
source scripts/lib/notary-credentials.sh
# shellcheck source=lib/release-keychain.sh
source scripts/lib/release-keychain.sh

if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  [[ "$BUILD_NUMBER_OVERRIDE" =~ ^[0-9]+$ ]] || {
    echo "BUILD_NUMBER_OVERRIDE must consist of numbers only." >&2
    exit 1
  }
  BUILD_OVERRIDES=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER_OVERRIDE")
  echo "→ Build number override: $BUILD_NUMBER_OVERRIDE"
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  load_release_keychain || exit 1
  APP_NAME="OpenRamble"
  BUNDLE_ID="is.waiwai.dictation"
  BUILD_CONFIGURATION="Release"
  DMG_BASENAME="OpenRamble"
else
  APP_NAME="OpenRambleDev"
  BUNDLE_ID="is.waiwai.dictation.dev"
  BUILD_CONFIGURATION="Debug"
  DMG_BASENAME="OpenRambleDev"
fi

if [[ -n "$NOTARY_PROFILE" || -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" \
   || -n "$NOTARY_ISSUER" || -f "$APPSTORECONNECT_CONFIG" \
   || "$REQUIRE_NOTARIZATION" == "1" ]]; then
  if ! load_notary_credentials; then
    if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
      echo "For installable beta, correct notarization credentials are required." >&2
    fi
    exit 1
  fi
else
  NOTARY_ARGS=()
fi

echo "→ Generating a project"
XCODEGEN=$(./scripts/pinned-xcodegen.sh)
(cd apps/macos && "$XCODEGEN" generate >/dev/null)

echo "→ Build configuration $BUILD_CONFIGURATION"
rm -rf "$BUILD_DIR" "$DMG_DIR"
mkdir -p "$BUILD_DIR" "$DMG_DIR"

PACKAGE_CACHE="$BUILD_DIR/SourcePackages"
echo "→ I allow immutable package revisions"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" >/dev/null

if [[ -n "$DEVELOPER_ID" ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual)
  if [[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]]; then
    SIGN_ARGS+=("${XCODE_KEYCHAIN_SIGN_ARGS[@]}")
  fi
else
  echo "Developer ID is not specified - I am collecting a separate Debug-probe OpenRambleDev"
  SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
fi

ARCHIVE_LOG=$(mktemp)
# Only temporary files are trapped. A variable once visited here,
# which was reused below under the path IN THE REPOSITORY - and each rehearsal
# assemblies silently deleted licenses/CC-BY-4.0.txt, after which release.sh crashed
# on a "dirty tree" with no hint of a reason.
trap 'rm -f "$ARCHIVE_LOG"' EXIT
set +e
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$BUILD_CONFIGURATION" \
  -archivePath "$BUILD_DIR/$SCHEME.xcarchive" \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
  "${SIGN_ARGS[@]}" ${BUILD_OVERRIDES[@]+"${BUILD_OVERRIDES[@]}"} 2>&1 \
  | tee "$ARCHIVE_LOG" \
  | grep -E "error:|warning: .*deprecated|ARCHIVE"
ARCHIVE_STATUS=${PIPESTATUS[0]}
set -e
if [[ $ARCHIVE_STATUS -ne 0 ]]; then
  echo "Archive failed with exit code $ARCHIVE_STATUS" >&2
  exit "$ARCHIVE_STATUS"
fi

APP_PATH="$BUILD_DIR/$SCHEME.xcarchive/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "The build did not produce the application" >&2
  exit 1
fi
MCP_HELPER="$APP_PATH/Contents/MacOS/openramble-mcp"
if [[ ! -x "$MCP_HELPER" ]]; then
  echo "The build did not embed the MCP helper" >&2
  exit 1
fi
if otool -L "$MCP_HELPER" | grep -q '/Network\.framework/'; then
  echo "The local MCP helper unexpectedly links Network.framework" >&2
  exit 1
fi

# Binary targets dependencies can arrive universal, even when our target
# builds arm64. We remove someone else's x86_64 before the signature; lack of arm64 - hard
# failure, not a reason to leave a mixed artifact.
echo "→ Removing non-arm64 slices from bundled binary targets"
while IFS= read -r binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  archs=$(lipo -archs "$binary")
  [[ " $archs " == *" arm64 "* ]] || {
    echo "Mach-O doesn't have arm64 slice: $binary ($archs)" >&2
    exit 1
  }
  if [[ "$archs" != "arm64" ]]; then
    thinned="$binary.arm64-thinned"
    rm -f "$thinned"
    lipo "$binary" -thin arm64 -output "$thinned"
    mv "$thinned" "$binary"
  fi
done < <(find "$APP_PATH" -type f)

# The full texts of the licenses should be in the artifact itself, and not just
# links in README. Sources are taken from the same immutable package revisions,
# with which the application was just built.
echo "→ Adding full third-party licenses"
RESOURCES="$APP_PATH/Contents/Resources"
FLUID_LICENSES="$PACKAGE_CACHE/checkouts/FluidAudio"
SPARKLE_LICENSES="$PACKAGE_CACHE/checkouts/Sparkle"
for source in \
  "$FLUID_LICENSES/LICENSE" \
  "$FLUID_LICENSES/ThirdPartyLicenses/fastcluster-LICENSE.md" \
  "$FLUID_LICENSES/ThirdPartyLicenses/vbx-LICENSE.md" \
  "$SPARKLE_LICENSES/LICENSE"
do
  [[ -s "$source" ]] || { echo "No license in resolved dependency: $source" >&2; exit 1; }
done
cp "$FLUID_LICENSES/LICENSE" "$RESOURCES/FluidAudio-Apache-2.0.txt"
cp "$FLUID_LICENSES/ThirdPartyLicenses/fastcluster-LICENSE.md" "$RESOURCES/FluidAudio-fastcluster-BSD.txt"
cp "$FLUID_LICENSES/ThirdPartyLicenses/vbx-LICENSE.md" "$RESOURCES/FluidAudio-vbx-Apache-2.0.txt"
cp "$SPARKLE_LICENSES/LICENSE" "$RESOURCES/Sparkle-LICENSE.txt"

# CC BY 4.0 text has been submitted to the repository: the build should not require a network.
# Checksum remains - the file is legal, silent substitution is unacceptable.
CC_SOURCE="licenses/CC-BY-4.0.txt"
CC_SHA=$(shasum -a 256 "$CC_SOURCE" | awk '{print $1}')
if [[ "$CC_SHA" != "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411" ]]; then
  echo "CC BY 4.0 legalcode checksum mismatch: $CC_SHA" >&2
  exit 1
fi
cp "$CC_SOURCE" "$RESOURCES/Parakeet-CC-BY-4.0.txt"

# Every Mach-O in the artifact must be arm64-only: including Sparkle helpers.
echo "→ Checking arm64-only"
while IFS= read -r binary; do
  if ! file "$binary" | grep -q 'Mach-O'; then
    continue
  fi
  ARCHS=$(lipo -archs "$binary")
  echo "  ${binary#$APP_PATH/}: $ARCHS"
  if [[ "$ARCHS" != "arm64" ]]; then
    echo "Invalid slices in $binary: $ARCHS" >&2
    exit 1
  fi
done < <(find "$APP_PATH" -type f)

echo "→ Checking the minimum system version"
MIN_OS=$(vtool -show-build "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null | grep -m1 "minos" | awk '{print $2}')
echo "  minos $MIN_OS"
if [[ "$MIN_OS" != "14.0" ]]; then
  echo "Expected minOS 14.0, got $MIN_OS" >&2
  exit 1
fi

# The release identifier must remain unchanged forever: it is based on
# user-issued universal access. Debug-probe intentionally uses
# separate .dev identifier. We check before the signature, because his signature and
# pins.
echo "→ Checking ID"
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
echo "  $ACTUAL_BUNDLE_ID"
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Wrong identifier: expected $BUNDLE_ID, got "$ACTUAL_BUNDLE_ID"." >&2
  echo "Configuration $BUILD_CONFIGURATION was expected." >&2
  exit 1
fi

ACTUAL_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
echo "→ Build number: $ACTUAL_BUILD_NUMBER"
if [[ -n "$BUILD_NUMBER_OVERRIDE" && "$ACTUAL_BUILD_NUMBER" != "$BUILD_NUMBER_OVERRIDE" ]]; then
  echo "Build number override was not included in the artifact." >&2
  exit 1
fi

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ I sign"

  CODESIGN_ARGS=(--force)
  if [[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]]; then
    CODESIGN_ARGS+=("${CODESIGN_KEYCHAIN_ARGS[@]}")
  fi

  # You need to sign from the inside out, each nested component separately.
  # Order and composition - from Sparkle documentation (sparkle-project.org, section
  # about the sandbox and signature of components).
  #
  # --deep is prohibited here for two reasons. Apple announced it for signature
  # deprecated (“for emergency use only”): it applies the same options to
  # to all nested code, although it is signed differently. Sparkle asks not
  # apply it directly: Downloader.xpc signs with its entitlements,
  # which other binaries do not have, and do not have the same options
  # cover. What breaks down is not the assembly or notarization, but the installation
  # updates - that is, the first user will have nothing to repair.
  SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSION="$SPARKLE/Versions/B"

  sign() {
    codesign "${CODESIGN_ARGS[@]}" \
      --options runtime --timestamp --sign "$DEVELOPER_ID" "$@"
  }

  # If Sparkle moves to a different version letter or removes a component, silently
  # you can't skip it: the embedded code will remain with the ad-hoc assembly signature.
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    if [[ ! -e "$component" ]]; then
      echo "Can't find nested Sparkle component: $component" >&2
      echo "The framework layout has changed - update the list, otherwise part of the code" >&2
      echo "will be released with an ad-hoc signature." >&2
      exit 1
    fi
  done

  sign "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  # The only component that Sparkle specifically tells to save
  #entitlements. Our application is not in the sandbox, and now there is an empty list -
  # but this is exactly the place where the right to the network will appear if the sandbox is ever
  # will turn on. The flag is placed in advance so that the signature does not eat it silently.
  sign --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  sign "$SPARKLE_VERSION/Autoupdate"
  sign "$SPARKLE_VERSION/Updater.app"
  sign "$SPARKLE"
  sign --identifier "$BUNDLE_ID.mcp" "$MCP_HELPER"

  # Application last. We set the identifier explicitly so that it does not depend on
  # product name and build settings.
  sign --identifier "$BUNDLE_ID" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

  # But when checking, --deep is exactly what is needed: it bypasses nested code.
  echo "→ Checking signature"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  # Why check: the missing component will remain with an ad-hoc signature
  # builds. Notarization will reject this, and if it misses it, it will break down
  # installing the update. We check the identity of each component with
  # application identity.
  APP_AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  echo "credentials: ${APP_AUTHORITY:-ad-hoc}"
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE" \
    "$MCP_HELPER"
  do
    authority=$(codesign -dvv "$component" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    if [[ "$authority" != "$APP_AUTHORITY" ]]; then
      echo "The component is not signed by the same identity: $component" >&2
      echo "application: ${APP_AUTHORITY:-ad-hoc}" >&2
      echo "component: ${authority:-ad-hoc}" >&2
      exit 1
    fi
  done
  echo "the attached code is signed by the same identity"
else
  # After thinning and adding license resources, signing ready Sparkle
  # components are no longer valid. Debug-probe must pass strict
  # local code verification, so we rebuild the ad-hoc signature from the inside
  # out. Its .dev identity cannot pollute the production TCC grant.
  echo "→ I put a verifiable ad-hoc signature Debug-probe"
  SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  SPARKLE_VERSION="$SPARKLE/Versions/B"
  for component in \
    "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION/Autoupdate" \
    "$SPARKLE_VERSION/Updater.app" \
    "$SPARKLE"
  do
    [[ -e "$component" ]] || {
      echo "Can't find nested Sparkle component: $component" >&2
      exit 1
    }
  done

  codesign --force --sign - "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  codesign --force --sign - --preserve-metadata=entitlements \
    "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  codesign --force --sign - "$SPARKLE_VERSION/Autoupdate"
  codesign --force --sign - "$SPARKLE_VERSION/Updater.app"
  codesign --force --sign - "$SPARKLE"
  codesign --force --sign - --identifier "$BUNDLE_ID.mcp" "$MCP_HELPER"
  codesign --force --sign - --identifier "$BUNDLE_ID" \
    --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "→ Assembling the image"
STAGING="$DMG_DIR/staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# PlistBuddy, not defaults: defaults silently crashed along the way, and the fallback
# signed the image with someone else's version - release v0.1.0 with application 0.2.0 inside.
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$DMG_DIR/$DMG_BASENAME-$VERSION.dmg"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

if [[ -n "$DEVELOPER_ID" ]]; then
  echo "→ Signing DMG"
  codesign "${CODESIGN_ARGS[@]}" \
    --timestamp --sign "$DEVELOPER_ID" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi
hdiutil verify "$DMG_PATH" >/dev/null

if [[ -n "$DEVELOPER_ID" && ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  echo "→ Sending for notarization (this takes a few minutes)"
  NOTARY_RESULT=""
  NOTARY_ID=""
  NOTARY_COMMAND_STATUS=1
  NOTARY_STARTED_AT=$(date -u +%s)

  # Upload and wait are separated intentionally. notarytool can get the ID from
  # server, but fail with connectTimeout during subsequent polling. In this
  # in this case, re-upload is not needed: we find the latest submission by name and
  # we continue to wait for him.
  recover_recent_notary_id() {
    local history_json
    history_json=$(xcrun notarytool history \
      "${NOTARY_ARGS[@]}" --output-format json) || return 1
    NOTARY_HISTORY_JSON="$history_json" python3 - \
      "$(basename "$DMG_PATH")" "$NOTARY_STARTED_AT" <<'PY'
import datetime
import json
import os
import sys

name = sys.argv[1]
started_at = int(sys.argv[2])
payload = json.loads(os.environ["NOTARY_HISTORY_JSON"])
for item in payload.get("history", []):
    if item.get("name") != name:
        continue
    created = item.get("createdDate", "")
    try:
        created_at = int(datetime.datetime.fromisoformat(
            created.replace("Z", "+00:00")
        ).timestamp())
    except ValueError:
        continue
    if created_at >= started_at - 300:
        print(item["id"])
        break
PY
  }

  for attempt in 1 2 3; do
    if [[ -z "$NOTARY_ID" ]]; then
      set +e
      NOTARY_SUBMIT_RESULT=$(xcrun notarytool submit \
        "$DMG_PATH" "${NOTARY_ARGS[@]}" --output-format json)
      NOTARY_COMMAND_STATUS=$?
      set -e
      if [[ $NOTARY_COMMAND_STATUS -eq 0 ]]; then
        NOTARY_ID=$(printf '%s' "$NOTARY_SUBMIT_RESULT" \
          | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
      else
        sleep 2
        NOTARY_ID=$(recover_recent_notary_id || true)
        if [[ -n "$NOTARY_ID" ]]; then
          echo "upload accepted; continuing submission $NOTARY_ID after network failure"
        fi
      fi
    fi

    if [[ -n "$NOTARY_ID" ]]; then
      set +e
      NOTARY_RESULT=$(xcrun notarytool wait "$NOTARY_ID" \
        "${NOTARY_ARGS[@]}" --timeout 30m --output-format json)
      NOTARY_COMMAND_STATUS=$?
      set -e
      [[ $NOTARY_COMMAND_STATUS -eq 0 ]] && break
    fi

    if [[ $attempt -lt 3 ]]; then
      echo "notarytool: temporary network failure, trying $((attempt + 1)) of 3"
    fi
  done

  [[ $NOTARY_COMMAND_STATUS -eq 0 ]] || {
    echo "notarytool did not complete submission after three attempts." >&2
    exit 1
  }

  NOTARY_STATUS=$(printf '%s' "$NOTARY_RESULT" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
  RESULT_NOTARY_ID=$(printf '%s' "$NOTARY_RESULT" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
  [[ -n "$RESULT_NOTARY_ID" ]] && NOTARY_ID="$RESULT_NOTARY_ID"
  echo "  status: ${NOTARY_STATUS:-unknown}; id: ${NOTARY_ID:-unknown}"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    if [[ -n "$NOTARY_ID" ]]; then
      xcrun notarytool log "$NOTARY_ID" "${NOTARY_ARGS[@]}" || true
    fi
    echo "Notarization rejected." >&2
    exit 1
  fi
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  echo "→ Notarized"
else
  if [[ "$REQUIRE_NOTARIZATION" == "1" ]]; then
    echo "Notarization is required, but Developer ID or credentials are not specified." >&2
    exit 1
  fi
  echo "Notarization missing: this is not an installable beta"
fi

shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"
echo ""
echo "Done: $DMG_PATH"

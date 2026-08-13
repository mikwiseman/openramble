#!/bin/bash
set -euo pipefail

APP="${1:?Pass the path to OpenRamble.app}"
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)
[[ -n "$EXECUTABLE_NAME" ]] || { echo "There is no CFBundleExecutable in Info.plist." >&2; exit 1; }
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || { echo "No executable: $EXECUTABLE" >&2; exit 1; }
MCP_HELPER="$APP/Contents/MacOS/openramble-mcp"
[[ -x "$MCP_HELPER" ]] || { echo "No MCP helper: $MCP_HELPER" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$MCP_HELPER"
if otool -L "$MCP_HELPER" | grep -q '/Network\.framework/'; then
  echo "The local MCP helper links Network.framework." >&2
  exit 1
fi
"$(dirname "$0")/test-mcp-helper.sh" "$MCP_HELPER"

audio_input_entitlement=$(
  codesign -d --entitlements :- "$APP" 2>/dev/null \
    | /usr/bin/plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - - 2>/dev/null \
    || true
)
[[ "$audio_input_entitlement" == "true" ]] || {
  echo "The signature does not contain the required com.apple.security.device.audio-input=true." >&2
  exit 1
}

while IFS= read -r binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  archs=$(lipo -archs "$binary")
  [[ "$archs" == "arm64" ]] || {
    echo "Not arm64-only: $binary ($archs)" >&2
    exit 1
  }
done < <(find "$APP" -type f)

minos=$(vtool -show-build "$EXECUTABLE" | awk '/minos/{print $2; exit}')
[[ "$minos" == "14.0" ]] || { echo "Invalid minOS: $minos" >&2; exit 1; }

for resource in \
  LICENSE NOTICE THIRD_PARTY_LICENSES.md model-manifest.json \
  FluidAudio-Apache-2.0.txt FluidAudio-fastcluster-BSD.txt \
  FluidAudio-vbx-Apache-2.0.txt Sparkle-LICENSE.txt \
  Parakeet-CC-BY-4.0.txt
do
  [[ -s "$APP/Contents/Resources/$resource" ]] || {
    echo "No required resource: $resource" >&2
    exit 1
  }
done

echo "Installed artifact smoke: arm64-only, minOS 14.0, local MCP, audio input entitlement, signature/resources OK."

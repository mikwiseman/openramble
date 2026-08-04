#!/bin/bash
set -euo pipefail

APP="${1:?Передайте путь к Wai Dictation.app}"
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)
[[ -n "$EXECUTABLE_NAME" ]] || { echo "В Info.plist нет CFBundleExecutable." >&2; exit 1; }
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || { echo "Нет executable: $EXECUTABLE" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP"

audio_input_entitlement=$(
  codesign -d --entitlements :- "$APP" 2>/dev/null \
    | /usr/bin/plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - - 2>/dev/null \
    || true
)
[[ "$audio_input_entitlement" == "true" ]] || {
  echo "В подписи нет обязательного com.apple.security.device.audio-input=true." >&2
  exit 1
}

while IFS= read -r binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  archs=$(lipo -archs "$binary")
  [[ "$archs" == "arm64" ]] || {
    echo "Не arm64-only: $binary ($archs)" >&2
    exit 1
  }
done < <(find "$APP" -type f)

minos=$(vtool -show-build "$EXECUTABLE" | awk '/minos/{print $2; exit}')
[[ "$minos" == "14.0" ]] || { echo "Неверный minOS: $minos" >&2; exit 1; }

for resource in \
  LICENSE NOTICE THIRD_PARTY_LICENSES.md model-manifest.json \
  FluidAudio-Apache-2.0.txt FluidAudio-fastcluster-BSD.txt \
  FluidAudio-vbx-Apache-2.0.txt Sparkle-LICENSE.txt \
  Parakeet-CC-BY-4.0.txt
do
  [[ -s "$APP/Contents/Resources/$resource" ]] || {
    echo "Нет обязательного resource: $resource" >&2
    exit 1
  }
done

echo "Installed artifact smoke: arm64-only, minOS 14.0, audio input entitlement, signature/resources OK."

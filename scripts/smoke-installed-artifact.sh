#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_ARGUMENT="${1:?Pass OpenRamble.app or the exact OpenRamble DMG}"
if [[ "$ARTIFACT_ARGUMENT" == /* ]]; then
  ARTIFACT="$ARTIFACT_ARGUMENT"
else
  ARTIFACT="$PWD/$ARTIFACT_ARGUMENT"
fi
cd "$REPOSITORY_ROOT"

PROJECT_YML="apps/macos/project.yml"
OFFICIAL_FEED_URL="https://mikwiseman.github.io/openramble/appcast.xml"
PERMANENT_PUBLIC_KEY="9ATQM2BrR8XItn19YR1bHKzPn32SZ2oiyJb3dbqaJOI="
ASR_WORKER_ID="is.waiwai.dictation.asr-worker"

project_value() {
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *$/\1/p" "$PROJECT_YML" | head -1
}

EXPECTED_VERSION="${EXPECTED_VERSION:-$(project_value MARKETING_VERSION)}"
EXPECTED_BUILD="${EXPECTED_BUILD:-$(project_value CURRENT_PROJECT_VERSION)}"
EXPECTED_MIN_OS="${EXPECTED_MIN_OS:-14.0}"
EXPECTED_FEED_URL="${EXPECTED_FEED_URL:-$OFFICIAL_FEED_URL}"
EXPECTED_PUBLIC_KEY="${EXPECTED_PUBLIC_KEY:-$PERMANENT_PUBLIC_KEY}"
EXPECTED_APP_NAME="${EXPECTED_APP_NAME:-}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-}"
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"
REQUIRE_OFFLINE_RECOGNITION="${REQUIRE_OFFLINE_RECOGNITION:-0}"

for value_name in EXPECTED_VERSION EXPECTED_BUILD EXPECTED_MIN_OS EXPECTED_FEED_URL EXPECTED_PUBLIC_KEY; do
  [[ -n "${!value_name}" ]] || {
    echo "$value_name is empty; exact artifact verification cannot continue." >&2
    exit 1
  }
done
[[ "$REQUIRE_DEVELOPER_ID" == "0" || "$REQUIRE_DEVELOPER_ID" == "1" ]] || {
  echo "REQUIRE_DEVELOPER_ID accepts only 0 or 1." >&2
  exit 1
}
[[ "$REQUIRE_OFFLINE_RECOGNITION" == "0" || "$REQUIRE_OFFLINE_RECOGNITION" == "1" ]] || {
  echo "REQUIRE_OFFLINE_RECOGNITION accepts only 0 or 1." >&2
  exit 1
}
if [[ "$REQUIRE_DEVELOPER_ID" == "1" && "$REQUIRE_OFFLINE_RECOGNITION" != "1" ]]; then
  echo "Developer ID artifact smoke requires packaged-worker recognition with network denied." >&2
  exit 1
fi

MOUNT_DIRECTORY=""
TEMP_DIRECTORY=""
cleanup() {
  if [[ -n "$MOUNT_DIRECTORY" ]]; then
    hdiutil detach "$MOUNT_DIRECTORY" >/dev/null 2>&1 || true
    rmdir "$MOUNT_DIRECTORY" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_DIRECTORY" ]]; then
    rm -rf -- "$TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT

if [[ -f "$ARTIFACT" && "$ARTIFACT" == *.dmg ]]; then
  hdiutil verify "$ARTIFACT" >/dev/null
  MOUNT_DIRECTORY=$(mktemp -d -t openramble-dmg-smoke)
  hdiutil attach "$ARTIFACT" -nobrowse -readonly -mountpoint "$MOUNT_DIRECTORY" >/dev/null

  APP_CANDIDATES=()
  while IFS= read -r candidate; do
    APP_CANDIDATES+=("$candidate")
  done < <(find "$MOUNT_DIRECTORY" -maxdepth 1 -type d -name '*.app' -print)
  [[ ${#APP_CANDIDATES[@]} -eq 1 ]] || {
    echo "The DMG must contain exactly one top-level application." >&2
    exit 1
  }
  APP="${APP_CANDIDATES[0]}"
  [[ -L "$MOUNT_DIRECTORY/Applications" ]] || {
    echo "The DMG does not contain the Applications symlink." >&2
    exit 1
  }
  [[ "$(readlink "$MOUNT_DIRECTORY/Applications")" == "/Applications" ]] || {
    echo "The DMG Applications symlink does not point to /Applications." >&2
    exit 1
  }
  while IFS= read -r entry; do
    case "$(basename "$entry")" in
      "$(basename "${APP_CANDIDATES[0]}")"|Applications) ;;
      *)
        echo "Unexpected top-level DMG entry: $(basename "$entry")" >&2
        exit 1
        ;;
    esac
  done < <(find "$MOUNT_DIRECTORY" -mindepth 1 -maxdepth 1 -print)
else
  APP="$ARTIFACT"
fi

[[ -d "$APP" && "$APP" == *.app ]] || {
  echo "Artifact is neither a readable .app nor a readable .dmg: $ARTIFACT" >&2
  exit 1
}

APP_BASENAME="$(basename "$APP" .app)"
if [[ -z "$EXPECTED_APP_NAME" ]]; then
  EXPECTED_APP_NAME="$APP_BASENAME"
fi
[[ "$APP_BASENAME" == "$EXPECTED_APP_NAME" ]] || {
  echo "Invalid app name: expected $EXPECTED_APP_NAME, got $APP_BASENAME." >&2
  exit 1
}

if [[ -z "$EXPECTED_BUNDLE_ID" ]]; then
  case "$EXPECTED_APP_NAME" in
    OpenRamble) EXPECTED_BUNDLE_ID="is.waiwai.dictation" ;;
    OpenRambleDev) EXPECTED_BUNDLE_ID="is.waiwai.dictation.dev" ;;
    *)
      echo "EXPECTED_BUNDLE_ID is required for an unfamiliar app name." >&2
      exit 1
      ;;
  esac
fi

if [[ -n "$MOUNT_DIRECTORY" ]]; then
  EXPECTED_DMG_NAME="$EXPECTED_APP_NAME-$EXPECTED_VERSION.dmg"
  [[ "$(basename "$ARTIFACT")" == "$EXPECTED_DMG_NAME" ]] || {
    echo "Invalid DMG name: expected $EXPECTED_DMG_NAME, got $(basename "$ARTIFACT")." >&2
    exit 1
  }
fi

PLIST="$APP/Contents/Info.plist"
plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true
}
expect_plist() {
  local key="$1" expected="$2" actual
  actual=$(plist_value "$key")
  [[ "$actual" == "$expected" ]] || {
    echo "Invalid $key: expected '$expected', got '${actual:-missing}'." >&2
    exit 1
  }
}

expect_plist CFBundleExecutable "$EXPECTED_APP_NAME"
expect_plist CFBundleIdentifier "$EXPECTED_BUNDLE_ID"
expect_plist CFBundleShortVersionString "$EXPECTED_VERSION"
expect_plist CFBundleVersion "$EXPECTED_BUILD"
expect_plist LSMinimumSystemVersion "$EXPECTED_MIN_OS"
expect_plist LSUIElement true
expect_plist SUFeedURL "$EXPECTED_FEED_URL"
expect_plist SUPublicEDKey "$EXPECTED_PUBLIC_KEY"
expect_plist SUEnableAutomaticChecks true
expect_plist SUSendProfileInfo false
expect_plist SUAllowsAutomaticUpdates false

EXECUTABLE="$APP/Contents/MacOS/$EXPECTED_APP_NAME"
[[ -x "$EXECUTABLE" ]] || { echo "No executable: $EXECUTABLE" >&2; exit 1; }
MCP_HELPER="$APP/Contents/MacOS/openramble-mcp"
[[ ! -e "$MCP_HELPER" ]] || { echo "Unexpected MCP helper: $MCP_HELPER" >&2; exit 1; }
TEST_FIXTURE="$APP/Contents/MacOS/openramble-asr-worker-test-fixture"
[[ ! -e "$TEST_FIXTURE" ]] || { echo "Unexpected ASR test fixture: $TEST_FIXTURE" >&2; exit 1; }
ASR_WORKER="$APP/Contents/MacOS/openramble-asr-worker"
[[ -x "$ASR_WORKER" ]] || { echo "No private ASR worker: $ASR_WORKER" >&2; exit 1; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/B"
NESTED_CODE_COMPONENTS=(
  "$ASR_WORKER"
  "$SPARKLE_VERSION/XPCServices/Installer.xpc"
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
  "$SPARKLE_VERSION/Autoupdate"
  "$SPARKLE_VERSION/Updater.app"
  "$SPARKLE"
)

codesign --verify --strict --verbose=2 "$APP"
for component in "${NESTED_CODE_COMPONENTS[@]}"; do
  [[ -e "$component" ]] || {
    echo "Missing expected nested code component: $component" >&2
    exit 1
  }
  codesign --verify --strict --verbose=2 "$component"
done

app_signature_identifier=$(codesign -dvv "$APP" 2>&1 \
  | sed -n 's/^Identifier=//p' | head -1)
[[ "$app_signature_identifier" == "$EXPECTED_BUNDLE_ID" ]] || {
  echo "Invalid application signature identifier: $app_signature_identifier" >&2
  exit 1
}

audio_input_entitlement=$(
  codesign -d --entitlements :- "$APP" 2>/dev/null \
    | /usr/bin/plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - - 2>/dev/null \
    || true
)
[[ "$audio_input_entitlement" == "true" ]] || {
  echo "The signature does not contain com.apple.security.device.audio-input=true." >&2
  exit 1
}

if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
  APP_AUTHORITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
  [[ "$APP_AUTHORITY" == Developer\ ID\ Application:* ]] || {
    echo "The mounted application is not Developer ID signed: ${APP_AUTHORITY:-ad-hoc}." >&2
    exit 1
  }
  for component in "${NESTED_CODE_COMPONENTS[@]}"; do
    COMPONENT_AUTHORITY=$(codesign -dvv "$component" 2>&1 \
      | sed -n 's/^Authority=//p' | head -1)
    [[ "$COMPONENT_AUTHORITY" == "$APP_AUTHORITY" ]] || {
      echo "Nested code is not signed by the application identity: $component" >&2
      exit 1
    }
  done
  if [[ -n "$MOUNT_DIRECTORY" ]]; then
    codesign --verify --verbose=2 "$ARTIFACT"
    DMG_AUTHORITY=$(codesign -dvv "$ARTIFACT" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    [[ "$DMG_AUTHORITY" == "$APP_AUTHORITY" ]] || {
      echo "The DMG is not signed by the application identity." >&2
      exit 1
    }
  fi
fi

while IFS= read -r binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  codesign --verify --strict --verbose=2 "$binary"
  archs=$(lipo -archs "$binary")
  [[ "$archs" == "arm64" ]] || {
    echo "Not arm64-only: $binary ($archs)" >&2
    exit 1
  }
done < <(find "$APP" -type f)

minos=$(vtool -show-build "$EXECUTABLE" | awk '/minos/{print $2; exit}')
[[ "$minos" == "$EXPECTED_MIN_OS" ]] || {
  echo "Invalid executable minOS: expected $EXPECTED_MIN_OS, got $minos." >&2
  exit 1
}
worker_minos=$(vtool -show-build "$ASR_WORKER" | awk '/minos/{print $2; exit}')
[[ "$worker_minos" == "$EXPECTED_MIN_OS" ]] || {
  echo "Invalid ASR worker minOS: expected $EXPECTED_MIN_OS, got $worker_minos." >&2
  exit 1
}

worker_identifier=$(codesign -dvv "$ASR_WORKER" 2>&1 | sed -n 's/^Identifier=//p' | head -1)
[[ "$worker_identifier" == "$ASR_WORKER_ID" ]] || {
  echo "Invalid ASR worker signature identifier: $worker_identifier" >&2
  exit 1
}

WORKER_DEPENDENCIES=$(otool -L "$ASR_WORKER") || {
  echo "Could not inspect ASR worker dynamic-library dependencies." >&2
  exit 1
}
if printf '%s\n' "$WORKER_DEPENDENCIES" \
  | grep -Eq '/(Network|NetworkExtension|WebKit)\.framework/'; then
  echo "The private ASR worker links a forbidden network/UI framework." >&2
  exit 1
fi
WORKER_LINKS_CFNETWORK=0
WORKER_CONTAINS_URLSESSION=0
if printf '%s\n' "$WORKER_DEPENDENCIES" \
  | grep -E '/CFNetwork\.framework/' >/dev/null; then
  WORKER_LINKS_CFNETWORK=1
fi
strings "$ASR_WORKER" >/dev/null || {
  echo "Could not inspect strings in the ASR worker." >&2
  exit 1
}
if strings "$ASR_WORKER" \
  | grep -E 'URLSessionModelDownloader|NSURLSession|https://huggingface\.co' >/dev/null; then
  WORKER_CONTAINS_URLSESSION=1
fi
if [[ "$WORKER_LINKS_CFNETWORK" == "1" || "$WORKER_CONTAINS_URLSESSION" == "1" ]]; then
  echo "NOTICE: packaged worker contains CFNetwork/URLSession downloader code via LocalASR linkage."
  echo "No binary-level transport-free claim is made; release requires deny-network recognition."
fi
WORKER_UNDEFINED_SYMBOLS=$(nm -u "$ASR_WORKER" 2>/dev/null) || {
  echo "Could not inspect undefined symbols in the ASR worker." >&2
  exit 1
}
if printf '%s\n' "$WORKER_UNDEFINED_SYMBOLS" \
  | grep -Eq '[[:space:]]_(accept|accept4|bind|connect|connectx|getaddrinfo|gethostbyname|getnameinfo|listen|recv|recvfrom|recvmsg|send|sendmsg|sendto|socket|socketpair)(\$[^[:space:]]+)?$'; then
  echo "The private ASR worker directly imports a socket/DNS primitive." >&2
  exit 1
fi

scripts/test-asr-worker.sh "$ASR_WORKER"

for resource in \
  LICENSE NOTICE THIRD_PARTY_LICENSES.md model-manifest.json vocabulary-manifest.json \
  FluidAudio-Apache-2.0.txt FluidAudio-fastcluster-BSD.txt \
  FluidAudio-vbx-Apache-2.0.txt Sparkle-LICENSE.txt \
  Parakeet-CC-BY-4.0.txt
do
  [[ -s "$APP/Contents/Resources/$resource" ]] || {
    echo "No required resource: $resource" >&2
    exit 1
  }
done

if [[ "$REQUIRE_OFFLINE_RECOGNITION" == "1" ]]; then
  MODEL_DIRECTORY="${WAI_PACKAGED_WORKER_MODEL_DIRECTORY:-}"
  if [[ -z "$MODEL_DIRECTORY" ]]; then
    MODELS_ROOT="${WAI_MODELS_ROOT:-$HOME/Library/Application Support/OpenRamble/Models}"
    MODEL_DIRECTORY=$(/usr/bin/python3 - \
      "$APP/Contents/Resources/model-manifest.json" "$MODELS_ROOT" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
folder = manifest["repository"].rsplit("/", 1)[-1]
if folder.endswith("-coreml"):
    folder = folder[:-7]
print(os.path.join(sys.argv[2], manifest["modelID"], manifest["revision"], folder))
PY
    )
  fi
  [[ -d "$MODEL_DIRECTORY" ]] || {
    echo "The installed model required for packaged-worker offline proof is missing:" >&2
    echo "  $MODEL_DIRECTORY" >&2
    exit 69
  }

  TEMP_DIRECTORY=$(mktemp -d -t openramble-offline-smoke)
  FIXTURE="${WAI_PACKAGED_WORKER_FIXTURE:-}"
  EXPECTED_TEXT="${WAI_EXPECTED_TEXT:-Checking work without the Internet}"
  if [[ -z "$FIXTURE" ]]; then
    say -v Samantha -o "$TEMP_DIRECTORY/probe-en.aiff" "$EXPECTED_TEXT"
    afconvert -f WAVE -d LEI16@16000 -c 1 \
      "$TEMP_DIRECTORY/probe-en.aiff" "$TEMP_DIRECTORY/probe-en.wav"
    FIXTURE="$TEMP_DIRECTORY/probe-en.wav"
  elif [[ -z "${WAI_EXPECTED_TEXT:-}" ]]; then
    echo "WAI_EXPECTED_TEXT is required with a custom offline fixture." >&2
    exit 64
  fi
  [[ -f "$FIXTURE" ]] || { echo "No offline fixture: $FIXTURE" >&2; exit 1; }

  PROFILE="$TEMP_DIRECTORY/no-network.sb"
  cat > "$PROFILE" <<'PROFILE_END'
(version 1)
(allow default)
(deny network*)
PROFILE_END

  # Positive control: this exact sandbox profile must turn a local connect into
  # EPERM. A missing or ignored sandbox is therefore a hard failure, not a pass.
  sandbox-exec -f "$PROFILE" /usr/bin/python3 -c \
    'import errno,socket,sys
try:
    socket.socket().connect(("127.0.0.1", 9))
except PermissionError as error:
    sys.exit(0 if error.errno == errno.EPERM else 2)
except OSError:
    sys.exit(3)
sys.exit(4)'
  echo "Deny-network sandbox positive control passed (connect returned EPERM)."

  sandbox-exec -f "$PROFILE" /usr/bin/python3 \
    scripts/tests/packaged-worker-offline.py \
    "$ASR_WORKER" "$MODEL_DIRECTORY" "$FIXTURE" "$EXPECTED_TEXT"
  echo "The exact packaged worker recognized with network access denied by macOS."
fi

echo "Installed artifact smoke: exact identity/version/build/feed/key/minOS, arm64-only code, mounted DMG layout, private ASR protocol, dictation-only contents, entitlement, signature and resources OK."

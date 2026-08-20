#!/bin/bash
# Prepare the pinned native Sparkle framework used by the Tauri macOS bundle.
#
# The framework is a generated build input and is ignored by git. Its checksum
# is fixed here. This script never runs Sparkle's key generator; OpenRamble uses
# the permanent key documented in AGENTS.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.9.4"
EXPECTED_SHA256="ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
CACHE=".build-tools/sparkle-$VERSION"
ARCHIVE="$CACHE/Sparkle-$VERSION.tar.xz"
FRAMEWORK="$CACHE/Sparkle.framework"
DESTINATION="apps/desktop/src-tauri/Sparkle.framework"

mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 --output "$ARCHIVE" "$URL"
fi

ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Sparkle archive checksum mismatch: $ACTUAL_SHA256" >&2
  exit 1
fi

if [[ ! -d "$FRAMEWORK" ]]; then
  tar -xJf "$ARCHIVE" -C "$CACHE"
fi
if [[ ! -d "$FRAMEWORK" ]]; then
  echo "The verified Sparkle archive did not contain Sparkle.framework." >&2
  exit 1
fi

if [[ -L "$DESTINATION" ]]; then
  unlink "$DESTINATION"
fi
if [[ ! -d "$DESTINATION" ]]; then
  # Tauri's framework copier must traverse the bundle. An outer symlink looks
  # valid to the linker but is not traversed by the bundler, so keep a generated
  # local copy while preserving Sparkle's internal framework symlinks.
  ditto "$FRAMEWORK" "$DESTINATION"
fi
echo "Prepared Sparkle $VERSION at $DESTINATION"

#!/bin/bash
# XcodeGen 2.46.0, опубликованный 2026-07-16. Версия и archive checksum
# проверяются до исполнения; Homebrew latest в release/CI не используется.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
ROOT=".build-tools/xcodegen-$VERSION"
BIN="$ROOT/xcodegen/bin/xcodegen"

if [[ ! -x "$BIN" ]]; then
  mkdir -p ".build-tools"
  ZIP=$(mktemp ".build-tools/xcodegen.XXXXXX.zip")
  trap 'rm -f "$ZIP"' EXIT
  curl --fail --location --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" \
    --output "$ZIP"
  ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  if [[ "$ACTUAL" != "$SHA256" ]]; then
    echo "XcodeGen checksum mismatch: $ACTUAL" >&2
    exit 1
  fi
  rm -rf "$ROOT"
  mkdir -p "$ROOT"
  ditto -x -k "$ZIP" "$ROOT"
fi

"$BIN" --version >&2
printf '%s/%s\n' "$PWD" "$BIN"

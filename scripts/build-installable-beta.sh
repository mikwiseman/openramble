#!/bin/bash
# Stable QA build. Unlike the probe image, it retains the same
# designated requirement, so the Accessibility grant doesn't break every time
# changing the binary.

set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: WaiWai, LLC (R4A779QVVY)}"
ALLOW_DIRTY_BETA="${ALLOW_DIRTY_BETA:-0}"

HEAD_SHA=$(git rev-parse --verify HEAD)
if [[ -n "$(git status --porcelain)" && "$ALLOW_DIRTY_BETA" != "1" ]]; then
  echo "Installable beta is not built from dirty wood." >&2
  echo "For local QA uncommitted code, specify ALLOW_DIRTY_BETA=1 explicitly." >&2
  exit 1
fi

echo "→ Initial commit: $HEAD_SHA"
if [[ "$ALLOW_DIRTY_BETA" == "1" ]]; then
  echo "Dirty-tree override: artifact for local QA only, not for public distribution."
  BUILD_NUMBER_OVERRIDE="${BUILD_NUMBER_OVERRIDE:-$(date -u +%y%m%d%H%M)}"
  export BUILD_NUMBER_OVERRIDE
  echo "Unique QA build number: $BUILD_NUMBER_OVERRIDE"
fi

if ! security find-identity -v -p codesigning \
  | grep -Fq "\"$DEVELOPER_ID\""; then
  echo "Certificate not found: $DEVELOPER_ID" >&2
  exit 1
fi

DEVELOPER_ID="$DEVELOPER_ID" \
REQUIRE_NOTARIZATION=1 \
./scripts/build-dmg.sh

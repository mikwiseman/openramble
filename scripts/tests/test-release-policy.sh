#!/bin/bash
# Guard the small set of release invariants that would strand installed copies.
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() { echo "FAIL: $1" >&2; exit 1; }
BUILD=scripts/build-tauri-dmg.sh
RELEASE=scripts/release.sh
SMOKE=scripts/smoke-installed-artifact.sh

bash -n "$BUILD" "$RELEASE" "$SMOKE" scripts/ship.sh

for invariant in \
  'BUNDLE_ID=$(json_value '\''.identifier'\'')' \
  'OFFICIAL_FEED_URL="https://mikwiseman.github.io/openramble/appcast.xml"' \
  'PERMANENT_PUBLIC_KEY="9ATQM2BrR8XItn19YR1bHKzPn32SZ2oiyJb3dbqaJOI="' \
  'EXPECTED_MIN_OS="14.0"' \
  '--target universal-apple-darwin' \
  'REQUIRE_OFFLINE_RECOGNITION' \
  'xcrun notarytool submit' \
  'xcrun stapler validate' \
  './scripts/smoke-installed-artifact.sh "$DMG_PATH"'
do
  grep -Fq -- "$invariant" "$BUILD" || fail "release builder lost: $invariant"
done

for invariant in \
  'expect_plist CFBundleIdentifier "$EXPECTED_BUNDLE_ID"' \
  'expect_plist SUFeedURL "$EXPECTED_FEED_URL"' \
  'expect_plist SUPublicEDKey "$EXPECTED_PUBLIC_KEY"' \
  'Not universal arm64+x86_64' \
  'REQUIRE_DEVELOPER_ID' \
  './scripts/test-zero-network.sh'
do
  grep -Fq -- "$invariant" "$SMOKE" || fail "artifact smoke lost: $invariant"
done

grep -Fq -- '--verify --ed-key-file' "$RELEASE" || fail "Sparkle signature verification disappeared"
grep -Fq 'assert_release_source_unchanged "immediately before appcast mutation"' "$RELEASE" \
  || fail "source snapshot is not checked at publication"
grep -Fq 'UNSIGNED_RELEASE_TOPOLOGY: "1"' .github/workflows/ci.yml \
  || fail "CI no longer builds the production topology"
if grep -Fq -- '--deep' "$BUILD" "$SMOKE"; then
  fail "release signing or verification relies on recursive codesign"
fi
if grep -Fq 'generate_keys' "$BUILD" "$RELEASE"; then
  fail "release code mentions generating a replacement Sparkle key"
fi

echo "PASS: Tauri release keeps the permanent update and artifact gates"

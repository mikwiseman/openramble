#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE_SCRIPT="$REPOSITORY_ROOT/scripts/release.sh"
BUILD_SCRIPT="$REPOSITORY_ROOT/scripts/build-dmg.sh"
PROJECT_YML="$REPOSITORY_ROOT/apps/macos/project.yml"
SMOKE_SCRIPT="$REPOSITORY_ROOT/scripts/smoke-installed-artifact.sh"
NETWORK_SCRIPT="$REPOSITORY_ROOT/scripts/check-network-surface.sh"
OFFLINE_DRIVER="$REPOSITORY_ROOT/scripts/tests/packaged-worker-offline.py"
RELEASE_DOC="$REPOSITORY_ROOT/docs/release.md"
CI_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/ci.yml"

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

if grep -Eq 'LIVE_BENCHMARK_REPORT|validate-live-benchmark|RELEASE_EVIDENCE|validate-release-evidence' "$RELEASE_SCRIPT"; then
  fail_test "a human quality report still blocks or participates in release.sh"
fi

for required_gate in \
  'check-network-surface.sh' \
  'test-zero-network.sh' \
  'test-zero-network-trace.sh' \
  'smoke-installed-artifact.sh' \
  '--verify --ed-key-file' \
  'stapler validate' \
  'spctl --assess'
do
  grep -Fq -- "$required_gate" "$RELEASE_SCRIPT" \
    || fail_test "release safety gate disappeared: $required_gate"
done

if grep -Fq 'REUSE_VERIFIED_ARTIFACT' "$RELEASE_SCRIPT"; then
  fail_test "release.sh can still reuse an artifact that may belong to another SHA"
fi
grep -Fq 'assert_release_source_unchanged "before the fresh archive build"' "$RELEASE_SCRIPT" \
  || fail_test "release source snapshot is not rechecked before the archive"
grep -Fq 'assert_release_source_unchanged "after building and verifying the exact DMG"' "$RELEASE_SCRIPT" \
  || fail_test "release source snapshot is not rechecked before publishing"
grep -Fq 'assert_release_source_unchanged "immediately before appcast mutation"' "$RELEASE_SCRIPT" \
  || fail_test "release source snapshot is not rechecked at the publication boundary"
if grep -Fq 'generate_keys' "$RELEASE_SCRIPT"; then
  fail_test "release.sh still instructs the operator to generate a replacement Sparkle key"
fi
if grep -Fq 'SUPublicEDKey: \"$DERIVED_KEY\"' "$RELEASE_SCRIPT"; then
  fail_test "release.sh still tells the operator to replace the permanent public key"
fi
grep -Fq 'Do not change SUPublicEDKey.' "$RELEASE_SCRIPT" \
  || fail_test "private-key mismatch no longer directs permanent-key recovery"
if grep -Fq 'generate_keys' "$PROJECT_YML"; then
  fail_test "project.yml still tells maintainers to generate a replacement Sparkle key"
fi
grep -Fq 'Do not run Sparkle `generate_keys`' "$RELEASE_DOC" \
  || fail_test "release docs no longer prohibit replacement Sparkle key generation"
grep -Fq './scripts/bootstrap-release-secrets.sh' "$RELEASE_DOC" \
  || fail_test "release docs do not point to permanent-key recovery"
grep -Fq 'Do not describe this binary as transport-free' "$RELEASE_DOC" \
  || fail_test "release docs conceal the worker's linked downloader symbols"

for exact_release_gate in \
  'EXPECTED_BUNDLE_ID="is.waiwai.dictation"' \
  'EXPECTED_FEED_URL="https://mikwiseman.github.io/openramble/appcast.xml"' \
  'EXPECTED_PUBLIC_KEY="9ATQM2BrR8XItn19YR1bHKzPn32SZ2oiyJb3dbqaJOI="' \
  'EXPECTED_MIN_OS="14.0"' \
  'EXPECTED_BUILD=$(yml_value CURRENT_PROJECT_VERSION)' \
  'shasum -a 256 -c "$DMG_PATH.sha256"' \
  './scripts/smoke-installed-artifact.sh "$DMG_PATH"' \
  'REQUIRE_DEVELOPER_ID=1' \
  'REQUIRE_OFFLINE_RECOGNITION=1'
do
  grep -Fq -- "$exact_release_gate" "$RELEASE_SCRIPT" \
    || fail_test "exact release-artifact gate disappeared: $exact_release_gate"
done

for mounted_artifact_gate in \
  'hdiutil attach "$ARTIFACT"' \
  '-readonly' \
  'Unexpected top-level DMG entry:' \
  'EXPECTED_DMG_NAME="$EXPECTED_APP_NAME-$EXPECTED_VERSION.dmg"' \
  'expect_plist CFBundleIdentifier "$EXPECTED_BUNDLE_ID"' \
  'expect_plist CFBundleShortVersionString "$EXPECTED_VERSION"' \
  'expect_plist CFBundleVersion "$EXPECTED_BUILD"' \
  'expect_plist SUFeedURL "$EXPECTED_FEED_URL"' \
  'expect_plist SUPublicEDKey "$EXPECTED_PUBLIC_KEY"' \
  'expect_plist LSMinimumSystemVersion "$EXPECTED_MIN_OS"' \
  'app_signature_identifier' \
  'No binary-level transport-free claim is made' \
  'getnameinfo' \
  'sandbox-exec -f "$PROFILE"' \
  'scripts/tests/packaged-worker-offline.py'
do
  grep -Fq -- "$mounted_artifact_gate" "$SMOKE_SCRIPT" \
    || fail_test "mounted artifact/offline gate disappeared: $mounted_artifact_gate"
done

grep -Fq 'WORKER_CONTROL_FORBIDDEN=' "$NETWORK_SCRIPT" \
  || fail_test "ASR worker control-plane network scan disappeared"
grep -Fq 'except PermissionError as error:' "$SMOKE_SCRIPT" \
  || fail_test "deny-network sandbox has no positive control"
grep -Fq 'Developer ID artifact smoke requires packaged-worker recognition with network denied.' "$SMOKE_SCRIPT" \
  || fail_test "Developer ID artifact smoke permits skipping offline recognition"
grep -Fq 'PREPARE_MAIN = 3' "$OFFLINE_DRIVER" \
  || fail_test "packaged-worker proof no longer loads the model"
grep -Fq 'TRANSCRIBE_FILE = 7' "$OFFLINE_DRIVER" \
  || fail_test "packaged-worker proof no longer performs recognition"
/usr/bin/python3 -m py_compile "$OFFLINE_DRIVER"

grep -Fq 'PRODUCT_NAME: OpenRamble' "$PROJECT_YML" \
  || fail_test "shipping product name is not OpenRamble"
grep -Fq 'APP_NAME="OpenRamble"' "$RELEASE_SCRIPT" \
  || fail_test "release.sh still publishes the old product name"
grep -Fq 'DMG_BASENAME="OpenRamble"' "$BUILD_SCRIPT" \
  || fail_test "production DMG still uses the old product name"
grep -Fq './scripts/smoke-installed-artifact.sh "$DMG_PATH"' "$BUILD_SCRIPT" \
  || fail_test "build-dmg.sh does not mount and smoke the DMG it just created"
grep -Fq 'A notarized build requires packaged-worker recognition with network denied.' "$BUILD_SCRIPT" \
  || fail_test "build-dmg.sh permits notarization without packaged-worker offline recognition"
grep -Fq 'UNSIGNED_RELEASE_TOPOLOGY="${UNSIGNED_RELEASE_TOPOLOGY:-0}"' "$BUILD_SCRIPT" \
  || fail_test "build-dmg.sh lost the CI-only production Release topology"
grep -Fq '"${CI:-}" != "true"' "$BUILD_SCRIPT" \
  || fail_test "unsigned production topology is no longer restricted to CI"
grep -Fq 'UNSIGNED_RELEASE_TOPOLOGY: "1"' "$CI_WORKFLOW" \
  || fail_test "CI no longer exercises the production Release topology"
grep -Fq 'artifacts/dmg/OpenRamble-*.dmg' "$CI_WORKFLOW" \
  || fail_test "CI does not smoke the production-shaped DMG"
if grep -Fq 'OpenRambleDev.app' "$CI_WORKFLOW"; then
  fail_test "release-build CI still validates the Debug application topology"
fi
if grep -Fq -- '--deep' "$BUILD_SCRIPT" "$SMOKE_SCRIPT"; then
  fail_test "release artifact verification still relies on recursive codesign"
fi
grep -Fq 'NESTED_CODE_COMPONENTS=(' "$SMOKE_SCRIPT" \
  || fail_test "artifact smoke no longer enumerates expected nested code"
grep -Fq 'if [[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]]; then' "$BUILD_SCRIPT" \
  || fail_test "legacy Developer ID signing still expands an empty keychain array under nounset"
grep -Fq 'CODESIGN_ARGS=(--force)' "$BUILD_SCRIPT" \
  || fail_test "codesign arguments are not initialized for the legacy login-keychain path"
grep -Fq 'CODESIGN_ARGS+=("${CODESIGN_KEYCHAIN_ARGS[@]}")' "$BUILD_SCRIPT" \
  || fail_test "release-keychain codesign arguments are not appended conditionally"
if grep -Fq 'codesign --force "${CODESIGN_KEYCHAIN_ARGS[@]}"' "$BUILD_SCRIPT"; then
  fail_test "legacy Developer ID codesign still expands an empty keychain array under nounset"
fi

printf 'PASS: autonomous release keeps machine-verifiable artifact gates\n'

#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RELEASE_SCRIPT="$REPOSITORY_ROOT/scripts/release.sh"
BUILD_SCRIPT="$REPOSITORY_ROOT/scripts/build-dmg.sh"
PROJECT_YML="$REPOSITORY_ROOT/apps/macos/project.yml"

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

grep -Fq 'PRODUCT_NAME: OpenRamble' "$PROJECT_YML" \
  || fail_test "shipping product name is not OpenRamble"
grep -Fq 'APP_NAME="OpenRamble"' "$RELEASE_SCRIPT" \
  || fail_test "release.sh still publishes the old product name"
grep -Fq 'DMG_BASENAME="OpenRamble"' "$BUILD_SCRIPT" \
  || fail_test "production DMG still uses the old product name"
grep -Fq 'if [[ "$RELEASE_KEYCHAIN_ACTIVE" == "1" ]]; then' "$BUILD_SCRIPT" \
  || fail_test "legacy Developer ID signing still expands an empty keychain array under nounset"

printf 'PASS: autonomous release keeps machine-verifiable artifact gates\n'

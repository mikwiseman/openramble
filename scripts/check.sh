#!/bin/bash
# Banish everything that should be green before committing.
#
# ./scripts/check.sh both packages + application + network gate
# ./scripts/check.sh --fast packets and gate only (seconds, no Xcode)
# ./scripts/check.sh --app application only
#
# The script itself fixes the build freeze, which everyone else stumbles over: SwiftPM
# asks Keychain for credentials for the binary artifact download host
# Sparkle, but there is no one to show the dialog from the terminal - and the request waits forever, at 0%
# CPU, without a single line in the log. It can be treated by placing the artifact once
# to the shared cache by running with --disable-keychain; then xcodebuild takes it
# does not go from there to Keychain at all.
#
# The cache is shared and survives DerivedData deletion, but does not survive purge
# ~/Library/Caches. Therefore, the check is cheap and done every time.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
ARTIFACT_CACHE="$HOME/Library/Caches/org.swift.swiftpm/artifacts"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

fail() { red "$1"; exit 1; }

# --- Warming up the binary artifact cache ---------------------------------------

warm_artifact_cache() {
  # We take the revision from project.yml, and not hardcode: when updating Sparkle
  # The cache will warm up for the new version on its own, without editing this script.
  local revision
  revision=$(sed -n 's/^ *revision: *\([0-9a-f]\{40\}\).*/\1/p' apps/macos/project.yml | head -1)
  [[ -n "$revision" ]] || fail "Can't find Sparkle revision in apps/macos/project.yml"

  if compgen -G "$ARTIFACT_CACHE/*Sparkle*" > /dev/null 2>&1; then
    return 0
  fi

  echo "→ Artifact cache is empty - I'm warming it up (otherwise xcodebuild will hang on Keychain)"
  local work
  work=$(mktemp -d)
  mkdir -p "$work/Sources/Warm"
  cat > "$work/Package.swift" <<SWIFT
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Warm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", revision: "$revision")
    ],
    targets: [
        .target(name: "Warm", dependencies: [.product(name: "Sparkle", package: "Sparkle")])
    ]
)
SWIFT
  echo "public let warm = 1" > "$work/Sources/Warm/Warm.swift"

  if (cd "$work" && swift build --disable-keychain > /dev/null 2>&1); then
    green "cache is warm"
  else
    rm -rf "$work"
    fail "Failed to warm up the artifact cache.
Check the network: curl -sSI https://github.com/sparkle-project/Sparkle/releases/latest | head -1"
  fi
  rm -rf "$work"
}

# --- Steps ------------------------------------------------------------------

run_packages() {
  for package in DictationCore LocalASR; do
    echo "→ $package"
    local log
    log=$(mktemp)
    if swift test --package-path "Packages/$package" > "$log" 2>&1; then
      # We look for the line with the counter in the entire output, not in the tail: after it
      # swift-testing prints its lines, and tail does not catch it.
      grep -E "Executed [0-9]+ tests, with" "$log" | tail -1
    else
      grep -E "error:|failed" "$log" | head -20
      rm -f "$log"
      fail "$package tests failed."
    fi
    rm -f "$log"
  done
}

run_app() {
  warm_artifact_cache
  echo "→ Generating a project"
  local xcodegen
  xcodegen=$(scripts/pinned-xcodegen.sh)
  (cd apps/macos && "$xcodegen" generate > /dev/null)

  echo "→Application tests"
  local log
  log=$(mktemp)
  if (cd apps/macos && xcodebuild -project OpenRamble.xcodeproj -scheme OpenRamble \
        -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test) > "$log" 2>&1; then
    grep -E "Executed [0-9]+ tests, with" "$log" | tail -1
  else
    grep -E "error:" "$log" | head -20
    rm -f "$log"
    fail "Application tests failed."
  fi
  rm -f "$log"
}

run_network_gate() {
  echo "→ Network Surface"
  ./scripts/check-network-surface.sh > /dev/null || fail "Network gate failed."
  green "the promise about the network stands"
}

case "$MODE" in
  --fast) run_packages; run_network_gate ;;
  --app)  run_app ;;
  all|*)  run_packages; run_app; run_network_gate ;;
esac

green "
Everything is green."

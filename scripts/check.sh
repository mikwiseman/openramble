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
    # -warnings-as-errors because that is what CI does. Without it this script
    # said "everything is green" on code CI then rejected, which is worse than
    # no check at all: it spends the trust it was built to earn.
    if swift build --package-path "Packages/$package" --build-tests \
         -Xswiftc -warnings-as-errors > "$log" 2>&1 \
       && swift test --package-path "Packages/$package" >> "$log" 2>&1; then
      # We look for the line with the counter in the entire output, not in the tail: after it
      # swift-testing prints its lines, and tail does not catch it.
      grep -E "Executed [0-9]+ tests, with|Test run with [0-9]+ tests" "$log" \
        | grep -v "Test run with 0 tests" \
        | tail -1
    else
      grep -E "error:|failed" "$log" | head -20
      rm -f "$log"
      fail "$package tests failed."
    fi
    rm -f "$log"
  done
}

run_shared_core() {
  echo "→ Shared core"
  command -v cargo > /dev/null || fail "cargo is not installed; the shared core cannot be checked."

  # A local toolchain older than the pinned one runs an older clippy, which has
  # fewer lints. It will call code green that CI then rejects — the exact
  # failure mode this script exists to prevent, so it is said out loud.
  local pinned local_version
  pinned=$(sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml)
  local_version=$(cargo --version | awk '{print $2}')
  if [[ -n "$pinned" && "$pinned" != "$local_version" ]]; then
    echo "  note: local Rust is $local_version, CI pins $pinned."
    echo "        Lint results here are advisory; CI is authoritative."
  fi
  local log
  log=$(mktemp)
  # The same gate CI runs. Saying "green" here on code CI then rejects spends
  # exactly the trust this script exists to earn.
  # The same scope CI uses: the core crates. The desktop app is built by its
  # own job, because on Linux it needs GTK and WebKit and a missing system
  # library is not a regression in the shared logic.
  CORE_PACKAGES=(-p ramble-core -p ramble-text -p ramble-model -p ramble-audio -p ramble-history)
  if cargo fmt --all --check > "$log" 2>&1 \
     && cargo clippy "${CORE_PACKAGES[@]}" --all-targets --all-features -- -D warnings >> "$log" 2>&1 \
     && cargo test "${CORE_PACKAGES[@]}" --all-features >> "$log" 2>&1; then
    # Sum every suite rather than tailing: the last line is the doc-test run,
    # which reports zero and reads like nothing happened.
    awk '/^test result: ok/ { total += $4 } END { printf "\t Executed %d tests, with 0 failures\n", total }' "$log"
  else
    grep -E "^error|panicked|FAILED|Diff in" "$log" | head -20
    rm -f "$log"
    fail "Shared core checks failed."
  fi
  rm -f "$log"

  # The bridge the macOS migration crosses. Built here so an API change Swift
  # cannot call fails now rather than at migration time.
  echo "→ Swift calls the core"
  if ./scripts/build-ffi.sh > /dev/null 2>&1 \
     && swift test --package-path Packages/RambleCoreFFI > /dev/null 2>&1; then
    green "the boundary holds"
  else
    fail "The Swift bridge to the shared core failed."
  fi

  # The fixtures are recordings of the shipping Swift pipeline. Regenerating
  # them is how a change to DictationCore that the port has not followed gets
  # noticed here rather than on a Windows machine three phases from now.
  echo "→ Core matches macOS"
  local generator=core/conformance/generator
  if swift build --package-path "$generator" > /dev/null 2>&1 \
     && "$generator/.build/debug/GenerateFixtures" \
          core/conformance/corpus-text.json \
          core/conformance/fixtures/text/pipeline.json 2> /dev/null; then
    git diff --quiet -- core/conformance/fixtures \
      || fail "The macOS pipeline or starter dictionary no longer matches what is committed."
    cargo test -p ramble-text --test conformance > /dev/null 2>&1 \
      || fail "The Rust core no longer reproduces what macOS produced."
    green "both implementations agree"
  else
    fail "Could not regenerate the conformance fixtures."
  fi
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

  echo "→ Application artifact"
  log=$(mktemp)
  if (cd apps/macos && xcodebuild -project OpenRamble.xcodeproj -scheme OpenRamble \
        -configuration Debug -destination 'platform=macOS,arch=arm64' \
        CODE_SIGNING_ALLOWED=NO build) > "$log" 2>&1; then
    :
  else
    grep -E "error:" "$log" | head -20
    rm -f "$log"
    fail "Application artifact build failed."
  fi
  rm -f "$log"

  local settings built_products_dir full_product_name app
  settings=$(cd apps/macos && xcodebuild -project OpenRamble.xcodeproj \
    -scheme OpenRamble -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -showBuildSettings 2>/dev/null)
  built_products_dir=$(sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' <<<"$settings" | head -1)
  full_product_name=$(sed -n 's/^ *FULL_PRODUCT_NAME = //p' <<<"$settings" | head -1)
  app="$built_products_dir/$full_product_name"
  if [[ -e "$app/Contents/MacOS/openramble-mcp" ]]; then
    fail "The dictation-only artifact unexpectedly contains openramble-mcp."
  fi
  [[ ! -e "$app/Contents/MacOS/openramble-asr-worker" ]] \
    || fail "The application still embeds the retired ASR worker."
  local framework="$app/Contents/Frameworks/CTranscribe.framework"
  [[ -d "$framework" ]] || fail "The inference runtime is missing from the application."
}

run_network_gate() {
  echo "→ Network Surface"
  ./scripts/check-network-surface.sh > /dev/null || fail "Network gate failed."
  green "the promise about the network stands"
  echo "→ Diagnostics Surface"
  ./scripts/check-diagnostics-surface.sh > /dev/null || fail "Diagnostics gate failed."
  green "diagnostics stay opt-in"
}

case "$MODE" in
  --fast) run_packages; run_shared_core; run_network_gate ;;
  --app)  run_app ;;
  all|*)  run_packages; run_shared_core; run_app; run_network_gate ;;
esac

green "
Everything is green."

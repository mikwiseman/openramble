#!/bin/bash
# The local gate for the shipping Rust/Tauri product.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-all}"
green() { printf '\033[32m%s\033[0m\n' "$1"; }
fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
PINNED_CARGO=$(rustup which --toolchain 1.97.1 cargo)
PINNED_RUSTC=$(rustup which --toolchain 1.97.1 rustc)
# Cargo discovers component subcommands such as cargo-clippy through PATH.
# Put the pinned toolchain first so a Homebrew component cannot silently lint
# with a different compiler than the Cargo binary above.
export PATH="$(dirname "$PINNED_CARGO"):$PATH"

run() {
  local label="$1"; shift
  local log
  log=$(mktemp -t openramble-check)
  if "$@" >"$log" 2>&1; then
    rm -f "$log"
    green "$label"
  else
    echo "$label failed:" >&2
    tail -60 "$log" >&2
    echo "Full output: $log" >&2
    exit 1
  fi
}

run_rust() {
  run "Rust formatting" "$PINNED_CARGO" fmt --all --check
  run "Rust lints" env RUSTC="$PINNED_RUSTC" "$PINNED_CARGO" clippy \
    --locked --workspace --all-targets --all-features -- -D warnings
  run "Rust tests" env RUSTC="$PINNED_RUSTC" "$PINNED_CARGO" test \
    --locked --workspace --all-targets --all-features
}

run_surfaces() {
  run "Network surface" ./scripts/check-network-surface.sh
  run "Diagnostics surface" ./scripts/check-diagnostics-surface.sh
  run "Design tokens" ./scripts/generate-tokens.py --check
}

case "$MODE" in
  --fast) run_rust; run_surfaces ;;
  --app)
    run "Tauri application tests" env RUSTC="$PINNED_RUSTC" "$PINNED_CARGO" test \
      --locked -p openramble-desktop --all-targets --all-features
    run_surfaces
    ;;
  all) run_rust; run_surfaces ;;
  *) fail "Usage: ./scripts/check.sh [--fast|--app]" ;;
esac

green "Everything is green."

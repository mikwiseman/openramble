#!/bin/bash
# Stable release entrypoint. The macOS product is now the universal Tauri app.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/build-tauri-dmg.sh "$@"

#!/bin/bash
# Cargo runner for Tauri: the CLI has no --locked option of its own.
set -euo pipefail
exec "${CARGO:?CARGO must name the pinned Cargo binary}" "$@" --locked

#!/bin/bash
# The Tauri release contains no per-take diagnostics or transcript logging mode.
set -euo pipefail
cd "$(dirname "$0")/.."

STATUS=0
if grep -rnE 'OPENRAMBLE_DIAGNOSTICS|OpenRambleDiagnostics' \
  apps/desktop/src-tauri/src apps/desktop/src-tauri/tauri.conf.json \
  apps/desktop/src-tauri/Info.plist >/dev/null 2>&1; then
  echo "The shipping Tauri source exposes a diagnostics build surface." >&2
  STATUS=1
fi

if [[ $# -ge 1 ]]; then
  PLIST="$1/Contents/Info.plist"
  [[ -f "$PLIST" ]] || { echo "No Info.plist in $1" >&2; exit 1; }
  MARKER=$(/usr/libexec/PlistBuddy -c 'Print :OpenRambleDiagnostics' "$PLIST" 2>/dev/null || true)
  if [[ -n "$MARKER" ]]; then
    echo "$1 carries a diagnostics marker and must not be released." >&2
    STATUS=1
  fi
fi

[[ $STATUS -eq 0 ]] && echo "→ diagnostics surface is release-safe"
exit "$STATUS"

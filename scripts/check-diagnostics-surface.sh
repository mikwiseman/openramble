#!/bin/bash
# A diagnostics build must never be distributed.
#
# Diagnostics are opt-in through OPENRAMBLE_DIAGNOSTICS=1, which compiles the
# per-take machine sampler into the app and stamps the marker into Info.plist.
# That build writes durable local records and is meant for one machine, so the
# release path has to be able to refuse it — on the artifact, not on the
# environment variable that happened to be set in some shell.
#
# Usage:
#   scripts/check-diagnostics-surface.sh                 # check the sources
#   scripts/check-diagnostics-surface.sh path/to/App.app # check an artifact
set -euo pipefail
cd "$(dirname "$0")/.."

STATUS=0

# 1. Source: the marker may only be reachable through the build setting.
#    A literal `#if OPENRAMBLE_DIAGNOSTICS` is expected and fine; a hard-coded
#    `true` for the switch is not.
if grep -rn "OPENRAMBLE_DIAGNOSTICS_CONDITION: \"OPENRAMBLE_DIAGNOSTICS\"" apps/macos/project.yml >/dev/null 2>&1; then
  echo "project.yml turns diagnostics on by default" >&2
  STATUS=1
fi

# 2. Every diagnostics entry point must stay compiled out by default. The
#    no-op shape is what keeps release builds from paying for, or emitting,
#    anything at all.
if ! grep -q "#if OPENRAMBLE_DIAGNOSTICS" apps/macos/OpenRamble/System/DictationDiagnostics.swift; then
  echo "DictationDiagnostics.swift is no longer guarded by the compile condition" >&2
  STATUS=1
fi

# 3. Artifact, when one is given: the stamped marker must be empty or absent.
if [[ $# -ge 1 ]]; then
  APP="$1"
  PLIST="$APP/Contents/Info.plist"
  if [[ ! -f "$PLIST" ]]; then
    echo "No Info.plist in $APP" >&2
    exit 1
  fi
  MARKER=$(/usr/libexec/PlistBuddy -c "Print :OpenRambleDiagnostics" "$PLIST" 2>/dev/null || true)
  if [[ -n "$MARKER" ]]; then
    echo "$APP is a diagnostics build (OpenRambleDiagnostics=$MARKER) and must not be released" >&2
    STATUS=1
  else
    echo "→ $APP carries no diagnostics marker"
  fi
fi

if [[ $STATUS -eq 0 ]]; then
  echo "→ diagnostics surface is release-safe"
fi
exit "$STATUS"

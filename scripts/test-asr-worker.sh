#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

HELPER="${1:?Pass the path to openramble-asr-worker}"
[[ -x "$HELPER" ]] || {
  echo "ASR worker is missing or is not executable: $HELPER" >&2
  exit 1
}

/usr/bin/python3 scripts/test-asr-worker.py "$HELPER"

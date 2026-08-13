#!/bin/bash
set -euo pipefail

HELPER="${1:?Pass the path to openramble-mcp}"
[[ -x "$HELPER" ]] || { echo "MCP helper is not executable: $HELPER" >&2; exit 1; }

exec python3 "$(dirname "$0")/test-mcp-helper.py" "$@"

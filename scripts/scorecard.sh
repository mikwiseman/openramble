#!/bin/bash
# One command, one scorecard: ./scripts/scorecard.sh <candidate>... [--suite NAME]...
#
# Candidates are research/scorecard/candidates/<name>.json. Several at once are
# interleaved in the speed suites, which is the only fair way to compare their
# latency on one Mac. Inputs and binaries live in $SCORECARD_ROOT
# (~/Library/Caches/OpenRambleScorecard); research/scorecard/README.md says how
# to set them up and what every number means.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -gt 0 ]] || { sed -n '2,8p' "$0"; exit 64; }
command -v uv > /dev/null || { echo "uv is required (it pins jiwer 4.0.0, the Oct 9 aligner)."; exit 69; }

scorecard() { uv run --quiet --with jiwer==4.0.0 python scripts/scorecard/scorecard.py "$@"; }

candidates=()
suites=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite) suites+=(--suite "$2"); shift 2 ;;
    *) candidates+=("$1"); shift ;;
  esac
done

scorecard prepare
scorecard run "${candidates[@]}" "${suites[@]+"${suites[@]}"}"
for candidate in "${candidates[@]}"; do
  scorecard score "$candidate"
done
scorecard html
echo "Scorecard: research/scorecard/index.html"

#!/bin/bash
# Generates the iPhone app's project, builds it and runs its tests in the iOS
# Simulator. Used by ./scripts/check.sh --ios and by CI.
#
#   ./scripts/test-ios.sh            picks an iPhone simulator that exists here
#   IOS_SIMULATOR=<udid> ./scripts/test-ios.sh
#
# The simulator is chosen, not named, because the device names that come with
# Xcode change every year and a check must not fail for that alone.
set -euo pipefail
cd "$(dirname "$0")/.."

destination=${IOS_SIMULATOR:-}
if [[ -z "$destination" ]]; then
  destination=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in devices if "iOS-" in r), key=lambda r: [int(p) for p in r.split("iOS-")[1].split("-")], reverse=True)
for runtime in runtimes:
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        preferred = [d for d in phones if d["name"].endswith("Pro")] or phones
        print(preferred[0]["udid"])
        break
')
fi
[[ -n "$destination" ]] || { echo "No iPhone simulator is installed; add one in Xcode → Settings → Components." >&2; exit 1; }

xcodegen=$(scripts/pinned-xcodegen.sh)
(cd apps/ios && "$xcodegen" generate > /dev/null)

log=$(mktemp)
trap 'rm -f "$log"' EXIT
if (cd apps/ios && xcodebuild -project OpenRambleiOS.xcodeproj -scheme OpenRamble \
      -destination "id=$destination" CODE_SIGNING_ALLOWED=NO test) > "$log" 2>&1; then
  grep -E "Executed [0-9]+ tests, with" "$log" | tail -1
else
  grep -E "error:|failed|Failing" "$log" | head -30
  echo "The iPhone app's build or tests failed; full log above the summary." >&2
  exit 1
fi

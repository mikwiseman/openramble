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

# Booted first, on its own, so a slow boot is told apart from a slow build.
echo "→ Booting the simulator $destination"
xcrun simctl boot "$destination" 2>/dev/null || true
xcrun simctl bootstatus "$destination" -b > /dev/null

# Progress is printed as it happens: a run that a time limit ends still says
# how far it got.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
for action in build-for-testing test-without-building; do
  echo "→ $action"
  if ! (cd apps/ios && xcodebuild -project OpenRambleiOS.xcodeproj -scheme OpenRamble \
        -destination "id=$destination" CODE_SIGNING_ALLOWED=NO "$action") 2>&1 \
      | tee "$log" \
      | grep --line-buffered -E "^(Resolve Package Graph|Fetching from|Test Suite '.*' (started|passed|failed)|Test Case '.*' failed|\*\* .* \*\*)|error:"; then
    :
  fi
  if ! grep -qE "\*\* (BUILD|TEST BUILD|TEST EXECUTE) SUCCEEDED \*\*|\*\* TEST SUCCEEDED \*\*" "$log"; then
    grep -E "error:|failed|Failing" "$log" | head -30
    echo "The iPhone app's $action failed." >&2
    exit 1
  fi
done
grep -E "Executed [0-9]+ tests, with" "$log" | tail -1

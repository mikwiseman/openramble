#!/bin/bash
# Tests the core promise of the product: the network is only used where
# this is declared to the user.
#
# Exactly two places are allowed:
# • ModelDownloading.swift — downloading a model using a button
# • Sparkle wrapper - checking for updates with user consent
#
# Everything else is a violation. The list of characters is wider than the obvious URLSession:
# You can download data from Foundation in a good dozen ways, and each of them
# would quietly turn “works on an airplane” into a lie.

set -euo pipefail
cd "$(dirname "$0")/.."

# Files that are allowed by the network.
ALLOWED='Packages/LocalASR/Sources/LocalASR/ModelDownloading.swift|SparkleUpdater.swift'

# We only check the shipping code. The tests intentionally create a URLSession, read
# local fixture files via Data(contentsOf:) and raise control-connect;
# consider these seams to be the network surface of the product - a false PASS/FAIL signal.
SHIPPING_PATHS=(Packages/DictationCore/Sources Packages/LocalASR/Sources apps/macos/OpenRamble)

# Symbols that can go online.
FORBIDDEN='URLSession|NWConnection|NWBrowser|CFNetwork|CFStream|WKWebView|NSNetService|NSURLConnection'
# Silent download methods: These initializers take a URL and silently go to the network.
FORBIDDEN+='|Data\(contentsOf:|String\(contentsOf:|NSAttributedString\(url:|NSImage\(contentsOf:|AVAsset\(url:'
# Sending speech to Apple servers is directly contrary to the purpose of the product.
FORBIDDEN+='|SFSpeechRecognizer'
# Synchronization between devices: data should not get here either.
FORBIDDEN+='|NSUbiquitousKeyValueStore|CKContainer|CKDatabase'
# Loading models past our manifest.
FORBIDDEN+='|MLModelCollection'

status=0

echo "Checking network symbols..."
while IFS= read -r hit; do
  file="${hit%%:*}"
  if [[ "$file" =~ $ALLOWED ]]; then
    continue
  fi
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "VIOLATION: network outside permitted locations."
    status=1
  fi
  echo "  $hit"
done < <(grep -rnE "$FORBIDDEN" "${SHIPPING_PATHS[@]}" 2>/dev/null \
  | grep -v '^Binary' \
  | grep -vE ':[0-9]+: *//' \
  | grep -vE 'URLSessionModelDownloader\(\)|: ModelDownloading' \
  || true)

# The clipboard is a different story. Naked clearContents() returns dictated
# text in Universal Clipboard, that is, on all Apple ID devices via iCloud.
# You can only write to the buffer using prepareForNewContents(with: .currentHostOnly).
#
# declareTypes(_:owner:) - the same thing in other words. This is the legacy way to start
# new entry: it also resets the buffer and also does not set limits
# current computer. Checking for one clearContents() would only catch
# modern spelling, but the promise to the user is not formulated about the name
# method.
FORBIDDEN_PASTEBOARD='clearContents\(\)|declareTypes\('
echo "Checking the clipboard entry..."
while IFS= read -r hit; do
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "VIOLATION: flushing buffer past .currentHostOnly takes away dictation"
    echo "to Universal Clipboard - to all Apple ID devices."
    echo "Use prepareForNewContents(with: .currentHostOnly)."
    status=1
  fi
  echo "  $hit"
  # Comments are excluded in the same way as in network symbol checking. Without this
  # the gate crashed on a line that itself explains why you can’t write it like that -
  # and a false positive here is more expensive than a pass: they start to bypass it, and
  # one day they will bypass the present.
done < <(grep -rnE "$FORBIDDEN_PASTEBOARD" "${SHIPPING_PATHS[@]}" 2>/dev/null \
  | grep -v '^Binary' \
  | grep -vE ':[0-9]+: *//' \
  || true)

# Updates must remain silent until enabled. This is not cosmetics:
# without SUEnableAutomaticChecks=false Sparkle will ask itself on the second launch
# permission and will enable checks by default - the application will go online without
# commands, and the promise on the main page will become untrue.
echo "Checking update settings..."
PROJECT_YML="apps/macos/project.yml"
declare -a REQUIRED_UPDATE_KEYS=(
  "SUEnableAutomaticChecks: false"
  "SUSendProfileInfo: false"
  "SUAllowsAutomaticUpdates: false"
)
for required in "${REQUIRED_UPDATE_KEYS[@]}"; do
  if grep -qF "$required" "$PROJECT_YML"; then
    continue
  fi
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "VIOLATION: Updates are not configured as promised to the user."
    status=1
  fi
  echo "$PROJECT_YML does not have the line '$required'"
done

# Logging the dictation text itself is something that the user definitely does not expect.
echo "Checking text logging..."
while IFS= read -r hit; do
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "VIOLATION: recognized text is included in the log."
    status=1
  fi
  echo "  $hit"
done < <(grep -rnE 'log(ger)?\.(info|debug|error|warning|notice)\(.*(transcript|dictatedText|recognizedText)' \
  "${SHIPPING_PATHS[@]}" 2>/dev/null || true)

if [[ $status -eq 0 ]]; then
  echo ""
  echo "Network surface is fine: model loading and updates (disabled by default), nothing else."
fi
exit $status

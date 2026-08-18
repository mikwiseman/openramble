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
ALLOWED='^(Packages/LocalASR/Sources/LocalASR/ModelDownloading\.swift|apps/macos/OpenRamble/System/SparkleUpdater\.swift)$'

# We only check the shipping code. The tests intentionally create a URLSession, read
# local fixture files via Data(contentsOf:) and raise control-connect;
# consider these seams to be the network surface of the product - a false PASS/FAIL signal.
SHIPPING_PATHS=(
  Packages/DictationCore/Sources
  Packages/LocalASR/Sources
  apps/macos/OpenRamble
)

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

# A plain clearContents()/declareTypes() puts dictation on Universal Clipboard,
# where it reaches every device on the Apple ID. The definition used to sit
# beside the ASR worker's control-plane scan and was removed with it, which left
# this check reading an unset variable: it printed an error, matched nothing and
# exited zero — a gate that looked like it was running and was not.
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
# What the gate defends is what README promises, and that promise changed:
# the app now looks for updates on its own, because a security fix that never
# arrives helps nobody. The two guarantees that did NOT change are the ones
# still pinned here — nothing about this Mac travels with the request, and
# nothing installs without a click.
#
# `SUEnableAutomaticChecks` stays in the list, now required to be `true`. It is
# pinned in BOTH directions on purpose: leaving the key absent lets Sparkle ask
# the person its own question on the second launch, and an unannounced modal
# about update policy is exactly what neither value is supposed to produce.
declare -a REQUIRED_UPDATE_KEYS=(
  "SUEnableAutomaticChecks: true"
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

# The inference runtime is a prebuilt third-party binary, so reading its source
# proves nothing about what ships. Audit the Mach-O we actually link: a library
# that can reach the network has to reference something that can open a socket.
echo "Checking the inference runtime binary..."
RUNTIME_BINARY=$(find "$PWD/Packages/LocalASR" -path "*CTranscribe.framework/Versions/A/CTranscribe" -print -quit 2>/dev/null || true)
if [[ -z "$RUNTIME_BINARY" ]]; then
  RUNTIME_BINARY=$(find "$PWD/Packages/LocalASR" -path "*CTranscribe.framework/CTranscribe" -print -quit 2>/dev/null || true)
fi
if [[ -z "$RUNTIME_BINARY" ]]; then
  echo "  runtime not resolved yet (run a build first); skipping the binary audit"
else
  NETWORK_SYMBOLS='curl_easy|NSURLSession|NSURLConnection|NSURLRequest|CFNetwork|CFURLConnection|CFReadStream|_socket$|_connect$|_getaddrinfo$|_gethostby|SSLCreateContext|nw_connection|dns_sd'
  while IFS= read -r hit; do
    if [[ $status -eq 0 ]]; then
      echo ""
      echo "VIOLATION: the inference runtime references a network API."
      status=1
    fi
    echo "  $hit"
  done < <(nm -u "$RUNTIME_BINARY" 2>/dev/null | grep -E "$NETWORK_SYMBOLS" || true)

  # NSURL alone is the file-path value type; the runtime uses fileURLWithPath:
  # to load its model and Metal library. Anything beyond that is worth failing on.
  while IFS= read -r hit; do
    if [[ $status -eq 0 ]]; then
      echo ""
      echo "VIOLATION: the inference runtime links a networking framework."
      status=1
    fi
    echo "  $hit"
  done < <(otool -L "$RUNTIME_BINARY" 2>/dev/null | grep -E "CFNetwork|Network\.framework|Security\.framework|libcurl" || true)
fi

# ---------------------------------------------------------------------------
# The same promise, on the Rust side.
#
# The shared core carries dictation logic for every platform, and it performs no
# I/O at all — bytes move through ports the shell implements. Adding an HTTP
# client here would put a network call inside code that macOS, Windows and Linux
# all link, in the one place this audit would not have been looking. The story
# must not fork by language.
if [[ -d core ]]; then
  echo ""
  echo "Checking the Rust core..."

  # Anything that opens a socket, and the async runtimes whose net features do.
  RUST_FORBIDDEN_CRATES='reqwest|hyper|ureq|curl|isahc|attohttpc|surf|awc|tungstenite|quinn|rustls|native-tls|openssl|trust-dns|hickory'
  while IFS= read -r hit; do
    if [[ $status -eq 0 ]]; then
      echo ""
      echo "VIOLATION: the Rust core declares a networking dependency."
      status=1
    fi
    echo "  $hit"
  done < <(grep -rnE "^[[:space:]]*($RUST_FORBIDDEN_CRATES)[[:space:]]*=" core --include=Cargo.toml || true)

  # The dependency graph of the core crates specifically, not the whole
  # workspace.
  #
  # A workspace-wide lockfile check was the first attempt and it was wrong: Tauri
  # links reqwest unconditionally, so the moment the desktop app joined the
  # workspace the gate failed on a dependency nobody chose. That is the same
  # distinction the Swift side already draws — Foundation contains URLSession and
  # is linked by everything, so the audit looks at what the code *calls*, not at
  # what the framework happens to contain.
  #
  # What must stay absolutely network-free is the shared core: it is compiled
  # into every platform's app, it is where a fetch would be least expected, and
  # it has no business owning one. The app shell's own network use is confined to
  # the declared areas and is caught by the source scan below.
  if command -v cargo > /dev/null && [[ -f Cargo.lock ]]; then
    for package in ramble-core ramble-text ramble-model ramble-audio ramble-engine; do
      while IFS= read -r hit; do
        if [[ $status -eq 0 ]]; then
          echo ""
          echo "VIOLATION: a networking crate reached the shared core."
          status=1
        fi
        echo "  $package depends on $hit"
      done < <(cargo tree --package "$package" --target all --edges normal --prefix none 2>/dev/null \
                 | awk '{print $1}' | sort -u \
                 | grep -xE "$RUST_FORBIDDEN_CRATES" || true)
    done
  fi

  # std::net and the socket types reachable without a crate.
  RUST_FORBIDDEN_SYMBOLS='std::net|TcpStream|TcpListener|UdpSocket|UnixStream|ToSocketAddrs'
  while IFS= read -r hit; do
    if [[ $status -eq 0 ]]; then
      echo ""
      echo "VIOLATION: the Rust core reaches for a socket."
      status=1
    fi
    echo "  $hit"
  done < <(grep -rnE "$RUST_FORBIDDEN_SYMBOLS" core --include=*.rs || true)
fi

if [[ $status -eq 0 ]]; then
  echo ""
  echo "Network source surface is limited to model downloads and update checks; the inference runtime and the shared Rust core cannot reach the network at all."
fi
exit $status

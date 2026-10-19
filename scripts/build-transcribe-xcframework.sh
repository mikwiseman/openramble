#!/bin/bash
# Build the inference runtime from source and audit it before anything links it.
#
#   ./scripts/build-transcribe-xcframework.sh <transcribe.cpp checkout> [output folder]
#
# The checkout must be clean, so the zip is a function of one commit. The macOS
# slice is built with transcribe.cpp's own release scripts (arm64 with Metal,
# x86_64 on the CPU, as upstream ships it), and then audited by the same
# network check that guards the upstream binary. The script prints the
# SwiftPM checksum for Packages/LocalASR/Package.swift; publishing the zip and
# changing the pin are separate, deliberate steps.
set -euo pipefail
cd "$(dirname "$0")/.."

source_dir=$(cd "${1:?usage: $0 <transcribe.cpp checkout> [output folder]}" && pwd)
output=${2:-$PWD/.build/transcribe-xcframework}

[[ -z "$(git -C "$source_dir" status --porcelain)" ]] \
  || { echo "The transcribe.cpp checkout has uncommitted changes; build from a commit."; exit 65; }
commit=$(git -C "$source_dir" rev-parse HEAD)
describe=$(git -C "$source_dir" describe --tags --always)

echo "→ Building CTranscribe for macOS from $describe ($commit)"
TRANSCRIBE_XCFRAMEWORK_SLICES=macos "$source_dir/scripts/ci/build_xcframework.sh" > "$output.log" 2>&1 \
  || { tail -30 "$output.log"; echo "Build failed; full log: $output.log"; exit 70; }
"$source_dir/scripts/ci/package_xcframework.sh" >> "$output.log" 2>&1

built="$source_dir/bindings/swift/build-apple"
binary="$built/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework/Versions/A/CTranscribe"
echo "→ Auditing the binary"
RUNTIME_BINARY="$binary" ./scripts/check-network-surface.sh > /dev/null \
  || { RUNTIME_BINARY="$binary" ./scripts/check-network-surface.sh | grep -A5 VIOLATION; exit 1; }

mkdir -p "$output"
cp "$built/TranscribeCpp.xcframework.zip" "$output/TranscribeCpp-$describe.xcframework.zip"
checksum=$(swift package compute-checksum "$output/TranscribeCpp-$describe.xcframework.zip")
cat <<RESULT
Audit passed.
zip:      $output/TranscribeCpp-$describe.xcframework.zip
commit:   $commit
checksum: $checksum
RESULT

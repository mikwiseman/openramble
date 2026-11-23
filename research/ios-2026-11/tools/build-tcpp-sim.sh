#!/bin/bash
# Builds transcribe.cpp (fork, commit dacdba09) for the iOS Simulator, arm64,
# CPU only (as upstream's own ios-sim slice), installs it, then builds the
# engine's ore-cli and tcpp-probe against it for the same target.
set -euo pipefail
cd "$(dirname "$0")"
SRC=$PWD/tcpp-src
B=$PWD/build/tcpp-sim
P=$PWD/build/tcpp-sim-prefix
cmake -B "$B" -S "$SRC" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DTRANSCRIBE_BUILD_SHARED=OFF -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
  -DTRANSCRIBE_BUILD_TOOLS=OFF -DTRANSCRIBE_INSTALL=ON -DTRANSCRIBE_USE_OPENMP=OFF \
  -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DTRANSCRIBE_METAL=OFF -DGGML_METAL=OFF \
  -DCMAKE_INSTALL_PREFIX="$P"
cmake --build "$B" --config Release --parallel 6
cmake --install "$B"
echo TCPP-DONE

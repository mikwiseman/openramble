#!/bin/bash
# Fails when the recognition runtime built for the Windows and Linux packages
# would only run on a computer like the one that built it.
#
# Three things are read from the build, not from the workflow that asked for
# them: that CMake was told not to tune for the build machine's processor, that
# the runtime links no BLAS library of the build machine, and that the compiled
# libraries name no AVX-512 register. The libraries are read before they are
# linked because they still carry only the runtime's own code there. The
# finished executable cannot be judged this way: the TLS library brings AVX-512
# routines that it calls only after asking the processor, and those are fine.
#
# Usage: check-desktop-portability.sh [cargo target directory]
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-target}"

OUT=$(find "$TARGET/release/build" -maxdepth 2 -type d -path '*/transcribe-cpp-sys-*/out' | head -1)
[[ -n "$OUT" ]] || { echo "No transcribe-cpp-sys build under $TARGET/release/build." >&2; exit 1; }

grep -q '^GGML_NATIVE:[A-Z]*=OFF' "$OUT/build/CMakeCache.txt" || {
  echo "The runtime was tuned for this build machine's processor (GGML_NATIVE is not OFF)." >&2
  exit 1
}

# What the runtime tells its users to link, written by its own install step.
MANIFEST=$(find "$OUT" -path "$OUT/build" -prune -o -type f -name transcribe-link.json -print | head -1)
[[ -n "$MANIFEST" ]] || { echo "No transcribe-link.json under $OUT." >&2; exit 1; }
if grep -qi 'blas' "$MANIFEST"; then
  echo "The runtime links this build machine's BLAS library, which the packages do not carry." >&2
  exit 1
fi

LIBRARIES=()
while IFS= read -r library; do LIBRARIES+=("$library"); done < <(
  find "$OUT" -path "$OUT/build" -prune -o -type f \( -name '*.a' -o -name '*.lib' \) -print | sort)
[[ ${#LIBRARIES[@]} -gt 0 ]] || { echo "No runtime libraries under $OUT." >&2; exit 1; }

WIDE=0
AVX2=0
for library in "${LIBRARIES[@]}"; do
  counts=$(objdump -d --no-show-raw-insn "$library" | awk '
    /^ *[0-9a-f]+:/ { total++ }
    /%zmm/          { wide++ }
    /%k[0-7]/       { mask++ }
    /%ymm/          { avx2++ }
    END { printf "%d %d %d %d", total, wide, mask, avx2 }')
  read -r total wide mask avx2 <<< "$counts"
  echo "${library#"$OUT"/}: $total instructions, $wide on AVX-512 registers, $mask on mask registers, $avx2 on 256-bit registers"
  WIDE=$((WIDE + wide + mask))
  AVX2=$((AVX2 + avx2))
done

[[ "$WIDE" -eq 0 ]] || { echo "The runtime contains instructions that need AVX-512." >&2; exit 1; }
# Also the proof that the disassembler read the code at all, and that the
# build did not fall to the slow baseline with AVX2 switched off.
[[ "$AVX2" -gt 0 ]] || { echo "The runtime contains no AVX2 instructions." >&2; exit 1; }
echo "The runtime uses AVX2, no AVX-512, and no BLAS library of this machine."

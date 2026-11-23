#!/bin/bash
# Fails when the recognition engine built for the Windows and Linux packages
# would only run on a computer like the one that built it.
#
# The engine carries its own kernels for AVX2 and AVX-512 and for processors
# that have neither, and picks one set when a model is opened. That is only
# safe if everything outside the kernel files is compiled for the first
# x86-64 processors, so this reads what was compiled, file by file: the two
# kernel files may use newer instructions, nothing else may. 0.37.0 for Linux
# is why the build is read and not trusted: its runtime was tuned for the
# build machine and needed AVX-512.
#
# Usage: check-desktop-portability.sh [cargo target directory]
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-target}"

OUT=$(find "$TARGET/release/build" -maxdepth 2 -type d -path '*/ramble-engine-*/out' | head -1)
[[ -n "$OUT" ]] || { echo "No ramble-engine build under $TARGET/release/build." >&2; exit 1; }

OBJECTS=()
while IFS= read -r object; do OBJECTS+=("$object"); done < <(
  find "$OUT" -maxdepth 1 -type f \( -name '*-ore*.o' -o -name '*-ore*.obj' \) | sort)
[[ ${#OBJECTS[@]} -ge 13 ]] || { echo "Expected the engine's 13 compiled files under $OUT, found ${#OBJECTS[@]}." >&2; exit 1; }

# Instructions the first x86-64 processors lack and that carry no AVX prefix:
# SSSE3, SSE4 and the bit-manipulation sets. Every AVX and AVX-512 mnemonic
# starts with "v", and nothing older does in compiled code.
#
# One exception is known and checked for. The Windows compiler writes some
# loops twice, once with SSE4 instructions, and picks between them while the
# program runs by reading __isa_available, which its runtime library sets
# from the processor. A file that refers to that variable may hold them.
NEWER='^(pshufb|palignr|pabs[bwd]|pmaddubsw|phadd[wd]|phaddsw|phsub[wd]|phsubsw|psign[bwd]|pmulhrsw|pmulld|pmuldq|pblendw|pblendvb|blendvp[sd]|blendp[sd]|ptest|pextr[bdq]|pinsr[bdq]|extractps|insertps|pmovzx[a-z]+|pmovsx[a-z]+|pminu[wd]|pmaxu[wd]|pmins[bd]|pmaxs[bd]|round[ps][sd]|dpp[sd]|mpsadbw|packusdw|pcmpeqq|pcmpgtq|popcnt[wlq]?|crc32[bwlq]?|lzcnt[wlq]?|andn[lq]?|bextr[lq]?|bzhi[lq]?|pdep[lq]?|pext[lq]?|mulx[lq]?|sarx[lq]?|shlx[lq]?|shrx[lq]?|rorx[lq]?|movbe[wlq]?)$'

status=0
AVX=0
WIDE=0
for object in "${OBJECTS[@]}"; do
  name=$(basename "$object")
  counts=$(objdump -d --no-show-raw-insn "$object" | awk -v newer="$NEWER" '
    /^ *[0-9a-f]+:/ {
      total++
      if ($2 ~ /^v/)      avx++
      if ($2 ~ newer)     later++
      if ($0 ~ /zmm/)     wide++
    }
    END { printf "%d %d %d %d", total, avx, later, wide }')
  read -r total avx later wide <<< "$counts"
  echo "$name: $total instructions, $avx with an AVX prefix ($wide on 512-bit registers), $later from SSSE3, SSE4 or the bit sets"
  case "$name" in
    *ore_kernels_neon.*)
      # The Arm kernels: an empty file on this processor family.
      continue
      ;;
  esac
  [[ "$total" -gt 0 ]] || { echo "  The disassembler read nothing from $name." >&2; status=1; }
  case "$name" in
    *ore_kernels_avx2.*)
      AVX=$((AVX + avx))
      WIDE=$((WIDE + wide))
      ;;
    *ore_kernels_sse.*)
      [[ "$avx" -eq 0 ]] || { echo "  The SSE kernels contain AVX instructions." >&2; status=1; }
      ;;
    *)
      guarded=$(objdump -t "$object" 2> /dev/null | grep -c '__isa_available' || true)
      if [[ "$avx" -ne 0 || ( "$later" -ne 0 && "$guarded" -eq 0 ) ]]; then
        echo "  $name runs before any kernel is chosen and needs a newer processor than the first x86-64 ones:" >&2
        objdump -d --no-show-raw-insn "$object" | awk -v newer="$NEWER" \
          '/^ *[0-9a-f]+:/ && ($2 ~ /^v/ || $2 ~ newer) { print "   " $0 }' | head -5 >&2
        status=1
      elif [[ "$later" -ne 0 ]]; then
        echo "  ($name asks the processor before it uses those: __isa_available)"
      fi
      ;;
  esac
done

# Also the proof that the disassembler read the code at all, and that the
# fast kernels were compiled in.
[[ "$AVX" -gt 0 ]] || { echo "The engine contains no AVX2 kernels." >&2; status=1; }
[[ "$WIDE" -gt 0 ]] || { echo "The engine contains no AVX-512 kernels." >&2; status=1; }
[[ "$status" -eq 0 ]] || exit 1
echo "Only the kernel files use instructions newer than the first x86-64 processors."

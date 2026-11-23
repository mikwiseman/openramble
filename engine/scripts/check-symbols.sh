#!/bin/bash
# Checks what the built engine can ask of the system.
#
# The engine reads one model file and computes. It has no business opening a
# socket, loading code, starting a process, or reading the environment, and a
# source-level promise is only as good as the next edit. So this lists every
# symbol the static library leaves for the system to supply and fails on any
# that is not on the short list below: memory, strings, math, one file mapped
# read-only, a clock, threads, and the compiler's own helpers (stack checks,
# and on Linux arm64 the atomic operations GCC keeps out of line).
#
#   check-symbols.sh path/to/libore.a
set -euo pipefail

lib="${1:?usage: check-symbols.sh path/to/libore.a}"

# Names as nm prints them, with the leading underscore macOS adds removed.
allowed='^(
ore_[a-z0-9_]+
|malloc|calloc|realloc|free|posix_memalign|aligned_alloc
|mem(cpy|move|set|cmp)|memset_pattern16|bzero|__bzero|str(len|cmp)|strtod|__isoc23_strtod|qsort
|__(mem(cpy|move|set)|snprintf|vsnprintf)_chk|snprintf
|open|open64|close|fstat|fstat64|fstat\$INODE64|__fstat|__fxstat|__fxstat64|mmap|mmap64|munmap
|clock_gettime|sysconf|getauxval
|pthread_(create|join|mutex_(init|destroy|lock|unlock)|cond_(init|destroy|wait|broadcast)|set_qos_class_self_np)
|(sin|cos|exp|log|tanh|sqrt|fma|fabs|floor|ceil|nearbyint)f?|llround|lround|__sincosf?_stret|sincosf?
|__stack_chk_(fail|guard)|___chkstk_darwin|__chkstk_darwin|_GLOBAL_OFFSET_TABLE_
|__aarch64_(cas|swp|ldadd|ldset|ldclr|ldeor)[0-9]+_(relax|acq|rel|acq_rel|sync)|__aarch64_have_lse_atomics
)$'
allowed="$(printf '%s' "$allowed" | tr -d '\n')"

status=0
while IFS= read -r sym; do
  name="${sym#_}"
  if ! [[ "$name" =~ $allowed || "$sym" =~ $allowed ]]; then
    echo "not allowed: $sym"
    status=1
  fi
done < <(nm -u "$lib" 2>/dev/null | awk 'NF == 2 && $1 == "U" { print $2 } NF == 1 && $1 !~ /:$/ { print $1 }' | sed 's/@.*//' | sort -u)

if [ "$status" -eq 0 ]; then
  echo "ok: $(basename "$lib") needs only memory, math, one mapped file, a clock and threads"
fi
exit "$status"

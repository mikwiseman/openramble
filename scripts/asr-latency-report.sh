#!/bin/bash
# What the recognition tail actually looks like, from the app's own logs.
#
# Exists because the stall fixed in 0.14.0 was found this way and can only be
# confirmed this way. The reasoning behind the fix is plausible; plausible is
# not the same as true, and the only thing that settles it is whether the tail
# of `recognize − engine` collapses on a build that has it.
#
# `recognize` is the whole interval from the microphone stopping to the text
# being ready. `engine` is the inference call inside it. The difference is
# everything that is not recognition — and before 0.14.0 that difference held
# 100% of the excess: p90 0.19 s, p99 6.36 s, worst 13.74 s, while the engine
# itself never once passed 1.07 s.
#
#   ./scripts/asr-latency-report.sh          # last 24 hours
#   ./scripts/asr-latency-report.sh 8h       # any `log show --last` duration

set -euo pipefail
WINDOW="${1:-24h}"

# Which build is installed. The log does not stamp a version on each take, so
# a window that spans an upgrade mixes them — and a verdict drawn from mixed
# data would blame or credit the wrong build. This is printed rather than
# guessed at, and the verdict below refuses to conclude anything on its own.
INSTALLED=$(/usr/bin/defaults read /Applications/OpenRamble.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "not installed")
echo "installed version    $INSTALLED"

# The absolute path on purpose: zsh ships a `log` builtin that shadows this.
/usr/bin/log show --last "$WINDOW" --predicate 'process == "OpenRamble"' --info 2>/dev/null \
  | grep -F 'dictation stop→text' \
  | sed -E -e 's/.*stop→text ([0-9.-]+)s.*recognize ([0-9.-]+)s queued ([0-9.-]+)s engine ([0-9.-]+)s.*/\1 \2 \4 \3/' \
          -e 't' \
          -e 's/.*stop→text ([0-9.-]+)s.*recognize ([0-9.-]+)s engine ([0-9.-]+)s.*/\1 \2 \3 -1/' \
  | awk -v window="$WINDOW" '
      NF == 4 && $3 >= 0 {
        gap = $2 - $3
        if (gap < 0) gap = 0
        gaps[n++] = gap
        if ($4 >= 0) { queued[q++] = $4; if ($4 > worstQueued) worstQueued = $4 }
        if ($3 > worstEngine) worstEngine = $3
        total += gap
      }
      END {
        if (n == 0) {
          print "No completed dictations in the last " window "."
          print "Dictate a few times, then run this again."
          exit 0
        }
        # Insertion sort: n is in the hundreds, and a dependency-free script
        # survives longer than a clever one.
        for (i = 1; i < n; i++) {
          v = gaps[i]
          for (j = i - 1; j >= 0 && gaps[j] > v; j--) gaps[j+1] = gaps[j]
          gaps[j+1] = v
        }
        p(50); p(90); p99 = gaps[int(n * 0.99)]
        printf "dictations           %d (last %s)\n", n, window
        printf "gap p50              %.2fs\n", gaps[int(n * 0.50)]
        printf "gap p90              %.2fs\n", gaps[int(n * 0.90)]
        printf "gap p99              %.2fs\n", p99
        printf "gap worst            %.2fs\n", gaps[n-1]
        printf "engine worst         %.2fs\n", worstEngine
        if (q > 0)
          printf "queued worst         %.2fs   (waiting before the engine started)\n", worstQueued
        else
          print  "queued               not recorded — build predates 0.17"
        printf "over 1s              %d\n", over
        print  ""
        print  "Before 0.14.0, for comparison:"
        print  "  gap p90 0.19s · p99 6.36s · worst 13.74s · engine worst 1.07s"
        print  ""
        print  "This window may span more than one build — the log does not stamp"
        print  "a version on each take. Judge the fix only on a window that begins"
        print  "after upgrading, e.g. run this with a duration shorter than the"
        print  "time since you updated."
        print  ""
        if (gaps[n-1] > 2.0)
          printf "A stall of %.2fs is present in this window.\n", gaps[n-1]
        else
          print "No stall over 2s in this window."
      }
      function p(x) { for (k = 0; k < n; k++) if (gaps[k] > 1.0) { over = n - k; return } }
    '

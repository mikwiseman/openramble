#!/bin/bash
# Where a dictation's time actually goes, stage by stage.
#
# `asr-latency-report.sh` answers "is it slow?". This answers "slow *where*",
# which is the question you need before optimising anything. It reads the same
# per-dictation line and profiles every stage: median, the tail, the worst, and
# what share of the total each one holds.
#
# The share column is the one to read. A stage with a frightening worst case
# but a tiny share is a rare event; a stage holding a third of every dictation
# is where the time is, whether or not it ever looks dramatic.
#
#   ./scripts/asr-profile.sh          # last 24 hours
#   ./scripts/asr-profile.sh 2h
#
# Requires a build of 0.19.2 or newer for the full breakdown. Older lines are
# read too, and the stages they predate are reported as missing rather than
# silently counted as zero — a stage that reads 0.00 because nobody measured it
# is exactly how the decode bug hid for months.

set -euo pipefail
WINDOW="${1:-24h}"

INSTALLED=$(/usr/bin/defaults read /Applications/OpenRamble.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "not installed")
echo "installed version    $INSTALLED"
echo "window               last $WINDOW"
echo

# Absolute path: zsh ships a `log` builtin that shadows this one.
/usr/bin/log show --last "$WINDOW" --predicate 'process == "OpenRamble"' --info 2>/dev/null \
  | grep -F 'dictation stop→text' \
  | sed -E 's/[a-z→]+ ([0-9.-]+)s/\1 /g; s/.*dictation //' \
  | awk '
      # stop→text stop→paste freeze prepare recognize [decode] [queued] engine audio
      NF >= 7 {
        total = $1; freeze = $3; prepare = $4; recognize = $5
        if (NF >= 10)     { readable = $6; decode = $7; queued = $8; engine = $9; audio = $10 }
        else if (NF == 9) { readable = -1; decode = $6; queued = $7; engine = $8; audio = $9 }
        else if (NF == 8) { readable = -1; decode = -1; queued = $6; engine = $7; audio = $8 }
        else              { readable = -1; decode = -1; queued = -1; engine = $6; audio = $7 }
        add("total", total); add("freeze", freeze); add("prepare", prepare)
        add("readable", readable)
        add("decode", decode); add("queued", queued); add("engine", engine)
        # Whatever no stage claimed. A large "unaccounted" means the breakdown
        # is still incomplete and there is another stage worth naming.
        rest = recognize
        if (readable >= 0) rest -= readable
        if (decode >= 0) rest -= decode
        if (queued >= 0) rest -= queued
        if (engine >= 0) rest -= engine
        add("unaccounted", rest < 0 ? 0 : rest)
        if (audio > 0 && engine > 0) add("rtf", audio / engine)
        takes++
      }
      function add(name, value) {
        if (value < 0) { missing[name] = 1; return }
        key = name SUBSEP (++count[name])
        v[key] = value
        sum[name] += value
      }
      function pct(name, q,   i, j, tmp, n, x) {
        n = count[name]
        for (i = 1; i <= n; i++) tmp[i] = v[name SUBSEP i]
        for (i = 2; i <= n; i++) { x = tmp[i]; for (j = i-1; j >= 1 && tmp[j] > x; j--) tmp[j+1] = tmp[j]; tmp[j+1] = x }
        i = int(n * q); if (i < 1) i = 1; if (i > n) i = n
        return tmp[i]
      }
      function row(name, label,   share) {
        if (missing[name] && count[name] == 0) {
          printf "  %-13s  %s\n", label, "not recorded by this build"
          return
        }
        share = sum["total"] > 0 ? 100 * sum[name] / sum["total"] : 0
        printf "  %-13s  %6.2f  %6.2f  %6.2f   %5.1f%%\n",
          label, pct(name, 0.50), pct(name, 0.90), pct(name, 1.00), share
      }
      END {
        if (takes == 0) { print "No dictations in this window. Dictate a few times and run it again."; exit 0 }
        printf "%d dictations\n\n", takes
        printf "  %-13s  %6s  %6s  %6s   %6s\n", "stage", "p50", "p90", "worst", "share"
        printf "  %-13s  %6s  %6s  %6s   %6s\n", "-------------", "------", "------", "------", "------"
        row("freeze",      "freeze")
        row("prepare",     "prepare")
        row("readable",    "readable")
        row("decode",      "decode")
        row("queued",      "queued")
        row("engine",      "engine")
        row("unaccounted", "unaccounted")
        printf "  %-13s  %6.2f  %6.2f  %6.2f   %5.1f%%\n", "TOTAL",
          pct("total", 0.50), pct("total", 0.90), pct("total", 1.00), 100
        print ""
        if (count["rtf"] > 0)
          printf "  engine speed   %.0fx real time at the median, %.0fx at its slowest\n",
            pct("rtf", 0.50), pct("rtf", 0.01)
        print ""
        print "  Read the share column first: it says where the time lives."
        print "  A stage with a big worst case but a small share is a rare event."
        if (sum["unaccounted"] > 0.05 * sum["total"])
          print "  UNACCOUNTED is large — some of the path is still unnamed, and that"
          print "  is where the next investigation starts."
      }
    '

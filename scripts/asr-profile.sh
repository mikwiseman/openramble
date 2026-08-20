#!/bin/bash
# Where a dictation's time goes, stage by stage.
#
# Parses by NAME, not by position. The previous version split on whitespace and
# assigned fields by counting them; the moment a non-numeric field joined the
# log line it read the word "path" as a duration and reported garbage without
# complaining once. A parser that cannot tell a word from a number will
# eventually be believed about the wrong thing, and that has already cost this
# investigation four rounds.
#
# A missing field is reported missing, never as zero. Zero is a measurement,
# and a stage nobody measured reading 0.00 is exactly how the real cause stayed
# hidden through three releases.
#
#   ./scripts/asr-profile.sh          # last 24 hours
#   ./scripts/asr-profile.sh 2h

set -euo pipefail
WINDOW="${1:-24h}"

INSTALLED=$(/usr/bin/defaults read /Applications/OpenRamble.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo "not installed")
echo "installed version    $INSTALLED"
echo "window               last $WINDOW"
echo

# Absolute path: zsh ships a `log` builtin that shadows this one.
/usr/bin/log show --last "$WINDOW" --predicate 'process == "OpenRamble"' --info 2>/dev/null \
  | grep -F 'dictation total=' \
  | awk '
      {
        delete f
        # Every key=value on the line, in any order and any number. A new field
        # needs no change here, which is the point.
        for (i = 1; i <= NF; i++) {
          if (split($i, kv, "=") == 2) {
            val = kv[2]; sub(/s$/, "", val)
            f[kv[1]] = val
          }
        }
        if (!("total" in f)) next
        takes++
        paths[("path" in f) ? f["path"] : "unrecorded"]++
        add("total", ("total" in f) ? f["total"] : "")
        stage("freeze", f); stage("prepare", f); stage("readable", f)
        stage("decode", f); stage("handover", f); stage("transport", f); stage("queued", f); stage("engine", f)

        # What no stage claimed, per take rather than in aggregate, so one bad
        # take cannot be averaged into looking fine.
        rest = ("recognize" in f) ? f["recognize"] + 0 : 0
        for (s in named) if ((s in f) && f[s] + 0 >= 0) rest -= f[s] + 0
        if (rest > 0.05) unexplained++
        if (rest > worstRest) { worstRest = rest; worstRestTotal = f["total"] + 0 }
      }
      function stage(name, f) { named[name] = 1; add(name, (name in f) ? f[name] : "") }
      function add(name, value) {
        if (value == "" || value + 0 < 0) { absent[name]++; return }
        key = name SUBSEP (++count[name])
        v[key] = value + 0
        sum[name] += value + 0
      }
      function pct(name, q,   i, j, tmp, n, x) {
        n = count[name]
        for (i = 1; i <= n; i++) tmp[i] = v[name SUBSEP i]
        for (i = 2; i <= n; i++) { x = tmp[i]; for (j = i-1; j >= 1 && tmp[j] > x; j--) tmp[j+1] = tmp[j]; tmp[j+1] = x }
        i = int(n * q); if (i < 1) i = 1; if (i > n) i = n
        return tmp[i]
      }
      function row(name,   share, spread, note) {
        if (count[name] == 0) {
          printf "  %-11s  %s\n", name, "never recorded in this window"
          return
        }
        share = sum["total"] > 0 ? 100 * sum[name] / sum["total"] : 0
        spread = pct(name, 1.00) - pct(name, 0.01)
        note = (absent[name] ? "(" absent[name] " absent) " : "")
        if (spread == 0 && count[name] > 5) note = note "identical on every take — suspect it is not measured"
        printf "  %-11s  %6.2f  %6.2f  %6.2f   %5.1f%%  %s\n",
          name, pct(name, 0.50), pct(name, 0.90), pct(name, 1.00), share, note
      }
      END {
        if (takes == 0) {
          print "No dictations in this window."
          print "If you were dictating, this build predates the named-field log line."
          exit 0
        }
        printf "%d dictations", takes
        sep = "   paths: "
        for (p in paths) { printf "%s%s=%d", sep, p, paths[p]; sep = ", " }
        print ""
        print ""
        printf "  %-11s  %6s  %6s  %6s   %6s\n", "stage", "p50", "p90", "worst", "share"
        printf "  %-11s  %6s  %6s  %6s   %6s\n", "-----------", "------", "------", "------", "------"
        row("freeze"); row("prepare"); row("readable"); row("decode")
        row("handover"); row("transport"); row("queued"); row("engine")
        printf "  %-11s  %6.2f  %6.2f  %6.2f   %5.1f%%\n", "TOTAL",
          pct("total", 0.50), pct("total", 0.90), pct("total", 1.00), 100
        print ""
        if (unexplained > 0) {
          printf "  %d of %d takes hold time no stage accounts for; worst %.2fs on a %.2fs take.\n",
            unexplained, takes, worstRest, worstRestTotal
          print  "  The breakdown is incomplete, and that remainder is where to look next."
        } else {
          print "  Every take is fully accounted for by its stages."
        }
      }
    '

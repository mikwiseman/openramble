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
        frames[("frame" in f) ? f["frame"] : "unrecorded"]++
        add("total", ("total" in f) ? f["total"] : "")
        addField("freeze", f); addField("prepare", f); addField("recognize", f)
        addField("readable", f); addField("decode", f); addField("handover", f)
        addField("transport", f); addField("poolreturn", f); addField("mainreturn", f)
        addField("enginedispatch", f)
        addField("queued", f); addField("engine", f)

        # Three containment checks, not one sum. `transport` contains handover,
        # readable, queued and both return spans; decode is itself inside queued.
        # Adding every printed row would double-subtract nested intervals and
        # turn missing time negative — the old parser did exactly that.
        if (present("total", f) && present("freeze", f) && present("recognize", f)) {
          top = f["total"] - f["freeze"] - value("prepare", f) - f["recognize"]
          add("topgap", top > 0 ? top : 0)
        }
        if (present("recognize", f) && present("transport", f) && present("engine", f)) {
          inside = f["recognize"] - f["transport"] - f["engine"]
          add("insidegap", inside > 0 ? inside : 0)
        }
        if (present("transport", f) && present("handover", f) && present("queued", f) \
            && present("poolreturn", f) && present("mainreturn", f) \
            && present("enginedispatch", f)) {
          missing = f["transport"] - value("handover", f) - value("readable", f) \
            - value("queued", f) - value("poolreturn", f) - value("mainreturn", f) \
            - value("enginedispatch", f)
          add("missing", missing > 0 ? missing : 0)
        } else if (present("transport", f)) {
          invalidTransport++
        }
      }
      function present(name, f) { return (name in f) && f[name] != "absent" && f[name] + 0 >= 0 }
      function value(name, f) { return present(name, f) ? f[name] + 0 : 0 }
      function addField(name, f) { add(name, present(name, f) ? f[name] : "") }
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
        sep = "   frames: "
        for (p in frames) { printf "%s%s=%d", sep, p, frames[p]; sep = ", " }
        print ""
        print ""
        printf "  %-11s  %6s  %6s  %6s   %6s\n", "stage", "p50", "p90", "worst", "share"
        printf "  %-11s  %6s  %6s  %6s   %6s\n", "-----------", "------", "------", "------", "------"
        row("freeze"); row("prepare"); row("readable"); row("decode")
        row("handover"); row("transport"); row("poolreturn"); row("mainreturn")
        row("enginedispatch")
        row("queued"); row("engine")
        printf "  %-11s  %6.2f  %6.2f  %6.2f   %5.1f%%\n", "TOTAL",
          pct("total", 0.50), pct("total", 0.90), pct("total", 1.00), 100
        print ""
        printf "  containment gaps (worst): total %.2fs, recognition %.2fs, transport %.2fs\n",
          pct("topgap", 1.00), pct("insidegap", 1.00), pct("missing", 1.00)
        if (invalidTransport > 0 || pct("topgap", 1.00) > 0.05 \
            || pct("insidegap", 1.00) > 0.05 || pct("missing", 1.00) > 0.05) {
          print "  The breakdown is incomplete; do not choose a fix from this window."
        } else {
          print "  Every take is accounted for without double-counting nested spans."
        }
      }
    '

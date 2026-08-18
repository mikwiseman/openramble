# Diagnostics build

A diagnostics build is an ordinary build of OpenRamble that also writes one
durable record per dictation, describing where the time went and what the
machine was doing around it. It is meant for one person's own machine while a
latency question is open, and it is never distributed.

## Why it exists

Two blind spots made a real report ("sometimes a take takes ten seconds") not
diagnosable from the shipping signal:

1. **The system log rotates too fast.** `info`-level entries on a busy Mac are
   gone within hours, so a rare slow take is unreadable by the time anyone
   looks. The shipping `stop→text` line is now `notice` and carries the stage
   breakdown, which helps — but a durable file that never rotates helps more.
2. **A total cannot name a cause.** "Stop → text = 10 s" is the same number
   whether the model had to be loaded, the model was loaded but its pages had
   been reclaimed, the accelerator was busy with another process, or
   recognition was genuinely slow. Those are four different bugs.

So the record separates the stages, and samples the memory subsystem on both
sides of the take. If a resident engine was faulted back in, `workerPageins`
and `decompressions` rise across a take that never went near a model load. If
they stay flat while `enginePreparation` carries the seconds, the model was
simply not resident. If every stage is small and `stopToText` is not, the cost
is somewhere the stages do not cover yet, and that is worth knowing too.

## Building one

```bash
OPENRAMBLE_DIAGNOSTICS=1 ALLOW_DIRTY_BETA=1 ./scripts/build-installable-beta.sh
```

Same bundle identifier, same Developer ID, same designated requirement as a
release build — deliberately, so the existing Accessibility grant survives and
the instrumented app *is* the daily driver rather than a lookalike that never
sees the failure.

## Where the records go

`~/Library/Application Support/OpenRamble/Diagnostics/dictation-YYYY-MM-DD.jsonl`,
one JSON object per line. Nothing is ever uploaded; nothing is deleted
automatically.

Each record carries durations (`captureFreeze`, `enginePreparation`,
`recognition`, `engineProcessing`, `stopToText`, `stopToPaste`), the take's
audio duration, whether the engine was ready when the person stopped speaking,
the memory-pressure tier, the unload policy in force, and a `machineAtStop` /
`machineAtText` pair with the delta between them.

`recognition` minus `engineProcessing` is everything the recognition round trip
cost that was not recognition: transport, scheduling, and page faults.

### Privacy

The rules do not relax for diagnostics. No dictated text, no words, no audio,
no user file names are recorded — only durations, counters, and a character
count. A diagnostics build makes no network request that a release build does
not; the file is local and stays local.

## Why it cannot be released

`OPENRAMBLE_DIAGNOSTICS` is a build setting that defaults to empty, so every
entry point compiles down to nothing in an ordinary build. A diagnostics build
also stamps `OpenRambleDiagnostics` into `Info.plist`, which makes the switch
verifiable on the artifact instead of on the shell that produced it:

- `scripts/check-diagnostics-surface.sh` fails if the source turns diagnostics
  on by default or if the guard is removed, and refuses an `.app` carrying the
  marker;
- `scripts/smoke-installed-artifact.sh` refuses a marked artifact, so
  `scripts/release.sh` cannot ship one even by accident;
- `scripts/check.sh` runs the source half of the gate on every check.

## Reading the records

```bash
DIR=~/Library/Application\ Support/OpenRamble/Diagnostics

# The slowest takes first, with the stage that owned each one.
cat "$DIR"/*.jsonl | python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin]
rows.sort(key=lambda r: -r["stopToTextSeconds"])
for r in rows[:20]:
    print(f"{r[\"timestamp\"]}  total={r[\"stopToTextSeconds\"]:.2f}s"
          f"  freeze={r.get(\"captureFreezeSeconds\") or 0:.2f}"
          f"  prepare={r.get(\"enginePreparationSeconds\") or 0:.2f}"
          f"  recognize={r.get(\"recognitionSeconds\") or 0:.2f}"
          f"  engine={r.get(\"engineProcessingSeconds\") or 0:.2f}"
          f"  audio={r.get(\"audioSeconds\") or 0:.1f}"
          f"  ready={r[\"engineWasReady\"]}"
          f"  workerPageins={r[\"delta\"][\"workerPageins\"]}")
'
```

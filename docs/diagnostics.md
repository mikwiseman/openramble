# Support reports

The shipping app has one export button: **Settings → About → Save Error Report…**.
It creates a ZIP locally and reveals it in Finder. The user shares it manually.
There is no reporting service, custom crash handler, upload or post-crash prompt.

`SupportLogs/events-YYYY-MM-DD.jsonl` is an allowlisted event journal, enabled by
default, bounded to seven UTC dates and 5 MB total. Turning the existing switch
off clears it. Writes run on a utility queue and close after each event. A process
crash preserves completed appends; power loss or an immediate crash before a
queued append reaches disk may lose the latest event. Export skips partial lines.
No free-text logging API is exposed.

Completed dictations include numeric audio/engine/file-read timings, the count
of pre-recognized segments and whether PCM came from the WAV. Recognition
failures record an allowlisted category and the native runtime status when
available, never the error description. Reports from 0.31.0 contain only the
overall completion time and a generic failure event, so they cannot identify
the cause of every failed recognition.

From 0.31.2, `dictationStageFailed` includes an allowlisted stage (capture freeze,
readable WAV, model preparation, or recognition), elapsed milliseconds, and a
timeout flag. `recognitionFallback` distinguishes a take with no completed
segments from a failed segment, retaining a native numeric status when present.
Successful recovery does not erase that fallback event. Completed dictations
also include capture-freeze, WAV-readiness and model-preparation durations.
These durations can overlap background work and must not be summed as a total.

The ZIP contains `system.json`, `events.jsonl`, `README.txt`, and at most five
redacted Apple `.ips` crash reports (each source limited to 5 MB, last seven days).
Only reports with OpenRamble's bundle identifier and process name are accepted;
the bundled CLI is also identified by its fixed code-signing identifier.
The collector checks the user's and system DiagnosticReports folders, including
Retired. Inaccessible, malformed or unsupported reports are counted, never copied
raw. Native stack frames, offsets and image UUIDs remain usable for symbolication.
Free-form exception messages, thread names, queues, personal paths and identifiers
are omitted. No audio, text, image, user settings dump, other applications' logs
or whole-system log archive is included. An empty journal or unavailable crash
report still produces a useful ZIP with a clear explanation.

Every shipped release also preserves its exact `.xcarchive` in
`~/.openramble/release-symbols/OpenRamble-<version>-symbols.zip` and attaches that
archive to the GitHub release. `symbols.json` records build, source commit, binary
hashes and architecture UUIDs. Main-app and CLI dSYMs must match before publishing.
Download the matching release's symbol archive, extract it, and use Xcode or
`xcrun crashlog` / `atos` with the matching UUID and architecture. Rebuilding the
same source does not recreate a missing dSYM. A report with no stack frames cannot
be repaired by symbols; register addresses can sometimes locate the leaf frame.

Apple references (checked 2026-09-27):
- [Acquiring crash reports](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)
- [Symbolicating a crash report](https://developer.apple.com/documentation/xcode/adding-identifiable-symbol-names-to-a-crash-report)
- [Logging privacy](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)

The performance research build below is separate. Its existing release prohibition
and `OPENRAMBLE_DIAGNOSTICS` gate remain unchanged.

# Performance diagnostics build

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

# Mac Mini streaming and parallel-file protocol

Recorded before new inference on 9 October 2026. Base is OpenRamble 0.32.0,
commit 8836439fb5cc51ffe9c64d31e6bfbc802cbb7367. The clean checkout is on
waiMini.local: Apple M4, 10 CPU cores, 16 GiB, macOS 26.4 (25E246).

The installed user's app is 0.31.2 and remains idle in the desktop workload.
It is not the tested binary. Its PID and CPU use are recorded around each
batch; no microphone or user settings are changed. The old August advice to
stop the UI is not followed here because this is a shared active desktop.

## Questions and boundaries

1. Measure controller Stop to the test insertion sink, including unfinished
   streaming work, final recognition and text processing. A prerecorded PCM
   capture replaces the microphone. The sink replaces the destination app.
   These are not physical-key or third-party insertion measurements.
2. Measure recording Stop to queue drain separately, using the shipping
   MeetingSegmentPolicy and MeetingTranscriptionQueue. This excludes screen
   encoding, audio-device shutdown and persistence in the app's MeetingStore.
3. Compare 1, 2 and 4 independent models on identical file chunks and the
   shipping timed joiner. This changes only scheduling, not model, cuts or
   stitching. Several sessions sharing one model must remain serialized.

The August Core ML cache failures remain closed. The new fact is that 0.32.0
uses transcribe.cpp 0.2.3, Metal, Parakeet v3 Q8 and pause-based streaming.
This experiment does not repeat or claim the old exact-cache design.

## Frozen inputs and reporting

Use the existing October FLEURS test selection and pinned archive hashes.
Choose one 4 to 12 second fixture per language by the existing rank, before
recognition. Construct about 60 and 360 second fixtures from complete phrases
in rank order with 0.5 second gaps, and reuse the previous 59-minute mono and
mixed composite recipe. All are public read speech; composites are not
natural dictation or meetings. Record PCM, references and component hashes.
No speech synthesis, private audio or model changes.

Primary controller matrix: RU/EN, short/about 60 seconds, normal desktop and
10 owned CPU-busy processes, 20 real-time replays per cell after a warmup.
Alternate language and duration; reverse condition order across rounds.
Report p50/p95/max with n, exact timing scope, WER and deletion rate. Record
frame-delivery lateness and work completed before Stop. Do not substitute the
last decode duration for controller latency. Distinct 360-second accelerated
replays test file-backed completion and an immediate-stop backlog; label them
separately and never present them as real-time dictation.

File matrix: independent fresh processes for workers 1/2/4, three repeats,
balanced cyclic order, identical mono RU, mono EN and mixed long files.
Warm one short clip before each pass. Report model load separately, total
file processing, process peak RSS, sampled physical footprint/pressure/swap,
per-language WER, deletions, exact text parity, ordered word timings and
seam completeness. Compare one-worker output against FileTranscriber.
Four workers are a bounded memory/scaling diagnostic, not a product default.

Stop on a model failure, missing chunk, duplicate output or memory-pressure
warning. Keep failures and partial records. Shut down only owned load PIDs.
Do not stop other chats or their jobs. Do not overlap inference with builds
or downloads. Preserve process/thermal snapshots around each batch.

A product change needs reproducible improvement of at least 10%, unchanged
chunk outputs and no missing words or new ordering defect. Otherwise retain
the shipping default and publish a negative result. A product defect needs a
regression test that fails before its fix. No release is planned.

## Artifact policy

Commit harnesses, protocol, aggregate results and public-fixture text evidence.
Keep audio, models, binaries, private handoff and correspondence outside Git.
Product Radar materials are drafts for review; do not save or submit the form.
Prior M4 Pro data stays in a separate series with its own hardware caption.

## Registered safety amendment after the smoke run

At 10:44 UTC the first four-model smoke attempt on a 61.92-second EN file
triggered `kern.memorystatus_vm_pressure_level=2`. The runner terminated only
its test process. The sampled footprint reached 2682194464 bytes during
model preparation; recognition did not complete. This is a memory-pressure
abort on the shared 16 GiB Mini, not a model OOM result and not a timing.
The failure and log remain in smoke-v1. Do not repeat four-model attempts on
this machine. Continue the file matrix with `--max-workers 2`; keep 4 marked
as not measured due to the safety stop. No file-speed conclusion was drawn
before this amendment. The primary dictation matrix remains unchanged.

Before the first long-file measurement, the build gate was narrowed to real
compiler/linker processes. `xcodebuild test` was idle after compilation while
a separate project's UI test remained active. Its children were idle
SWBBuildService and DTServiceHub, with no compiler processes. Treat this as
desktop background work and keep the process snapshots. Do not interrupt
other work. Abort if any real compilation/linking starts during inference.
The first file runner only waited; it produced no measurements before this
gate adjustment. Preserve that wait log as files-v1 and start files-v2.

## Resource reset and new scaling series, 16:18 UTC

The user explicitly authorized shutting down competing work to finish the
benchmark map and then test improvement hypotheses. Two simulators from the
morning session were already shut down. With no active build or XCTest
process, the remaining idle iPhone simulator was shut down by its exact ID.
Before that shutdown, swap use was approximately 3.4 GiB instead of 12 GiB,
memory pressure was normal, and free disk space had increased to 12 GiB.
The private evidence includes before/after process and memory snapshots.

This is a new resource condition. It supersedes the earlier prohibition on
another four-model attempt: run a new smoke series, then a fresh 1/2/4 file
matrix only if the smoke passes. Keep the same immediate memory-pressure
abort, compiler gate, model, fixtures and binary. Preserve all earlier
failures and the four incomplete pilot timings; do not pool those timings
with the new primary series. If four models warn again, keep that cell as
unmeasured and continue the supported worker counts. The real-time controller,
meeting and long-capture matrices remain as registered above. Other resource
changes must be recorded, and inference never overlaps our own builds.

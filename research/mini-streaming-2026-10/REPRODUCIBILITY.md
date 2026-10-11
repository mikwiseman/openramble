# Reproduce the Mini experiment

The raw evidence uses public FLEURS speech only. No microphone, clipboard or
user recording is read. Audio and model binaries are not committed.

## Source revisions matter

The current branch includes accepted behavior changes. Rebuilding its tip
does not reproduce the old default. Use a separate checkout of the recorded
revision for each cohort, and inspect its saved identity before combining data.

| Cohort | Source revision |
| --- | --- |
| Original 301-run baseline and separate scaling | `373f2c294a79daae76b449173c2001589df1cb01` |
| Fixed meeting offsets, file-policy development/holdout, tail read | `048cefd` (full identity in each data export) |
| Full FileTranscriber verification and 18 quiet/noise runs | `7dc3f2638b45a859fd232248c2497347719e3525` |
| Second holdout, system-channel default | `cea8893575bbefb5c9af25c8103725cb57b07d03` |

Every identity also records the runner, harness, binary, input manifest and
model SHA-256; custom runs additionally bind their plan. A rebuild may have
a different binary hash and must use a new output directory. New measurements
must not be silently appended to the archived cohort.

## Inputs

Use the October corpus preparer from this repository. It pins the dataset
revision and archive checksums, selects 100 RU and 100 EN test files by a
deterministic rank, and converts them to mono 16 kHz PCM.

```bash
export BENCH_ROOT="$PWD/work/mini-data"
python3 research/product-benchmark-2026-10/scripts/prepare-handy-benchmark.py
python3 research/mini-streaming-2026-10/prepare.py "$BENCH_ROOT"
```

The second command chooses one existing 4–12 second input per language and
constructs fixed long composites from whole phrases. The 59-minute RU/EN
audio hashes match the preceding M4 Pro experiment. Dataset: google/fleurs,
revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, CC BY 4.0.

The model file is `parakeet-tdt-0.6b-v3-Q8_0.gguf`, 739508576 bytes,
SHA-256 `5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7`.
Use an explicitly installed copy and set `BENCH_MODEL` to its containing
directory. The runner verifies this checksum before inference.

## Build and checks

```bash
./scripts/check.sh --fast
swift build --package-path Packages/LocalASR -c release --build-tests \
  -Xswiftc -enable-testing
```

Run checks without the benchmark configuration environment variable. The
new test skips unless `OPENRAMBLE_PRODUCT_BENCHMARK_CONFIG` explicitly names
a public-fixture configuration. `-enable-testing` exposes the existing file
chunker and joiner to the research test without changing shipping code.

Complete compilation and downloads before starting any measured run. The
Mini check environment needed the existing Rust toolchain on PATH and CMake
from an isolated task environment. Neither change touches the application.

## Run one lane at a time

```bash
python3 research/mini-streaming-2026-10/run.py smoke --max-workers 2 \
  --data "$BENCH_ROOT" --out work/mini-smoke --model "$BENCH_MODEL"
python3 research/mini-streaming-2026-10/run.py file --max-workers 2 \
  --data "$BENCH_ROOT" --out work/mini-files --model "$BENCH_MODEL"
python3 research/mini-streaming-2026-10/run.py controller \
  --data "$BENCH_ROOT" --out work/mini-controller --model "$BENCH_MODEL"
python3 research/mini-streaming-2026-10/run.py meeting \
  --data "$BENCH_ROOT" --out work/mini-meeting --model "$BENCH_MODEL"
python3 research/mini-streaming-2026-10/run.py long \
  --data "$BENCH_ROOT" --out work/mini-long --model "$BENCH_MODEL"
```

Each job uses a fresh `xctest` process with an explicit configuration. Models
load and receive a five-second warmup before timing starts. The controller
uses production DictationController, SpeechSegmenter and streaming queue.
Its public PCM capture and insertion sink deliberately replace OS edges.
No measured number includes a physical key event or another app's paste.

The file experiment uses independent model handles with the production
FileAudioChunks and TimedTranscriptJoiner. It processes bounded waves, then
joins in input order. This experimental scheduler does not use the shipping
one-chunk prefetch; the FileTranscriber control measures that path separately.

The runner records model, input, binary, harness and runner hashes. Resume
with identical commands; only jobs with a successful process completion and
a recorded JSON result are skipped. A changed identity needs a new output
directory. Never combine different binaries into one primary series.

The runner waits for active compiler/linker processes before each job and
aborts a job if compilation begins during it. A UI test's idle `xcodebuild`
parent is ordinary background workload, recorded in the private snapshot.
The runner stops on memory pressure, process error,
missing output or timeout. It terminates only the CPU load processes it owns.
Failed runs are evidence, not successful speed measurements.

Full process snapshots remain private. Publish the sanitized export rather
than raw observations or absolute-path configurations.

## Score and draw

Use Python with `jiwer==4.0.0`, NumPy and Matplotlib.

```bash
python3 research/mini-streaming-2026-10/analyze.py \
  work/mini-files work/mini-controller work/mini-meeting work/mini-long \
  --data "$BENCH_ROOT" --out work/mini-public-data
python3 research/mini-streaming-2026-10/plot.py \
  --summary work/mini-public-data/summary.json \
  --old research/product-benchmark-2026-10/data/products-benchmark.json \
  --out work/mini-figures
```

If a preparation run contains a safety abort, append `--failure-runs` and
that run's directory to the analysis command. The published Mini export
includes the original four-model smoke abort this way, while excluding
successful smoke timings from the primary groups.

WER uses Unicode NFC, lowercase, `ё` to `е`, and Unicode word tokens with
punctuation removed. Numerals are not expanded. Deletion rate is deletions
divided by reference word count. The scorer retains deletion runs of four
or more words for inspection. Repeating one fixture does not turn it into
many independent language examples. p50 and p95 use linear interpolation at
`(n - 1) * p`.

Memory includes `getrusage` process peak RSS and physical footprint sampled
through Darwin `proc_pid_rusage` at one-second intervals. The sample maximum
can miss shorter peaks. Model load and warmup are inside memory accounting
but outside recognition time. CPU pressure is ten separate busy-loop
processes, not a guarantee about total system utilization.

## Registered follow-up experiments

Build the committed candidate test bundle with the same release command
above. All custom jobs bind the plan SHA-256 as well as source, runner,
harness, binary, inputs and model. Keep every phase in its own output directory.

```bash
python3 research/mini-streaming-2026-10/run.py custom \
  --plan research/mini-streaming-2026-10/experiment-plans/meeting-coverage.json \
  --data "$BENCH_ROOT" --out work/mini-meeting-coverage --model "$BENCH_MODEL"
python3 research/mini-streaming-2026-10/run.py custom \
  --plan research/mini-streaming-2026-10/experiment-plans/segment-caps.json \
  --data "$BENCH_ROOT" --out work/mini-segment-caps --model "$BENCH_MODEL"
python3 research/mini-streaming-2026-10/offline-seam-study.py \
  work/mini-segment-caps --data "$BENCH_ROOT" --all-caps \
  --out work/mini-cap-replay.json
python3 research/mini-streaming-2026-10/run.py custom \
  --plan research/mini-streaming-2026-10/experiment-plans/tail-read.json \
  --data "$BENCH_ROOT" --out work/mini-tail-read --model "$BENCH_MODEL"
```

Use early-pauses.json and narrow-context.json only as the registered
conditional development follow-ups. Replay each with the same offline
helper. Pass all completed development replay JSON paths to
decide-joint-quality.py before extracting any holdout audio. The replay
first asserts exact agreement with the native unchanged joiner.

```bash
python3 research/mini-streaming-2026-10/decide-joint-quality.py \
  work/mini-cap-replay.json work/mini-early-replay.json work/mini-context-replay.json \
  --out work/mini-quality-decision.json
python3 research/mini-streaming-2026-10/prepare-heldout.py \
  --decision work/mini-quality-decision.json --source-data "$BENCH_ROOT" \
  --selection research/mini-streaming-2026-10/experiment-plans/heldout-selection.json \
  --out work/mini-heldout-data
```

The preparer refuses to open the holdout without a positive development gate,
checks the sealed selection and archive hashes, uses the same afconvert PCM16
conversion, and rejects audio hashes already present in development.
Do not tune a new policy on this heldout output; a subsequent new hypothesis
requires a fresh disjoint validation set. An approved quality policy still
needs native regression tests, matching repeated controls and final lifecycle
checks before adoption.

## Synthetic final-context diagnostic

This separate probe uses the cached Samantha WAV from the existing
`testEnglishTrailingSendStaysVerbatimAndNeverPressesReturn` test. Its exact
hash is registered in HYPOTHESES.md. `prepare-end-context.py --source-wav
<cached-WAV> --out <fresh-directory>` verifies that hash and writes an identical
PCM control plus a500ms-zero suffix variant. Use this new directory as
`run.py custom --data` with `experiment-plans/tts-end-context.json`. Never mix
these synthetic results into the FLEURS quality tables. A different system
voice asset requires a new cohort rather than ignoring the hash mismatch.

## Quiet speech, echo and the second heldout set

At revision `7dc3f26`, generate the four development speech composites and
five deterministic noise fixtures with `prepare-quiet-meeting.py
--source-data "$BENCH_ROOT" --out work/mini-quiet-data`. Run the generated
`quiet-meeting.json` with `run.py custom`, then score using
`analyze-quiet-meeting.py --run work/mini-quiet --data work/mini-quiet-data
--scorer research/mini-streaming-2026-10/analyze.py --out work/mini-quiet-export`.

The global threshold is rejected on sparse echo. Do not describe the heldout
results below as validation of that global candidate. The separately
registered system-only variant first requires the capture tests in
`SystemMeetingDefaultTests`, the existing `MeetingCaptureTests` and
`CrossTalkGateTests`. Its RED/GREEN evidence is in `regression-red/` and
`data/system-meeting/`. The microphone threshold and echo gate stay unchanged.

At revision `cea8893`, the second preparation is:

```bash
python3 research/mini-streaming-2026-10/prepare-quiet-heldout.py \
  --decision research/mini-streaming-2026-10/data/quiet-meeting/decision.json \
  --echo-evidence research/mini-streaming-2026-10/data/system-meeting/echo-decision.json \
  --system-only-registration research/mini-streaming-2026-10/experiment-plans/system-only-registration.json \
  --selection research/mini-streaming-2026-10/experiment-plans/quiet-heldout-selection.json \
  --source-data "$BENCH_ROOT" --first-heldout work/mini-heldout-data \
  --out work/mini-system-heldout-data
python3 research/mini-streaming-2026-10/run.py custom \
  --data work/mini-system-heldout-data --out work/mini-system-heldout \
  --plan work/mini-system-heldout-data/quiet-heldout.json --model "$BENCH_MODEL" --max-workers 1
python3 research/mini-streaming-2026-10/analyze-quiet-meeting.py \
  --run work/mini-system-heldout --data work/mini-system-heldout-data \
  --scorer research/mini-streaming-2026-10/analyze.py \
  --out work/mini-system-export --heldout --channel system
```

Use the final research helpers from this PR alongside the specified source
checkout: some export/preparation helpers were added after native execution.
The source-data directory must retain the pinned source archives and the
first holdout's `source-clips.json` for actual PCM and normalized-text exclusion.
The second heldout candidate omits a threshold override, exercising the real
system default; the control explicitly selects 0.02.

Both heldouts have now been inspected. Reproduction is possible, but they
are no longer untouched validation data for another parameter search.
One pass per threshold in the second holdout supports its fixed quality gate,
not a repeatability, latency percentile or live-call speed claim.

## Validation boundaries

With an explicit empty `WAI_MODELS_ROOT`, `./scripts/check.sh --fast` passes
659 core/capture tests, 199 LocalASR tests (32 model-related skips), the Rust
workspace, FFI, conformance and surface checks on the final ASR source.
That does not turn skipped inference checks into passes. Existing model E2E
failures remain documented in `FINDINGS.md` and
`regression-red/release-e2e-comparison.json`. Full-path file parity is separately
recorded in `data/file-quality/native-verification.json`.

# Reproduce the Mini experiment

The raw evidence uses public FLEURS speech only. No microphone, clipboard or
user recording is read. Audio and model binaries are not committed.

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

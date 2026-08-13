# Benchmark methodology

The `asr-bench` executable measures a pinned local recognition pipeline. These
benchmarks are development evidence, not an application release gate.

## Build and install models

```bash
swift build --package-path Packages/LocalASR -c release --product asr-bench
./Packages/LocalASR/.build/release/asr-bench install
./Packages/LocalASR/.build/release/asr-bench install-vocab
```

## Run a fixture

```bash
./Packages/LocalASR/.build/release/asr-bench transcribe path/to/audio.wav
```

The scorer reports word error rate, character error rate, punctuation errors,
and explicit insertions, deletions, and substitutions. Case is folded, the two
common written forms of the Russian yo/ye sound are treated as equivalent, and
spoken numerals are normalized before comparison. Punctuation is scored
separately rather than silently discarded.

Use only consented audio. Keep voice files outside Git and freeze reference
transcripts before comparing pipeline variants. Record the model revisions,
dependency commits, command-line options, fixture checksum, and source commit
for every published result.

Synthetic fixtures are useful for reproducibility but do not establish quality
on live speech. Do not present synthetic scores as human-speech measurements.

## OpenRamble vs Handy 0.9.5 (2026-08-13)

This is the current controlled comparison to use for product writing. It used
an Apple M4 with 16 GB RAM on macOS 26.4, the shipping OpenRamble Core ML
pipeline with acoustic vocabulary and inference pre-warm enabled, and Handy's
official notarized arm64 0.9.5 release with its catalog-default Parakeet v3
Q8_0 GGUF on Metal. Each value is two unreported warm-ups followed by nine
measured recognitions of the identical 16 kHz mono input. `p50` is the median;
`p95` is linearly interpolated.

| Input | Audio | OpenRamble p50 / p95 | Handy p50 / p95 | Median result |
|---|---:|---:|---:|---:|
| Synthetic Russian, short | 4.08 s | 0.1388 / 0.1449 s | 0.0820 / 0.1128 s | Handy 1.69× faster |
| Synthetic Russian, medium | 36.63 s | 0.5588 / 0.5623 s | 0.5950 / 0.6042 s | OpenRamble 1.06× faster |
| Synthetic Russian, long | 183.91 s | 2.8258 / 2.8527 s | 16.4250 / 16.9016 s | OpenRamble 5.81× faster |
| LibriSpeech `test-other` sample | 7.06 s | 0.1557 / 0.1575 s | 0.1100 / 0.1318 s | Handy 1.42× faster |
| VOiCES room sample | 3.40 s | 0.1303 / 0.1329 s | 0.0690 / 0.0842 s | Handy 1.89× faster |

Both apps produced zero word errors against the frozen references for the two
real English samples. Two clips are an integration check, not a representative
quality corpus, so this is not evidence of equal general WER. The three
synthetic Russian clips have no quality claim. OpenRamble reached 65× real time
on the three-minute input and used about 2.41 GB peak RSS; this run did not
capture Handy RSS with the same measurement method, so no memory comparison is
published.

The defensible public statement from this run is: **“Up to 5.8× faster than
Handy 0.9.5 on a tested three-minute local transcription, and 65× faster than
real time on an Apple M4.”** It must stay attached to the hardware, fixture,
versions, and method above. The run does not support “fastest for every clip”
or “10× faster”: Handy retains a 1.4–1.9× short-utterance advantage on this
machine. A product target is not a benchmark result.

The reproducible runner checkpoints atomically after every engine/fixture pair
and stores transcript hashes rather than transcript text:

```bash
./scripts/benchmark-local-asr.py \
  --manifest /absolute/path/to/manifest.json \
  --openramble-bin Packages/LocalASR/.build/release/asr-bench \
  --handy-bin /absolute/path/to/Handy.app/Contents/MacOS/handy \
  --handy-model parakeet-tdt-0.6b-v3-Q8_0 \
  --warmups 2 --repeats 9 \
  --output /absolute/path/to/report.json
```

The manifest records each fixture's absolute path, source, license, optional
frozen reference, model revisions, application commits, and release-asset and
model SHA-256 values. This run pinned Handy source
`db003f38b1aef4eb967ac3419bebc851d680f71c`, release asset SHA-256
`d7b83185ebe04d67b51b668a5ac26a052128ec27ff1dd5f0da85d385aa7de7aa`,
and Q8_0 model SHA-256
`5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7`.

## Handy backend investigation (2026-08-13)

Hardware: Apple M4, 16 GB, macOS 26.4. Audio: reproducible macOS `say`
fixtures, so these numbers establish latency only, not human-speech quality.

The comparison used Handy commit `549cbde3ebb72459f7f7230783931a45222018a1`.
There are two distinct Parakeet v3 installations in that source tree:

- New installations use pinned `transcribe-cpp` 0.1.3 with the catalog's
  default Q8_0 GGUF
  (`sha256:5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7`).
  That exact catalog entry is offline-only; Handy's stream/finalize path does
  not run for it.
- Handy retains a deprecated direct-download ONNX int8 entry for existing
  installations. It runs through `transcribe-rs` 0.3.8 and has archive SHA-256
  `43d37191602727524a7d8c6da0eef11c4ba24320f5b4730f1a2497befc2efa77`.

Both were built and measured, rather than inferring the backend from the model
display name.

| Pipeline | 4.08 s audio | 36.63 s audio | Peak RSS |
|---|---:|---:|---:|
| OpenRamble Core ML, warm, vocabulary on | 0.14 s | 0.54 s | 2.41 GB |
| Handy backend, GGUF Q8_0, Metal | 0.078 s | 0.599 s | 0.97–1.27 GB |
| Handy legacy backend, ONNX int8, CPU | 0.152 s | 1.19 s | 1.71–1.88 GB |
| OpenRamble Core ML, warm, vocabulary off | 0.127 s | 0.352 s | — |

The native backend has a lower short-utterance floor and substantially lower
memory use, but it is not generally faster: on the longer fixture, the current
Core ML path with acoustic vocabulary was slightly faster, and without the
second acoustic pass it was much faster. Adopting it would also add a 740 MB
model and a second runtime/model lifecycle. These measurements therefore do not
justify replacing the shipping backend solely for latency.

FluidAudio's long-form window pool was also swept on the exact 183.91-second
fixture after inference warm-up. Two workers took 1.99 s, four took 1.48–1.56 s,
six took 1.29–1.31 s, and eight or ten took 1.31 s. Six is now the shipping
default. The transcript SHA-256 was identical at four and six workers
(`f535f6a32e729561cdd185a6854353c2e3f1845794477a66f167bcf6126d163d`),
peak RSS stayed at about 2.414 GB, and the 36.63-second fixture remained flat
(0.36 s at four, 0.37 s at six). This buys roughly 15% on long dictation without
a quality, memory, or common short-dictation tradeoff.

The retained ONNX backend is not the source of Handy's short-latency advantage
on this machine. After its first run, it was slightly slower than warmed Core
ML on the short fixture and more than twice as slow on the 36.63-second fixture.
On the 183.91-second fixture it took 10.11 seconds, versus 1.43 seconds for the
warmed Core ML path without vocabulary. Its model load also took 0.60–0.77
seconds. Moving the product to ONNX would therefore regress the important long
dictation case substantially.

The actionable differences were elsewhere:

- Merely loading Core ML did not materialize every inference path. A first
  vocabulary-enabled recognition was observed at 2.51 s while steady-state
  repeats were 0.14 s. Running a one-second silence inference after both model
  loads made the first measured fixture 0.17 s; the warm-up itself took 0.39 s
  in that run and happens before the app reports the recognizer ready.
- Handy sends the recorder's Float32 PCM directly to recognition and persists
  WAV concurrently. OpenRamble used to close an Int16 WAV, reopen it, and
  convert it to Float32. The shipping capture now hands the same in-memory PCM
  to ASR while retaining the WAV as the durable recovery copy. The fast-path
  buffer is capped at five minutes (about 19 MB); unlimited longer recordings
  fall back to the WAV instead of growing resident memory without bound.
- FluidAudio pads every Parakeet v3 batch window to the model's fixed 15-second
  input. This explains the short-utterance latency floor. Its true-streaming
  managers use different model families; the v3 sliding-window API also lacks
  the product's explicit language-hint contract, so promoting preview output to
  final text would be a quality/feature change rather than a free optimization.

Reproduce the warmed product path with:

```bash
WAI_VOCAB=on WAI_ASR_PREWARM=on \
  ./Packages/LocalASR/.build/release/asr-bench bench path/to/audio.wav
```

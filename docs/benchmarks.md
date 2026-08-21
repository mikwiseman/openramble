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

## Paired OpenRamble and Handy protocol (2026-08-14)

The retired asymmetric comparison has been removed. Its timers covered
different work, it ran engines in blocks with only nine observations, and it
could not verify every Handy output. No number from that run is a product
claim.

The replacement harness launches each backend once behind the same persistent
JSONL protocol. It decodes canonical 16 kHz mono Float32 PCM before the timed
`predecoded-product-warm` lane, then interleaves every measured pair in a
seeded, balanced order. It records p50/p95/p99/max, paired-bootstrap confidence
intervals, Mac hardware model, chip, memory, macOS version/build, exact argv and
binary/model/source/patch/input hashes. Thermal state remains run evidence that
the operator must capture separately; the JSON report does not infer it.
Every output is normalized and hashed on every run; plaintext transcripts are
never written to the report. Checkpoints resume only when the complete
experiment identity still matches.

A 2026-08-14 internal acceptance run completed 400/400 pairs across four real
speech and four synthetic boundary fixtures without a hang. All four real
fixtures were transcript-stable and matched between the two tested backends
after common normalization. This is a backend-only check on one Apple M4, not
an official app-to-app benchmark: the Handy side is a locally patched pinned
backend, the engines use different model quantization, custom-vocabulary
configuration is asymmetric, and the fixture set is too small for a public
speed or general-WER claim. Synthetic boundary results are diagnostic only.

Therefore OpenRamble currently publishes **no speed multiplier versus Handy**.
A future claim requires publishing the consented fixture manifest and complete
artifacts, independent reproduction, an app-level lane, several Apple Silicon
generations and a representative frozen quality corpus.

## Decoder thread topology under processor pressure (2026-08-21)

The Parakeet batch decoder is pinned to one host-CPU thread. This is not a
general claim that serial inference is faster: the Metal encoder, Accelerate
filterbank, and batch mel front-end retain their own parallelism. The runtime's
CPU predictor installs a spin/yield barrier for every graph node at two or more
session threads; under full CPU saturation, removing that barrier mattered far
more than parallel decoder work.

On one Apple M4 Pro, a warmed 3.98-second fixture measured median 0.068 s with
eight threads and 0.083 s with one thread at idle. Under 14 competing CPU
workers, the paired medians were 0.741 s and 0.187 s. Five interleaved pressure
runs then completely separated the shipping one-thread topology
(0.119–0.228 s) from an explicit eight-thread control (0.580–1.466 s); the
same gate failed before the default changed. A paired 183.91-second idle
fixture measured medians 6.802 s at eight threads and 7.266 s at one (1.068×),
within the predeclared 1.5× guard. An earlier end-to-end run of that long
fixture reported 3.618 s at the runtime default; the absolute numbers came
from different harness and machine states, so only same-session paired ratios
were used for the decision.

These are local engineering measurements, not public cross-device benchmarks.
The Vulkan path shares the same decoder barrier but was not measured here.

The runner checkpoints atomically after every observation:

```bash
/usr/bin/python3 scripts/benchmark-local-asr.py \
  --manifest /absolute/path/to/manifest.json \
  --openramble-bin Packages/LocalASR/.build/release/asr-bench \
  --handy-bin /absolute/path/to/patched/handy \
  --handy-model handy-computer/parakeet-tdt-0.6b-v3-gguf/parakeet-tdt-0.6b-v3-Q8_0.gguf \
  --handy-model-path /absolute/path/to/parakeet-tdt-0.6b-v3-Q8_0.gguf \
  --handy-model-sha256 <sha256> \
  --handy-source-commit <40-character-commit> \
  --handy-patch scripts/benchmark-adapters/handy-persistent-jsonl-db003f3.patch \
  --lane predecoded-product-warm \
  --openramble-vocabulary on --openramble-prewarm on \
  --openramble-encoder-placement automatic \
  --openramble-vocabulary-scheduling candidateRegions \
  --warmups 6 --repeats 50 --bootstrap-samples 10000 \
  --output /absolute/path/to/report.json
```

The manifest records source, license, language, immutable input checksum and an
optional frozen reference for every fixture. `scripts/benchmark-adapters/README.md`
documents why the Handy patch is benchmark infrastructure rather than evidence
of parity with the official GUI application.

Report schema 4 includes OpenRamble phase timing schema 1. Collection is enabled
only by `serve-jsonl`; the shipping adapter leaves it off. The monotonic phases
are primary TDT inference+decode (the exact `AsrManager.transcribe` call), the
whole cached lexical localization/gating call, summed wall time of each
FluidAudio `spotKeywordsWithLogProbs` call, and CTC rescoring through conditional
punctuation restoration after all guards pass. The CTC value is API-wall time,
not a claim about an isolated Core ML kernel; audio slicing and sparse timeline
reconstruction remain unclassified orchestration outside it.
Skipped phases are JSON `null`, never a zero sentinel, and every report records
the CTC invocation count and vocabulary outcome. `elapsed_ns` remains the
authoritative outer wall time. In the explicit `alwaysParallel` reference lane,
TDT and CTC durations may overlap, so phase values must never be summed to
reconstruct total latency. `run-file` includes audio decoding only in the outer
total; its model phase boundaries remain identical to the predecoded lane.

## Vocabulary scheduler evidence

The shipping scheduler completes primary TDT recognition first, applies a
cached allocation-bounded lexical gate, and runs the optional CTC vocabulary
model only for regions that can change the final text. Ordinary short
dictations therefore avoid both discarded per-term dynamic programming and
accelerator contention with a speculative CTC pass. Candidate windows retain
the pinned overlap reconstruction rules. Frozen A/B fixtures, including real
Russian speech and an actual developer-term case, produced identical transcript
hashes between the reference and candidate-first schedulers; the full LocalASR
suite also exercises final context rescoring. These are implementation
regression checks, not cross-product claims.

## Reusable TDT input buffer evidence (2026-08-14)

The pinned upstream runtime cleared its cached 240,000-element Float32 audio
input after every TDT request, even though `preparePreprocessorInput` overwrites
the complete fixed-size buffer before Core ML can read it again. On the Apple M4
host used for the phase study, that redundant clear took about 16 ms by itself.
The pinned OpenRamble FluidAudio fork keeps the cache's zero-reset behavior as
the default and skips it only for this fully overwritten TDT input.

The same predecoded, persistent-process, vocabulary-on lane was run before and
after the change. The baseline used 20 measured requests per fixture and the
post-change run used 50; both used six warm-ups, the same frozen PCM hashes,
`.automatic` compute placement, and `candidateRegions` scheduling.

| Fixture | Before p50 | After p50 | Change |
|---|---:|---:|---:|
| LibriSpeech real EN, 7.06 s | 62.034 ms | 50.930 ms | -17.9% |
| VOiCES real EN, 3.53 s | 52.622 ms | 40.260 ms | -23.5% |
| FLEURS real RU, 7.44 s | 60.854 ms | 49.027 ms | -19.4% |
| FLEURS real RU, 3.40 s | 60.233 ms | 47.869 ms | -20.5% |
| Synthetic boundary, 14.9 s | 81.349 ms | 70.607 ms | -13.2% |
| Synthetic boundary, 15.1 s | 111.025 ms | 98.289 ms | -11.5% |
| Synthetic boundary, 29.9 s | 144.997 ms | 127.410 ms | -12.1% |
| Synthetic boundary, 30.1 s | 138.447 ms | 127.424 ms | -8.0% |

Every fixture retained exactly the same raw and normalized transcript hash. A
separate Russian developer-term fixture also retained its exact
`rescored_modified` hash; its primary TDT phase moved from 88.36 ms to 71.03 ms,
while the independent CTC phase dominated total variance. The optimized
eight-fixture report has SHA-256
`b8b758370a444d9faf67bcee9da1648121409bd4bb3de38eb376f7eafb23eacf`.
These are single-host implementation measurements, not a cross-hardware or
cross-product speed claim.

## Typed CTC tensor access evidence (2026-08-14)

The optional acoustic-vocabulary path previously wrote up to 240,000 Float16
audio samples and read roughly 188 × 1,025 Float16 logits through
`MLMultiArray`'s generic subscript. Every scalar crossed the Objective-C
`NSNumber` bridge. The pinned FluidAudio fork now writes the contiguous audio
backing directly and reads logits through their recorded tensor strides. The
log-softmax, candidate selection, overlap merge, and rescoring algorithms are
unchanged.

The same persistent, prewarmed M4 processes were compared in balanced order.
The real 7.578-second Russian developer-term fixture used six warm-ups and 80
measured baseline/candidate pairs, split exactly 40/40 by order. A synthetic
15.156-second repeat exercised two CTC windows with six warm-ups and 40 measured
pairs, split 20/20 by order.

| Candidate path | Baseline total p50 | Typed total p50 | Baseline CTC p50 | Typed CTC p50 |
|---|---:|---:|---:|---:|
| One CTC invocation | 210.403 ms | 120.285 ms (-42.8%) | 101.989 ms | 11.399 ms |
| Two CTC invocations | 413.418 ms | 218.891 ms (-47.1%) | 218.091 ms | 29.821 ms |

Every measured pair retained the same raw and normalized transcript hashes,
the same `rescored_modified` outcome, and the same CTC invocation count.
Float16/Float32, rank-3/rank-4, shipping-sized, and non-contiguous-stride oracle
tests compare the direct path against the former boxed subscript path; the
unsafe-buffer tests also pass AddressSanitizer and ThreadSanitizer. The
one-window and two-window reports have SHA-256
`4d952cb8be7a278d2c596975bd34ff258994fe73d21b74d6ba7aa770f4564f86`
and `2bd34284405da0ba9c6d858177244d18b49f4b230fd058830c87f1c007ec74db`.
The pinned current tree also passed all 233 LocalASR tests, including real-model
TDT and vocabulary-rescore coverage. These are single-host implementation
measurements for dictations that actually invoke optional CTC, not a claim about
ordinary no-candidate dictation or another product.

The same lexical gate that selects candidate audio windows can also prove which
vocabulary terms cannot reach the final rescorer's string threshold. Passing its
conservative term indices to the pinned rescorer keeps the full vocabulary for
collision checks and leaves the separately configured acoustic-rescue pass
unchanged, but avoids rebuilding and comparing forms for unrelated terms. An
internal phase profile localized 35.8 of 36.7 ms to that repeated term loop; CTC
dynamic programming for the accepted candidate was only about 0.2 ms.

Against the typed-I/O implementation, another balanced 80-pair run reduced
total p50 from 119.003 to 83.341 ms (-30.0%) and final fusion from 37.499 to
2.099 ms. A direct before-both-versus-final run measured 212.013 to 84.477 ms
(-60.2%), with CTC inference at 104.651 versus 11.418 ms and fusion at 37.079
versus 2.100 ms. All 80 pairs retained identical raw and normalized transcript
hashes, outcome, and CTC invocation count. The term-filter and direct-combined
reports have SHA-256
`3aac76bb7263c58537611dec51e0c12a06a32e7a8b3c06b615af7a23f8eb9b9b`
and `8f455955c1eaa2747d5c00d6389797d3dca2a67573480ac6df94772a4ca97516`.

On a pinned LibriSpeech fixture with no lexical candidate, a separate 40-pair
check kept every raw and normalized transcript hash identical and never invoked
CTC. Total p50 was 48.040 ms before versus 48.088 ms after (+0.10%); the gate
itself was 2.400 versus 2.383 ms at p50. This is consistent with run noise, not
evidence of a no-candidate speedup. The report SHA-256 is
`2be1a931681ff4a51b395792ab0e1bd3e7911f41d5d1d43016dea18e7a6aca0c`.

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
six took 1.29–1.31 s, and eight or ten took 1.31 s. The transcript SHA-256 was
identical at four and six workers
(`f535f6a32e729561cdd185a6854353c2e3f1845794477a66f167bcf6126d163d`),
peak RSS stayed at about 2.414 GB, and the 36.63-second fixture remained flat
(0.36 s at four, 0.37 s at six). Six buys roughly 15% on this M4's 184-second
fixture, but that single-host result is not a universal concurrency policy;
shipping retains FluidAudio's cross-device default of four until a wider
device matrix justifies per-host tuning.

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
  to ASR while retaining the WAV as the durable recovery copy. The lossless
  fast-path buffer is capped at five minutes (about 19 MB). At that boundary
  capture stops gracefully and transcribes the complete retained take; it does
  not trust an unsealed asynchronous WAV and does not grow resident memory
  without bound.
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

## Reload economics (2026-08-16, Apple M4 Pro, macOS build 25G72)

Measured with `scripts/bench-cold-reload.sh` in an exclusive window (both
dictation apps stopped by exact PID) on the 0.8.0 code. The e5rt
specialization cliff was captured live: the window's very first load — the
OS had purged the ANE program cache earlier that day — took **15.56 s**;
every load after it, in any process, stayed at ~0.11 s. That pair is the
entire story the 0.8.0 residency work is built around.

- In-process model comeback (`unloadModels` → prepare → warm, the resident
  worker path a residency or idle unload now takes): prepare 0.101–0.106 s +
  warm-up 0.043–0.048 s, **0.145–0.154 s total** across three cycles.
- Fresh-process comeback (spawn + dyld + init + load + warm, the pre-0.8
  path): **0.161–0.197 s** across three runs — the process overhead itself
  is small; the historic 13–16 s stalls were always the specialization
  cache, which is exactly what the early-rewarm and wait-and-insert changes
  absorb.
- Peak worker RSS with models loaded in the reload lane: 2.26 GB.
- The APFS-clone cache-key scenario (forcing respecialization without
  touching host caches) and the placement matrix did not run in this window
  because of a since-fixed engine-path bug in the script; the live-captured
  15.56 s cold / 0.11 s warm pair stands as the cliff evidence until the
  next exclusive window.

## transcribe.cpp engine (2026-08-18, Apple M4, macOS 26.4)

Measured through the product path — `DictationLatencyTests`, model on disk,
warm — against the Core ML numbers recorded above for the same fixtures.

| Audio | Core ML (vocab on / off) | transcribe.cpp | |
|---|---:|---:|---|
| 4.08 s | 0.14 / 0.127 s | **0.055 s** | 2.5x faster |
| 36.63 s | 0.54 / 0.352 s | **0.425 s** | comparable |
| 183.91 s | — / 1.43 s | **3.389 s** | **2.4x slower** |

The short path, which is what nearly every dictation is, got materially
faster; long-form got materially slower and is still 54x faster than real
time. A three-minute take costs about 3.4 s instead of about 1.4 s.

Resident memory is 976 MB against 2.41 GB, a warm model load is 0.29 s against
0.15 s warm and 13.5-16 s after the OS purged the Neural Engine cache, and a
half-second take costs 29 ms instead of a full padded 15-second window.

### Terms inside Russian speech

The starter dictionary reaches 22 of its 24 terms in Latin on real model
output. `Docker` and `Kubernetes` no longer do: they used to arrive because a
second Core ML model biased the recognizer acoustically, and the text-level
dictionary cannot reach them — it matches what the recognizer wrote, and the
recognizer now writes "Дакары" and "Кюберниц". Both are recorded as measured
gaps in `TermDictionaryEndToEndTests` rather than removed from the promise.

One synthetic English fixture also regressed: the engine writes "and it" where
the old one wrote "send it", recorded the same way.

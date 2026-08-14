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
intervals, thermal state, exact argv and binary/model/source/patch/input hashes.
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

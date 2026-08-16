# OpenRamble short-dictation engine investigation

Date: 2026-08-14

Scope: read-only investigation of the shared repository. All code changes and builds used for prototypes live under `/tmp/openramble-short-engine.SpfSeY`; no shared repository file was edited by this task.

## Executive verdict

The evidence does **not** support replacing OpenRamble's CoreML engine with Handy/transcribe.cpp as the primary backend. On the same Russian 6.22 s fixture, the warmed OpenRamble CoreML/NE path **without the acoustic-vocabulary pass** is 71.3 ms p50 versus 123.49 ms for Handy's exact native backend proxy: OpenRamble is already about **1.73x faster**. Enabling the shipping 28-term acoustic vocabulary raises the same OpenRamble path to 124.85 ms and consumes the whole advantage. The principal remaining short-dictation floor is therefore vocabulary scheduling/prefilter work, not Swift versus C++ and not the 15 s encoder shape.

The current product default also forces the main encoder to GPU. That is a material regression on the measured M4: the pinned encoder is 25.63 ms p50 on ANE/25.60 ms on `.all`, but 87.74 ms on GPU. In the full shipping-vocabulary path, GPU is 1.8x slower at the 15.1 s boundary and 2.05x slower at 29.9 s because concurrent windows contend on the GPU. `.all` and explicit ANE are statistically indistinguishable warm on this host.

Concrete immediate default: use `.all` as the portable no-cache/fallback choice, load it in a persistent private worker, and complete a real dummy inference before reporting `Ready`. For a genuinely fastest cross-hardware product, run an idle/install-time, sequential, full-pipeline microcalibration over `.all`, `.cpuAndNeuralEngine`, and `.cpuAndGPU`, cache the winner by hardware/OS/model/runtime identity, and never switch placement mid-dictation. Do not hardcode an M1/M2/M3/M4 table.

The highest-value measured engine change is to stop speculative short-form CTC work in `candidateRegions` mode. A temporary prototype that starts CTC only after TDT proves that a lexical candidate exists reduced p50 with identical transcript hashes:

| Fixture | Shipping scheduling | Candidate-first prototype | p50 reduction |
|---|---:|---:|---:|
| FLEURS RU, 7.44 s | 120.05 ms (`.all`) | 71.75 ms (`.all`) | 40.2% |
| RU plain, 6.22 s | 124.85 ms (NE) | 88.55 ms (`.all`) | 29.1% |
| RU developer terms, 7.58 s | ~125.5 ms (NE, earlier balanced lanes) | 108.30 ms (`.all`) | ~13.7% |

The developer-term fixture also got faster. The most plausible explanation is that candidate-first execution avoids accelerator contention even when it later needs vocabulary evidence; this prototype did not separately instrument candidate count or CTC stage time. The remaining roughly 17 ms gap between candidate-first plain speech and the 71.3 ms no-vocabulary floor is consistent with the current allocation-heavy `words × 1...4-grams × terms/aliases × Levenshtein` lexical prefilter.

No 10x claim is justified. The measured warm gains available here are tens of milliseconds; the 10–15 s showstopper is a cold/specialization/readiness failure class and must be eliminated architecturally rather than marketed as an average throughput improvement.

## Frozen inputs and host

- Host: Apple M4 (`Mac16,10`), 16 GB, arm64, macOS 26.4 build 25E246.
- No thermal warning was reported before or after the balanced CoreML runs.
- Frozen shipping benchmark binary SHA-256: `b38197c54ca0a7c41d5bcd0b7798cbbf9e82270996402a8d9b8100b0e6ec9c9e`.
- Temporary `.all` benchmark binary before the scheduling prototype: `d63f755d175a3321e27e94ad35aceac509ebbaab6cd7222fd04dcd0239ddf563`.
- Temporary `.all` + candidate-first binary: `57f8b889c26d65617a66d7050d71d6c67b7713fa045012f653679124bd8c9056`.
- OpenRamble model: `FluidInference/parakeet-tdt-0.6b-v3-coreml@aed02740059203c4a87495924f685de3722ae9ce`, encoder 6-bit palettized/mixed precision, 461 MiB total, 425 MiB encoder.
- FluidAudio: `19600a485baa4998812e4654b70d2bab8f2c9949` (0.15.5 in the product manifest).
- Handy source: `db003f38b1aef4eb967ac3419bebc851d680f71c`.
- Exact transcribe.cpp v0.1.3 source/tag: `a94e021ef658dc7c788837341a13f6acea3baf3c`.
- Handy Q8_0 GGUF SHA-256: `5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7`, 739,508,576 bytes.

Real fixtures were pinned LibriSpeech/VOiCES EN and FLEURS RU. FLEURS revision was `70bb2e84b976b7e960aa89f1c648e09c59f894dd` (CC BY 4.0). Boundary fixtures are deterministic repetitions of the same LibriSpeech PCM cut to 14.9/15.1/29.9/30.1 s; they are valid scheduling fixtures, not independent quality samples. Full fixture provenance and hashes are in `/tmp/openramble-real-short-manifest.json` and the JSON reports listed below.

## Compute placement: full shipping-vocabulary path

Method: predecoded in-memory product path; `WAI_VOCAB=on`; shipping 28-term vocabulary; product prewarm enabled; five additional per-lane warmups; two fresh-process lanes per placement in symmetric order; 50 measured repetitions per lane, therefore n=100 per fixture/placement. Percentiles use linear interpolation at `(n-1)q`. Every placement produced one stable transcript hash per fixture and NE/GPU hashes were identical across all 1,800 measured outputs.

Values are `p50 / p95 / p99 / max` in milliseconds:

| Fixture | Explicit NE | Explicit GPU | p50 winner |
|---|---:|---:|---:|
| LibriSpeech EN 7.06 s | 120.80 / 125.03 / 126.62 / 129.0 | 134.35 / 138.31 / 139.81 / 140.4 | NE 1.11x |
| VOiCES EN 3.40 s | 124.95 / 141.43 / 171.53 / 174.1 | 120.30 / 123.20 / 125.52 / 127.5 | GPU 1.04x |
| RU plain 6.22 s | 124.85 / 127.42 / 129.94 / 134.3 | 150.45 / 154.60 / 161.32 / 163.7 | NE 1.21x |
| EN repeated 14.9 s | 134.95 / 137.52 / 140.14 / 144.3 | 154.80 / 156.61 / 159.20 / 159.3 | NE 1.15x |
| EN repeated 15.1 s | 128.65 / 135.81 / 137.22 / 138.7 | 231.40 / 261.38 / 292.64 / 326.5 | NE 1.80x |
| EN repeated 29.9 s | 161.80 / 167.72 / 171.12 / 172.8 | 331.00 / 342.72 / 345.11 / 345.7 | NE 2.05x |
| EN repeated 30.1 s | 159.50 / 167.70 / 169.01 / 170.2 | 330.65 / 343.44 / 346.61 / 347.8 | NE 2.07x |
| FLEURS RU1 7.44 s | 123.05 / 127.80 / 128.71 / 129.7 | 136.80 / 150.91 / 184.64 / 208.8 | NE 1.11x |
| FLEURS RU6 4.80 s | 124.50 / 126.22 / 126.81 / 127.4 | 133.45 / 135.71 / 137.51 / 138.1 | NE 1.07x |

The one short VOiCES median favors GPU by only 4%, while NE suffered an environmental tail in one lane. It is not sufficient evidence for a GPU default. Above 15 s FluidAudio dispatches multiple windows concurrently through one loaded encoder; GPU windows contend, while ANE stays nearly flat.

### `.all` versus explicit placement

Four fixtures were repeated with symmetric `.all → NE → GPU → GPU → NE → .all` process order, n=100 per placement/fixture. All hashes matched across all three placements.

| Fixture | `.all` | Explicit NE | Explicit GPU |
|---|---:|---:|---:|
| FLEURS RU1 7.44 s | 120.05 / 122.91 / 123.50 / 123.5 | 120.70 / 123.01 / 123.41 / 124.8 | 132.45 / 134.00 / 135.40 / 135.8 |
| FLEURS RU6 4.80 s | 123.95 / 125.80 / 126.53 / 129.3 | 124.20 / 125.80 / 126.11 / 127.2 | 133.40 / 135.61 / 136.60 / 136.8 |
| EN repeated 15.1 s | 122.00 / 133.51 / 133.80 / 133.9 | 121.90 / 133.60 / 134.82 / 136.7 | 228.20 / 232.32 / 233.21 / 233.9 |
| EN repeated 29.9 s | 161.65 / 166.11 / 166.72 / 168.3 | 161.30 / 165.54 / 167.71 / 168.9 | 331.80 / 344.64 / 347.63 / 350.1 |

On this host `.all` effectively selects the same fast encoder route as explicit NE. It is the best portable fallback, but it is not proof that the OS has optimized the whole concurrent product workload on every M-series/OS combination; `MLComputeUnits` is applied per model, not to the scheduling interaction among TDT, CTC, and concurrent windows.

### Transcript hashes and quality guard

CoreML transcript hashes were stable and identical across compute placements:

| Fixture | SHA-256 of transcript UTF-8 |
|---|---|
| LibriSpeech EN 7.06 s | `de779a17ef1f131e54fff2c068b2dd146c6fbee92d471e37b32ad27fa969b70f` |
| VOiCES EN 3.40 s | `3a4531980d66676f383e36269a847e2a037dbb2ca4b5255f35ceb09d518b2268` |
| RU plain 6.22 s | `99109b7548351b7d243936bbe51ceeddab0aece6f19bc5889a6d0ed662878c73` |
| EN repeated 14.9 s | `9717c489b8053f6f6b6543f3e7690482f74f79b5b7b7491f1c9853e18fd1cd19` |
| EN repeated 15.1 s | `0af51c25c852b414aef9244e4bdfe3757fe582ce2d470ade56b493913eb97862` |
| EN repeated 29.9 s | `8b00a1277d4b1556e7d83185be54035470fc2b50707a9d83307d40dbcf9df254` |
| EN repeated 30.1 s | `6084ed9473ac74643f28c3c6d04de6fd6b586229c3c114cf4b5065c70c91903a` |
| FLEURS RU1 7.44 s | `316fbcba203437b57c0bc88e5bc925e3712ac80ecff77d2517e8223fa3d548bd` |
| FLEURS RU6 4.80 s | `7fc4182a756bd6e07183fc11c53110c14081922cd574f3e3983e0a6d6c3cbd7d` |
| RU developer terms 7.58 s | `857097619bc5b3ccb6eca207c007757a114a22fc230d258c9c9766a1d26d389b` |

Both CoreML and the exact Handy backend had normalized WER 0 on all four public real fixtures (two EN, two RU). Punctuation differs on the two EN samples, hence their raw hashes differ. The synthetic developer-term run is not a formal WER corpus: OpenRamble's contextual path preserved `Swift`, while native transcribe.cpp emitted the Cyrillic `свифт`; both still misheard the synthetic OpenRamble phrase. This is a concrete quality risk for replacing the vocabulary-aware path with the native backend.

## Cold, warm, and specialization tails

Fresh processes with the CoreML specialization cache already warm, vocabulary on, prewarm deliberately off, FLEURS RU1, n=20 per placement:

| Placement | Model load p50/p95/max | First inference p50/p95/p99/max | Whole process p50/p95/max |
|---|---:|---:|---:|
| `.all` | 135 / 191.5 / 220 ms | 129.15 / 131.58 / 132.72 / 133.0 ms | 436 / 493 / 522 ms |
| NE | 90 / 162.5 / 210 ms | 129.80 / 132.48 / 135.22 / 135.9 ms | 400 / 473 / 547 ms |
| GPU | 250 / 295.5 / 400 ms | 273.65 / 302.06 / 304.41 / 305.0 ms | 724 / 808 / 868 ms |

GPU's first un-prewarmed inference is roughly twice its warm steady state. Prewarm is not optional.

One first use of the newly introduced `.all` configuration showed `Model loaded in 14.42 s`, followed by a correct 122.9 ms inference. The immediately repeated cache-warm process loaded in 110 ms, prewarmed in 100 ms, and inferred in 121.2 ms. The 14.42 s event was observed in the original command output but was not repeated by deleting system caches, because destructive cache manipulation would contaminate the host; it is a single observation, not a percentile distribution. It is strongly consistent with a CoreML/ANE specialization-cache miss and directly reproduces the user's perceived “hang” class.

Product invariant: the worker must not advertise `Ready` after merely constructing/loading `MLModel`; readiness requires a successful representative inference. Keep the model resident. After crash, model update, OS update, or critical-memory eviction, rewarm outside the stop-to-text critical path and retain the WAV until insertion succeeds.

## Why vocabulary scheduling is now P0

On RU plain 6.22 s, the existing no-vocabulary product-path artifacts contain two 30-measure lanes per placement:

| Path | p50 / p95 / p99 / max |
|---|---:|
| CoreML explicit NE, vocabulary off | 71.30 / 73.68 / 83.98 / 88.7 ms |
| CoreML explicit GPU, vocabulary off | 132.15 / 137.21 / 139.15 / 139.8 ms |
| CoreML explicit NE, shipping vocabulary on | 124.85 / 127.42 / 129.94 / 134.3 ms |
| Exact Handy/transcribe.cpp Metal proxy | 123.49 / 178.73 / 459.47 / 933.5 ms |

The native tail above was polluted by visible background Brave/WindowServer load in its first lane, so it must not be interpreted as an intrinsic Handy stability result. The medians still establish the floor diagnosis: base CoreML/NE is faster, and vocabulary consumes about 53.6 ms on the common plain fixture.

Current source launches a full CTC evidence task concurrently for every `<=15 s` dictation whenever vocabulary is configured. After TDT returns, it waits for the task even when `candidateRegions` is empty, so no inference leaks into the next take. That makes the short path approximately `max(TDT under contention, CTC under contention)` and performs entirely unused CTC work on ordinary speech.

Temporary prototype diff: `/tmp/openramble-short-engine.SpfSeY/all-package/LocalASR/Sources/LocalASR/FluidAudioAdapter.swift`; it changes only `.all` plumbing plus the short scheduler condition. Report: `/tmp/openramble-short-engine.SpfSeY/candidate-only-prototype/report.json`. All three prototype fixtures produced one stable hash across n=100 and exactly matched the corresponding shipping output hash.

The next safe optimization after candidate-first scheduling is to cache normalized term/alias forms and their `[Character]` arrays at vocabulary load, normalize transcript words once, build 1–4-word phrases incrementally, apply the exact maximum-edit cutoff implied by the similarity threshold, and use threshold-bounded two-row Levenshtein. Preserve the existing normalization/Unicode semantics and parity-test every candidate decision before shipping.

## Handy/transcribe.cpp reuse assessment

### Technical feasibility

Yes, it can be embedded in a private helper: v0.1.3 provides a C API, Rust wrapper, Swift XCFramework bindings, and in-memory Float PCM input. Handy holds a persistent `Session`, which keeps its `Model` alive, so repeated dictation does not reload weights. A private worker is preferable to in-process integration because a native crash, allocator fragmentation, or Metal failure should not take down capture/UI.

Handy 0.9.5 pins:

- `transcribe-cpp = 0.1.3`, `default-features = false`;
- macOS feature `metal`;
- crate checksum `4c3c4d6136eeccf56cfe8a6669e2d63770d1ef051c7cafd2cb9226218c66cded4`;
- sys checksum `278fd6a6da4d9d8d5f2716bd6761a76ea55c129fda6ba57856b80249a8570ed4`.

Handy's backend `Auto` is capability-based, not performance-calibrated: it tries discrete GPU, then integrated GPU, layers ACCEL backends, and retains CPU fallback. Metal devices before Apple GPU family 7 are skipped under Auto because their missing simdgroup matrix multiply can produce wrong transcripts. There is no p95/tail/contention microbenchmark or hardware/OS/model score cache. This is robust capability fallback, not a blueprint for universally fastest selection.

### License and attribution

- Handy is MIT, copyright 2025 CJ Pais. Copying Handy integration code requires retaining its MIT notice.
- transcribe.cpp v0.1.3 is MIT, copyright 2026 the transcribe.cpp authors. Its vendored ggml and miniz components are MIT/MIT-style; ship the exact notices from `THIRD-PARTY-LICENSES.md`.
- The Q8_0 GGUF catalog entry is derived from `nvidia/parakeet-tdt-0.6b-v3`, revision `85ac09ea12fc4b1112fa76810059364bc6adc9de`, and is CC BY 4.0. Distribution requires appropriate creator/source credit, the CC BY 4.0 license link, and indication of changes. Have release counsel approve the final attribution wording.
- The pinned CoreML repository frontmatter also says CC BY 4.0, while its README footer incorrectly says Apache 2.0. The product manifest correctly treats it as CC BY 4.0; do not rely on the contradictory footer.

### Model compatibility and product cost

Both artifacts derive from the same 0.6B v3 architecture/language/tokenizer family, but they are not interchangeable weights or runtime state:

- Handy uses a 739.5 MB Q8_0 GGUF/ggml model.
- OpenRamble uses split CoreML bundles with a 445.2 MB 6-bit-palettized encoder plus decoder/joint/preprocessor.
- A native process probe reached 986,791,936 bytes maximum RSS (about 941 MiB), 1,004,717,376-byte peak footprint, and a roughly 415 ms model load. Across 18 persistent-lane loads the native load median was about 208 ms and max 485 ms.
- Running both backends means a second model download, roughly another GiB of live process memory, a second prewarm/recovery/cache lifecycle, and duplicated attribution/update logic.
- transcribe.cpp has no equivalent of OpenRamble's installed 28-term acoustic vocabulary pipeline; its synthetic developer-term transcript was worse on `Swift`.

### Exact native backend proxy timing

This is the exact Handy 0.9.5 backend dependency/model in a persistent process, Metal, five warmups plus 2×50 measurements per fixture, WAV decoded before the timer. It is **not** the full Handy UI/input/insertion E2E path.

| Fixture | Native `p50 / p95 / p99 / max`, ms | CoreML/NE shipping-vocab p50 | Median comparison |
|---|---:|---:|---:|
| LibriSpeech EN 7.06 s | 116.32 / 152.76 / 182.45 / 193.0 | 120.80 | native 1.04x |
| VOiCES EN 3.40 s | 113.29 / 705.03 / 843.88 / 873.9 | 124.95 | native 1.10x |
| FLEURS RU1 7.44 s | 119.85 / 227.80 / 262.58 / 375.2 | 123.05 | native 1.03x |
| FLEURS RU6 4.80 s | 90.13 / 113.48 / 131.09 / 148.5 | 124.50 | native 1.38x |
| RU plain 6.22 s | 123.49 / 178.73 / 459.47 / 933.5 | 124.85 | effectively tied |
| EN repeated 14.9 s | 219.27 / 290.05 / 305.62 / 310.7 | 134.95 | CoreML 1.63x |
| EN repeated 15.1 s | 220.24 / 245.08 / 279.42 / 319.9 | 128.65 | CoreML 1.71x |
| EN repeated 29.9 s | 431.51 / 441.12 / 459.03 / 459.7 | 161.80 | CoreML 2.67x |
| EN repeated 30.1 s | 434.77 / 478.45 / 507.87 / 524.8 | 159.50 | CoreML 2.73x |

This comparison deliberately uses OpenRamble's shipping feature workload and the native engine without that feature. The feature-parity comparison is the no-vocabulary row above, where CoreML/NE wins materially. Therefore a wholesale C++ rewrite or native replacement is not supported. Keep transcribe.cpp only as a possible optional, short-only recovery/experimentation lane after full-app quality, memory-pressure, and packaging gates; it is not P0.

## Can the shipping encoder accept shorter shapes?

No. Direct CoreML predictions against the installed, pinned bundles prove the compiled contracts are static:

- Preprocessor accepted only `[1, 240000]`; `[1, 16000]`, `[1, 48000]`, `[1, 80000]`, and `[1, 160000]` were rejected.
- Encoder accepted only `[1, 128, 1501]`; frame counts 101, 301, 501, and 1001 were rejected.
- Encoder output is fixed `[1, 1024, 188]`.
- Decoder is autoregressive U=1 with states `[2, 1, 640]`; JointDecision is a fixed single-step graph.

The exact Mobius exporter hardcodes `max_audio_seconds=15.0`, requires 15 s trace audio, traces the encoder on the resulting `mel_ref`, and exports its exact shape. The conversion plan explicitly says to re-export when window size changes. Although the current preprocessor conversion source declares a waveform `RangeDim`, the distributed compiled preprocessor metadata says `hasShapeFlexibility=0` and runtime rejected every shorter input.

### Fixed 3/5/10/15 s re-export

It should be possible **without retraining** because the NeMo encoder wrapper already passes an explicit length and the same learned weights can be traced at shorter valid shapes. It is not yet safe to ship: the local environment lacks torch/coremltools/NeMo, so no re-export or numerical/WER validation was performed.

Required gate:

1. Parameterize trace length and regenerate preprocessor/encoder from the original `.nemo` checkpoint with identical conversion, 6-bit palettization, and deployment target.
2. Compare PyTorch versus CoreML numerical outputs, token/duration/state parity, timestamps, seam behavior, and normalization at each bucket.
3. Run multilingual WER/CER plus dictation term/mixed-language tests and balanced cold/warm p50/p95/p99 timing on each hardware class.
4. Validate ANE residency; flexible shapes can change CoreML partitioning/specialization.
5. Solve storage sharing before shipping multiple copies: the encoder is 425 MiB, so naive 3/5/10/15 bundles add roughly 1.275 GiB beyond the existing encoder. Start with a 5/15 experiment or investigate CoreML multifunction/shared-weight packaging.

The maximum theoretical product-path gain is small relative to P0: the entire 15 s encoder is only 25.6 ms out of the approximately 120 ms shipping-vocabulary path. Even deleting it completely caps speedup near 1.27x, and a shorter bucket saves only part of that. If CTC/prefilter remains the critical path, the user-visible gain may be zero. Re-export is therefore a measured P2 experiment after vocabulary scheduling/profiling, not the first fix.

## Decoder/joint batching, fusion, and projection hoisting

Direct pinned-model component timing:

| Component | CPU | GPU | NE | `.all` |
|---|---:|---:|---:|---:|
| Encoder p50/p95, n=40 | 98.44 / 104.83 ms | 87.74 / 89.29 ms | 25.63 / 26.26 ms | 25.60 / 26.30 ms |
| Decoder p50/p95, n=300 | 0.158 / 0.175 ms | 0.157 / 0.168 ms | 0.158 / 0.179 ms | 0.165 / 0.177 ms |
| Joint p50/p95, n=300 | 0.181 / 0.204 ms | 0.175 / 0.196 ms | 0.177 / 0.194 ms | 0.180 / 0.201 ms |

Compute-unit placement is decisive only for the encoder. Decoder/joint placement is noise-scale because the 2-layer LSTM has no ANE kernel and the tiny autoregressive calls are dispatch/CPU bound.

Mobius' existing exact experiment is the appropriate guide:

- fp16 fused decoder+JointDecision: 0.482 ms separate versus 0.382 ms fused per step, 1.26x;
- representative 7.8 s utterance: 20.94 ms separate versus 18.90 ms fused, only about 2.0 ms saved;
- token, duration, and LSTM state parity were exact; top-k logits max absolute difference was about `7.3e-4`;
- fp32 fused regressed badly on GPU/`.all`; only fp16 is a candidate.

That is roughly 1–2% of the measured 120 ms shipping path. It is a valid later optimization, not a showstopper fix.

transcribe.cpp contains one useful idea not present in the current CoreML split: it precomputes `enc_w @ all_encoder_frames + bias` once as a real GEMM, then feeds projected frames to the per-step joint. The CoreML JointDecision graph receives a raw encoder step and repeats the encoder projection each joint call. A batched encoder-projection prepass plus a slimmer per-step joint is a plausible few-millisecond experiment, subject to export/parity/timing gates.

Full decoder/joint batching within one utterance is invalid because token choice and LSTM state are autoregressive. transcribe.cpp's offline multi-utterance encoder batching with variable-length masks is useful for future multi-file transcription throughput, not single dictation latency. It should not influence the core dictation default.

## Cross-hardware adaptive backend architecture

Static SoC matrices are brittle. FluidAudio's pinned documentation reports GPU 17.8 ms versus ANE 23.5 ms on an unspecified M-series Mac, while the exact OpenRamble bundle on this M4 measured GPU 87.74 ms versus ANE 25.63 ms. The difference can arise from chip, OS/CoreML build, model conversion, specialization cache, and concurrent product workload. Model-level `.all` alone also cannot see product-level CTC/window contention.

Recommended policy:

1. **Portable fallback:** `.all`; primary worker loads and performs a representative inference before `Ready`.
2. **Calibration timing:** after model install/update, or deferred until idle if the user can start recording immediately. Never calibrate on stop-to-text.
3. **Sequential ephemeral candidates:** `.all`, explicit NE, explicit GPU; never keep all three 461 MiB model graphs resident.
4. **Measure product scenarios:** one short TDT encoder; TDT concurrent with CTC; two simultaneous 15 s windows; one transcript-parity fixture. Three warmups and about nine measured runs are enough for a local selector, but record cold load separately.
5. **Score tails:** prefer full-pipeline p95/max, not isolated encoder p50. Require a material GPU margin (for example >15%) and no multi-window/CTC regression before choosing it. Ties favor `.all`/NE for energy and contention.
6. **Cache key:** hardware model and chip string (never serial/UUID), physical-memory tier, macOS product version and exact build, app/worker ASR ABI, FluidAudio commit, exact model-manifest hash, vocabulary model hash/scheduler version, and calibration-algorithm version.
7. **Cache value:** winner, candidate cold/warm samples, transcript parity, timestamp, failure counts. Write atomically; ignore corrupt/stale entries.
8. **Transient state:** low-power mode, thermal state, and memory pressure are not identity keys. Do not calibrate under serious/critical thermal or memory pressure.
9. **Runtime fallback:** do not switch during a dictation. On worker timeout/crash/CoreML error, preserve WAV, restart once on the cached placement, then try the next known-good candidate; session-blacklist a failing backend with cooldown. CPU-only is final recovery, not default.
10. **Drift:** collect only local latency/status telemetry, never audio/text. Several consecutive warm tail violations under normal pressure should schedule idle recalibration, not mutate the active session.

Physical M1/M2/M3 hardware was not available in this task. The adaptive design is the honest portability answer until the same matrix is executed on those machines.

## Ranked options

1. **P0, ship:** persistent worker, model + vocabulary prewarm before true `Ready`, WAV preservation/retry, and `.all` portable fallback. This removes the 14 s cold-path class from stop-to-text.
2. **P0, ship after parity tests:** make `candidateRegions` candidate-first for short audio; do not speculatively execute CTC on every dictation. Measured 13.7–40.2% p50 reduction with identical output hashes.
3. **P0/P1:** cache and bound the lexical candidate prefilter; remove its roughly 17 ms plain-speech floor without changing candidate semantics.
4. **P1:** sequential per-host full-pipeline placement calibration/cache. On the measured M4, `.all`/NE wins; do not ship the current hardcoded GPU default.
5. **P2 experiment:** fixed 5/15 s CoreML encoders only after stage-timeline proof, re-export/parity/WER gates, and a shared-weight/storage solution. Expected gain is bounded well below 1.27x.
6. **P2:** fp16 decoder+joint fusion and batched encoder-projection hoisting; expect a few milliseconds, not a step-function improvement.
7. **Optional recovery/research only:** transcribe.cpp private worker. Technically and legally feasible with notices/CC BY attribution, but not justified as the primary backend by speed, vocabulary quality, memory, or long-form results.

Do not pursue: existing dynamic input (runtime rejects it), decoder-on-ANE work, full autoregressive batching, a C++ rewrite solely for language overhead, a static M-series routing table, or a 10x marketing claim without cross-device end-to-end evidence.

## Reproducible artifacts

- CoreML shape probe: `/tmp/openramble-short-engine.SpfSeY/coreml_shape_probe.swift`; output `coreml-shape-probe-2026-08-14.txt`.
- Component placement probe: `/tmp/openramble-short-engine.SpfSeY/coreml_stage_bench.swift`; output `coreml-stage-bench-2026-08-14.txt`.
- NE/GPU shipping-vocabulary reports: `placement-ab/report.json`, `placement-ab-fleurs/report.json`.
- `.all`/NE/GPU balanced report: `placement-ab-all/report.json`.
- Fresh-process/cache-warm report: `process-cold-ab/report.json`.
- Candidate-first prototype runner/report: `run_candidate_only_ab.py`, `candidate-only-prototype/report.json`.
- Exact Handy backend runner/report: `run_handy_backend_proxy.py`, `handy-backend-proxy-ab/report.json`.
- Native RSS probe: `handy-backend-proxy-ab/rss-probe.txt` and `.json`.
- Boundary fixture generator: `make_boundary_wav.swift`; WAVs under `boundaries/`.
- Exact local checkouts: `handy/`, `transcribe-0.1.3/`, `mobius/`, `parakeet-coreml-model/`.

All paths above are under `/tmp/openramble-short-engine.SpfSeY` unless otherwise stated.

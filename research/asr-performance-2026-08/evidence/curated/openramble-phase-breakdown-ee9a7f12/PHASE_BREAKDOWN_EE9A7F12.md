# TEMP-only `manager.transcribe` phase profile — FluidAudio `ee9a7f12`

## Verdict

- On shipping 15 s fixed-shape inference, the only component large enough for a theoretical >=10% E2E gain is Core ML itself: encoder is 56.7–68.7% of warm p50, and decoder+joint predictions are 25.5–38.1%.
- There is no measured semantics-neutral Swift/code-level hotspot with >=10% E2E potential. Padding+input copy is 0.052–0.060 ms p50, preprocessor Core ML is 1.313–1.348 ms, TDT Swift residual is 0.571–0.797 ms, and top-level orchestration residual is 0.022–0.024 ms.
- A full Decoder/Joint 4×4 compute-placement smoke and selected n=20 confirmation did not demonstrate dispatch-tax savings outside ordinary run-to-run drift. Keep shipping `.all`; do not integrate a placement override.
- A static 7.5 s frontend cuts warm p50 by 32.6–37.7% on these short fixtures, but 14.28–14.84 ms of the 14.35–15.65 ms total delta is encoder Core ML. The 15 s padding+preprocessor penalty is only 0.535–0.600 ms. This is diagnostic evidence, not a product recommendation; the broader universal-short experiment already failed long-form acceptance, and token timestamps/confidences are not exact shape parity.

## Exact scope and configuration

- Application HEAD inspected: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`.
- FluidAudio base: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`, detached clean clone before TEMP changes.
- Host: Mac mini `Mac16,10`, Apple M4 10-core, 16 GB; macOS 26.4 (25E246), Darwin 25.4.0.
- Shipping graph: 15 s fixed-shape bundle, directory SHA-256 `d6c10d2a84ba889b9f6c118eef0e71f5336396cc435d0db1c020894ad9127cdd`, 483,105,645 logical bytes.
- Short diagnostic graph: 7.5 s static bundle, directory SHA-256 `88cd15a94f5242ec6d77c1427c04c5b6b980c262b9eeaab66140ad4551896d18`, 479,378,971 logical bytes.
- `MLModelConfiguration.computeUnits = .all`; encoder override `.all`; preprocessor remains FluidAudio's hard-coded `.cpuOnly`; shipping Decoder/Joint `.all`.
- `melChunkContext=false`, `parallelChunkConcurrency=4`, `TdtConfig(maxTokensPerChunk: 600)`, `dualDecodeArbitration=false`.
- Post-reset path is the current `returnArray(..., resetData: false)`. No 240,000-float return-time zero fill is included.
- Per-fixture language hint is `en` or `ru`, matching the frozen manifest.
- One model/manager per process, samples decoded before model load, five warmups per fixture, n=60 measured calls per fixture. Each call creates a fresh `TdtDecoderState`; the manager and Core ML models stay resident.
- `p50` is the mean of the two middle sorted values; `p95` is nearest-rank `ceil(0.95*n)-1`.

## Frozen real fixtures

| Fixture | Duration | Source SHA-256 |
|---|---:|---|
| LibriSpeech test-other | 7.06 s | `0ef932371d181b185f01b2ede213ebe649650457e5781d8e428f831dfbbe5343` |
| VOiCES room | 3.40 s | `c65fcd726d6b08c82c1e5dc7558f863cd8d483e3ed2f4a7bcf271dc1865ada14` |
| FLEURS ru validation 1 | 7.44 s | `363087f90513f5484750d8076da3cf7d029065d6b09f7ea68170bcf10b487d27` |
| FLEURS ru validation 6 | 4.80 s | `de6c6c691caf96369381f26aa204c4455d8f7c625dec017b634f9ff25833211f` |

All four hashes matched the manifest on every process launch.

## Shipping 15 s phase profile, warm n=60 (milliseconds, p50/p95)

| Fixture | E2E | align+pad+input memcpy | preprocessor Core ML | encoder Core ML | TDT total | decoder Core ML | joint Core ML | TDT Swift residual | orchestration residual |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| LibriSpeech | 45.949/50.043 | 0.060/0.067 | 1.316/1.366 | 26.318/29.933 | 18.329/18.832 | 7.273/7.404 | 10.269/10.632 | 0.797/0.841 | 0.024/0.026 |
| VOiCES | 38.036/41.177 | 0.058/0.062 | 1.313/1.359 | 26.135/28.395 | 10.357/11.354 | 3.811/4.131 | 5.974/6.626 | 0.571/0.617 | 0.022/0.027 |
| FLEURS ru 1 | 46.907/47.646 | 0.052/0.055 | 1.348/1.382 | 26.617/26.957 | 18.792/19.292 | 6.808/6.903 | 11.207/11.576 | 0.789/0.813 | 0.023/0.024 |
| FLEURS ru 6 | 45.761/46.470 | 0.054/0.057 | 1.323/1.374 | 26.424/26.891 | 17.826/18.148 | 7.027/7.111 | 10.047/10.300 | 0.760/0.780 | 0.022/0.026 |

The partition is exclusive at the outer level. `orchestration residual = harness wall - alignment/padding - preprocessor input - preprocessor prediction - encoder input bridge - encoder prediction - output extraction - TDT - cache return - result processing`. Encoder input bridge plus output extraction is about 0.006–0.007 ms p50; cache return is 0.0016–0.0019 ms; result processing is 0.044–0.057 ms.

TDT Swift residual is `TDT total - exact decoder model.prediction walls - exact joint model.prediction walls`; it therefore includes provider creation, frame copies/prefetch, output reads, token logic, and small tensor allocations.

## Exact TDT counts (stable across all 60 measured calls)

| Fixture | windows | actual/encoder/effective frames | decoder predictions | joint predictions | decoder cache hits | main/inner/final joint decisions | blank/nonblank | emitted tokens | duration advances |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| LibriSpeech | 1 | 89/90/89 | 29 | 38 | 34 | 29/4/5 | 9/29 | 28 | 94 |
| VOiCES | 1 | 43/44/43 | 15 | 23 | 22 | 14/1/8 | 8/15 | 14 | 55 |
| FLEURS ru 1 | 1 | 93/94/93 | 27 | 43 | 32 | 27/11/5 | 17/26 | 26 | 102 |
| FLEURS ru 6 | 1 | 60/61/60 | 28 | 37 | 33 | 28/4/5 | 10/27 | 27 | 70 |

Invariants held on every call: `joint predictions == main + inner + final` and `joint predictions == blank + nonblank`. No fixture entered `ChunkProcessor`; each is the direct one-window branch of `transcribeWithState`.

## Fixed-shape 15 s cost versus static 7.5 s

The comparison below uses the same final diagnostic binary and `.all/.all` placement, n=60 per form. Values are p50.

| Fixture | E2E 15→7.5 | E2E gain | pad+preprocessor 15→7.5 | frontend gain | encoder 15→7.5 | encoder gain |
|---|---:|---:|---:|---:|---:|---:|
| LibriSpeech | 45.949→30.992 ms | 14.958 ms (32.6%) | 1.376→0.809 ms | 0.567 ms | 26.318→11.794 ms | 14.524 ms |
| VOiCES | 38.036→23.690 ms | 14.347 ms (37.7%) | 1.371→0.835 ms | 0.535 ms | 26.135→11.855 ms | 14.280 ms |
| FLEURS ru 1 | 46.907→31.255 ms | 15.652 ms (33.4%) | 1.400→0.800 ms | 0.600 ms | 26.617→11.774 ms | 14.844 ms |
| FLEURS ru 6 | 45.761→30.177 ms | 15.584 ms (34.1%) | 1.378→0.801 ms | 0.577 ms | 26.424→11.765 ms | 14.660 ms |

Only roughly 0.02–0.03 ms of the frontend delta is Swift padding/input copy; roughly 0.54–0.58 ms is preprocessor Core ML. Two later short-form repetitions had sporadic p95 stalls despite no competing ASR runner and no recorded macOS thermal/performance warning, so short p95 is not used to claim a product tail improvement. The p50s reproduced within about 0.25–0.90 ms.

## Decoder/Joint component placement

TEMP loader overrides independently tested each of `.all`, `.cpuOnly`, `.cpuAndGPU`, and `.cpuAndNeuralEngine` for Decoder and Joint. Encoder remained `.all`; preprocessor remained `.cpuOnly`.

1. Full 4×4 smoke: 3 warmups + n=3, 16 processes/combinations. All 16 had stable exact transcripts, exact token IDs, and the same decoder/joint/main/inner/final call counts on all four fixtures.
2. Confirmation: 3 warmups + n=20 for baseline twice and four promising/control combinations.

| Placement | Mean of four fixture p50s |
|---|---:|
| baseline `.all/.all` A | 43.663 ms |
| Joint `.cpuOnly`, Decoder `.all` | 44.068 ms |
| Joint `.cpuAndGPU`, Decoder `.all` | 44.287 ms |
| Decoder `.cpuOnly`, Joint `.cpuAndNeuralEngine` | 44.175 ms |
| Decoder `.cpuOnly`, Joint `.all` | 44.523 ms |
| baseline `.all/.all` B | 44.553 ms |

The two baselines span 0.890 ms (~2.0%), and every candidate lies inside that bracket. There is no evidence of a stable dispatch-tax win, much less >=10% E2E. First-load numbers are order/cache-confounded across placements and are not used for the verdict.

## Parity and stability

- Within shipping 15 s: all four transcripts and complete `TokenTiming` hashes were stable over n=60.
- Within static 7.5 s: all four transcripts and complete `TokenTiming` hashes were stable over n=60.
- Across 15 s and 7.5 s: exact transcript and token-ID parity is 4/4. Timestamp parity is exact on 1/4; the other three shift by at most 80 ms at token starts and 160 ms at token ends. Maximum token-confidence absolute delta is 0.108. Therefore shape parity is lexical, not exact timing/confidence parity.
- Across every placement run: exact transcript, token-ID, and call-count parity is 4/4.

Transcript SHA-256 values:

- LibriSpeech: `de779a17ef1f131e54fff2c068b2dd146c6fbee92d471e37b32ad27fa969b70f`
- VOiCES: `3a4531980d66676f383e36269a847e2a037dbb2ca4b5255f35ceb09d518b2268`
- FLEURS ru 1: `316fbcba203437b57c0bc88e5bc925e3712ac80ecff77d2517e8223fa3d548bd`
- FLEURS ru 6: `7fc4182a756bd6e07183fc11c53110c14081922cd574f3e3983e0a6d6c3cbd7d`

## Process-first cost and RSS (compiled artifacts already present)

Final shipping run: model load 100.073 ms, manager load 0.022 ms, first inference 59.061 ms. `ru_maxrss` was 13,320,192 bytes at start, 40,943,616 after model load, 82,100,224 after first inference, and 85,032,960 at end. These are process-first numbers with existing `.mlmodelc` and OS/Core ML caches, not a disk-cold specialization measurement.

## Artifacts and hashes

- Temp root: `$TMP/openramble-phase-breakdown-ee9a7f12`
- Combined TEMP FluidAudio patch SHA-256 (tracked binary diff plus new diagnostic file): `26504239ec3495ce1cca2d82ddb5aba432441aded24b4933a3afe74a4f6e5da6`
- Final `phase-bench` binary SHA-256: `db6aed3be6c3521db3b695e2b5536a7d32bea87a82c1f9f8d33c4fbafc5b1049`
- Harness source SHA-256: `630b864de22e5b399f49bf4c766ce787e8f8e7719124e986199586269d5e4087`
- Fixture manifest SHA-256: `5db758211089be4960fa484266e4fee80fa8c7aaf3f51671510eba171dbeeab5`
- Final shipping n=60 report SHA-256: `54753b5834d07ea14f12a3348d31cb9635c6a2ba2ce83076ac732e03f8a1214d`
- Final short n=60 repeat report SHA-256: `6704dfe9571dcd2ac8a872a9b6cd33f3c520481f1f8c3131d958d807681a8b1b`
- 16 placement-smoke reports combined tree SHA-256: `fb2ae84b25b6f785b38cd3f5437d4e45049985fb82223832d3748d3ad55c1bdc`
- 6 placement n=20 reports combined tree SHA-256: `6a67a14d6da5241348f4c8a99a261fe55f00fd68faa3c6609597a3d4efc6a8be`

No shared tracked file was edited. Final shared-repository `git status --short` was empty. At handoff, no OpenRamble, asr-bench, short-shape-bench, or phase-bench process was running; the Core ML runner/accelerator was free.

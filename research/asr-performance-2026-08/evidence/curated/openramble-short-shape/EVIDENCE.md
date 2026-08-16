# TEMP-only Parakeet TDT v3 short-shape evidence

Date: 2026-08-14 (Europe/Moscow)

## Verdict

- A fixed 7.5 s Core ML frontend is technically reproducible without retraining and remains shape-compatible with the shipping Decoder and Joint: `[1,120000] -> [1,128,751] -> [1,1024,94]`, encoder hidden size 1024.
- On this M4 host, the fixed 7.5 s frontend preserved exact transcripts on all four frozen real fixtures and reduced post-cache-reset warm TDT wall time by 32.3% to 39.9% at p50.
- This is not evidence for an M4-specific product default. It does not validate long-form chunk/merge behavior, >7.5 s utterances, macOS 14 execution, or M1/M2/M3 hardware.
- A single 7.5+15 s `EnumeratedShapes` frontend is not viable with this graph/toolchain. The vanilla graph fails prediction; the bounded broadcast rewrite runs but fails ANE compilation, falls back to a much slower path, consumes about 3.11 GB client peak RSS, and loses transcript parity on one fixture.
- A Core ML multi-function package is macOS 15/iOS 18 minimum. The bounded dedup attempt could not ingest the exact shipping 15 s source model under pinned `coremltools 9.0b1`; proceeding would require another full 15 s re-export and was intentionally stopped.

No tracked/shared repository file was modified. All scripts, models, and reports are under `$TMP/openramble-short-shape`.

## Pinned sources

- Installed/shipping FluidInference revision: `aed02740059203c4a87495924f685de3722ae9ce`
  - <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce>
- NVIDIA checkpoint revision: `1b6821cbe889fcf82347cb95c3f8f0c7515a60e9`
  - checkpoint: 2,509,332,480 bytes
  - SHA-256: `3cbdc85877e668ca7b82d0d56770eb1fac76691f55d6b97545e8d61ca588d10d`
  - <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/tree/1b6821cbe889fcf82347cb95c3f8f0c7515a60e9>
- Mobius converter revision: `d2398af6042684a1b06dbc6951bdb50e1cf0366a`
  - <https://github.com/FluidInference/mobius/tree/d2398af6042684a1b06dbc6951bdb50e1cf0366a/models/stt/parakeet-tdt-v3-0.6b/coreml>
- Runtime benchmark source: FluidAudio `19600a485baa4998812e4654b70d2bab8f2c9949`; temp-only window override plus post-reset `MLArrayCache` behavior.
- Frozen conversion environment from Mobius `uv.lock`: Python 3.10.12, torch 2.7.0, coremltools 9.0b1, nemo-toolkit 2.3.1, numpy 1.26.4.
- The downloaded shipping source weights match the installed compiled weights exactly:
  - Encoder: 445,187,200 bytes, SHA-256 `e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421`
  - Preprocessor: 491,072 bytes, SHA-256 `129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea`

Primary Apple reference for finite flexible shapes and specialization behavior:
<https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html>

## Host and benchmark method

- Mac model: `Mac16,10` (M4), 16 GiB RAM, 10 logical CPUs.
- macOS 26.4 build 25E246.
- OpenRamble was stopped to avoid Core ML contention.
- `MLComputeUnits.all` was requested for encoder/runtime; the preprocessor remains CPU-pinned by FluidAudio. Core ML does not expose definitive accelerator placement through this harness, so static ANE placement is not claimed.
- No thermal or performance warning was reported by `pmset -g therm` before or after.
- Main result uses the already-integrated cache behavior (`returnArray` does not zero a buffer that callers completely overwrite). Earlier pre-reset runs are retained in the reports directory but are not used for the main delta.
- Three alternating fresh processes per variant; each process used 6 warmups and 20 timed calls per fixture. Total `n=60` timed calls per fixture per variant.
- p50 is the median. p95 is nearest-rank (`ceil(0.95*n)`). Timed region is `AsrManager.transcribe` (TDT path only), not OpenRamble outer orchestration.

## Frozen real fixtures and transcript parity

| Fixture | Duration | Source SHA-256 | Exact baseline/short transcript |
|---|---:|---|---|
| LibriSpeech test-other | 7.06 s | `0ef932371d181b185f01b2ede213ebe649650457e5781d8e428f831dfbbe5343` | `I really was very much afraid of showing him how much shocked I was at some parts of what he said` |
| VOiCES room | 3.40 s | `c65fcd726d6b08c82c1e5dc7558f863cd8d483e3ed2f4a7bcf271dc1865ada14` | `I had that curiosity beside me at this moment.` |
| FLEURS RU validation 1 | 7.44 s | `363087f90513f5484750d8076da3cf7d029065d6b09f7ea68170bcf10b487d27` | `Он сказал, что создал дверной звонок, работающий от вай-фай.` |
| FLEURS RU validation 6 | 4.80 s | `de6c6c691caf96369381f26aa204c4455d8f7c625dec017b634f9ff25833211f` | `О первых случаях заболевания в этом сезоне было сообщено в июле.` |

All 60 timed calls per fixture were internally stable. Baseline versus static 7.5 s exact transcript parity: 4/4.

## M4 warm latency after cache-reset parity

| Fixture | Shipping 15 s p50 / p95 | Static 7.5 s p50 / p95 | p50 / p95 delta |
|---|---:|---:|---:|
| LibriSpeech | 45.458 / 45.762 ms | 30.796 / 31.383 ms | -32.25% / -31.42% |
| VOiCES | 38.097 / 38.998 ms | 22.886 / 23.133 ms | -39.93% / -40.68% |
| FLEURS RU 1 | 47.363 / 47.922 ms | 31.318 / 31.623 ms | -33.88% / -34.01% |
| FLEURS RU 6 | 45.987 / 46.651 ms | 30.336 / 30.610 ms | -34.03% / -34.39% |

## Exact compiled bundle bytes

Logical bytes are the sum of file lengths. Allocated bytes are `st_blocks * 512` and may not reflect APFS clone sharing.

| Bundle | Logical bytes | Allocated bytes | Change vs shipping |
|---|---:|---:|---:|
| Shipping fixed 15 s | 483,105,645 | 483,151,872 | baseline |
| Static fixed 7.5 s replacement | 479,378,971 | 479,424,512 | -3,726,674 bytes (-0.771%) |
| 7.5+15 s EnumeratedShapes, broadcast experiment | 502,531,692 | 502,575,104 | +19,426,047 bytes (+4.02%) |
| Separate shipping 15 s plus static 7.5 s frontends, shared Decoder/Joint/vocab | 926,052,412 | not measured as a standalone directory | +442,946,767 bytes (+91.687%) |

Static 7.5 s compiled components:

- Encoder: 442,524,123 logical bytes
  - weight: 441,721,984 bytes
  - weight SHA-256: `f6478a6803e356b0d402ad88a83fae7a46f9c1e99d08c1f581d27842e954e221`
- Preprocessor: 422,644 logical bytes
  - weight: 395,072 bytes
  - weight SHA-256: `eb2412006697c8d82acf748f428dfdab37bdbe91141417a7fd6e6d6262194094`
- Shipping Decoder and Joint were copied unchanged:
  - Decoder weight SHA-256: `48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41`
  - JointDecisionv3 weight SHA-256: `4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e`
  - vocabulary SHA-256: `7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735`

## Build, compile, load, specialization, and RSS

Static 7.5 s export metadata:

- checkpoint restore: 10.845 s
- preprocessor trace / convert / int8 quantize: 0.119 / 0.551 / 0.156 s
- encoder trace / convert / 6-bit k-means palettize: 3.266 / 26.158 / 113.126 s
- total export: 156.419 s
- fresh `coremlcompiler` wall: preprocessor 0.08 s; encoder 0.24 s
- metadata SHA-256: `786b5f060557d18eb9fd47c12320094afbb732f5d335d839f8acca2a6cd73180`

Observed first process load after the app was stopped (not a cleared system Core ML cache):

- shipping: 13.482 s
- static 7.5 s: 12.692 s (-0.791 s, -5.86%)

After system/content specialization had been cached, fresh-process load medians across the three post-reset runs were approximately 264 ms shipping and 224 ms short. First-inference timings were noisy and cache-state dependent (shipping 101.1/76.2/63.3 ms; short 83.4/73.8/48.5 ms), so warm distributions above are the decision-quality result.

One `/usr/bin/time -lp` post-reset run reported client-process maximum RSS:

- shipping: 85,262,336 bytes (81.31 MiB)
- static 7.5 s: 76,857,344 bytes (73.30 MiB)
- delta: -8,404,992 bytes (-9.86%)

This excludes memory owned by external Core ML services and must not be presented as total model resident memory.

## One-package experiments and blockers

### EnumeratedShapes (macOS 14-compatible format target)

The preprocessor accepts enumerated waveform shapes. The encoder produced invalid dynamic MIL from the unmodified NeMo graph:

`Failed to PropagateInputTensorShapes ... tile ... All values of reps must be at least 1`

The exact source is NeMo FastConformer `_create_masks`: `expand(..., -1)` and `repeat([1, max_audio_length, 1])`. A bounded temp monkeypatch replaced both with mathematically equivalent broadcasting. Both 7.5 and 15 shapes then compiled and ran, but Core ML emitted:

`MILCompilerForANE error: failed to compile ANE model using ANEF`

Observed behavior under `.all`:

- 7.5 s: roughly 241-246 ms warm smoke calls, first inference 427 ms, max RSS 3,108,569,088 bytes; LibriSpeech changed `parts` to `part` (parity 3/4).
- 15 s: roughly 416-423 ms warm smoke calls, first inference 699 ms, max RSS 3,108,438,016 bytes; parity 4/4.

Therefore this is not a usable ANE/shared-weight replacement.

### Multi-function package

`coremltools.utils.save_multifunction` deduplicates constants across functions, but the local primary implementation forces specification version iOS 18, hence macOS 15 minimum (`coremltools/models/utils.py`). It cannot be a universal macOS 14 replacement.

The bounded attempt combined the exact static 7.5 source with the exact pinned FluidInference 15 s source. `coremltools 9.0b1` failed while importing the shipping encoder:

`ValueError: Unknown input 'shape' for op 'constexpr_lut_to_dense'`

Materializing two static functions from the flexible source also failed in the preprocessor pass:

`ValueError: Incompatible dim 1 in shapes (1, 239999) vs. (1, 119999)`

No multi-function artifact was emitted. A further retry would require a full 15 s re-export under the same patched toolchain, would still have the macOS 15 floor, and was outside the bounded acceptance rule.

## Reproducibility paths

- Static bundle: `$TMP/openramble-short-shape/model-root-7.5/parakeet-tdt-0.6b-v3`
- Static source packages and metadata: `$TMP/openramble-short-shape/export-7.5s`
- Exporter: `$TMP/openramble-short-shape/short_export.py`
- Harness: `$TMP/openramble-short-shape/harness`
- Frozen manifest: `$TMP/openramble-fair-n50-manifest.json`
  - SHA-256: `0659a540b1dddbca4f66b7c5acc95e17bc522c718a391c5a3fe0004e9c89086e`
- Main raw reports: `$TMP/openramble-short-shape/reports/*postreset*.json`
- Failed/no-go enumerated artifacts remain under `$TMP/openramble-short-shape/export-enum*` and `$TMP/openramble-short-shape/model-root-enum*` for inspection.

## Product implication

The fixed 7.5 s result justifies a guarded multi-bucket experiment, not a default switch. A product implementation still needs:

1. selection and fallback semantics for utterances near and above bucket boundaries;
2. long-form chunk/merge regression tests;
3. a download strategy, because a separate 7.5 s frontend adds about 422.43 MiB despite nearly identical neural weights;
4. M1/M2/M3/M4 and supported macOS hardware validation, including actual compute-unit placement and specialization disk/RSS;
5. substantially broader English/Russian quality and boundary parity coverage.

The 3.75 s bucket was not exported; the requested minimum 7.5 s bucket was completed.

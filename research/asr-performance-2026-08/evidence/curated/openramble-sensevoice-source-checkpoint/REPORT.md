# SenseVoiceSmall int8 source/CPU checkpoint

Date: 2026-08-14
Decision: **HARD NO as an English+Russian OpenRamble replacement or normal router. Do not request a model run.**

This is a static capability rejection, not a measured quality rejection. No model weights were downloaded, no `MLModel` was loaded, and no CoreML inference was run.

## Why the candidate is already falsified

The released SenseVoiceSmall checkpoint is a five-language ASR model: Mandarin, Cantonese, English, Japanese, and Korean. The official paper distinguishes Small's five languages from Large's 50+ languages. The current upstream repository now makes the same distinction explicitly. The pinned runtime language map has `auto`, `zh`, `en`, `yue`, `ja`, `ko`, and `nospeech`; it has no Russian input.

The converted CoreML vocabulary contains 105 language-like metadata tags, including `<|ru|>`, but contains zero Cyrillic output pieces and zero byte-fallback pieces. A metadata tag is therefore not Russian transcription support: this decoder cannot spell a Cyrillic transcript. The released tokenizer name itself is `chn_jpn_yue_eng_ko_spectok.bpe.model`.

The current Fluid CoreML wrapper further returns only `String`. It greedily decodes CTC, removes every `<|...|>` tag, and discards language, emotion/event, token IDs, frame positions, logits, timing, and confidence. It has no vocabulary or hotword API. Consequently it cannot preserve shipping `candidateRegions`, token/word timing, or confidence semantics even for English.

These facts independently fail the frozen gates:

- Russian hypotheses without Cyrillic: required 0; statically unavoidable for every non-empty Russian transcript.
- Missing word timings and confidence: required 0; current public result always omits both.
- Vocabulary candidate false negatives: required 0; current API has no candidate-region vocabulary path.

Running the model cannot repair these API/model capability failures, so it would only spend network, disk, and CoreML time after the decision is known.

## Exact pins

| Component | Exact identity |
|---|---|
| OpenRamble baseline | `f2b6e8cc66d20f7a07094f79af0faf3ba861af64` |
| Fluid fork dependency | `mikwiseman/FluidAudio@ee9a7f12d91710da53de6d75f8b7160e09eccee4` |
| Fluid upstream tag ancestry | `v0.15.5@19600a485baa4998812e4654b70d2bab8f2c9949` |
| SenseVoice subtree at both Fluid revisions | Git tree `97d7b4a569390fc7a1baae947e6b7f27e0c8c331` |
| CoreML conversion | `FluidInference/sensevoice-small-coreml@cdea3526163035c19915d4a10268992d018ebd46` |
| Upstream checkpoint audited | `FunAudioLLM/SenseVoiceSmall@3847d57b6bdf2dd8875cb1508d2af43d80a16bf7` |
| Upstream source audited | `QwenAudio/SenseVoice@b054623cca8f015b73ec471dce4f473ac47413da` |
| FunASR model-license text audited | `modelscope/FunASR@2e4914e7f9e0950e47eeb831675d6167a51d0632` |
| Shipping model | revision `aed02740059203c4a87495924f685de3722ae9ce`, 483,105,645 bytes |
| Shipping vocabulary | revision `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`, 102,803,869 bytes |
| Shipping product config | SHA-256 `98338d07767b45d3abaf222a790b6070b4a0dae6291343034cd7b91f16f3c59b` |

The exact nine-file int8 manifest is `MODEL_ARTIFACTS.json`, SHA-256 `d0a99130a53b09b6756b1203eb057d197608f278913f7aace3ce1a71b00e7906`. It totals 239,913,642 bytes (228.80 MiB). File sizes and SHA-256 values came from pinned Hugging Face metadata; weight files were not downloaded. The probe binary hard-codes this manifest hash and rejects any replacement before model load.

The CoreML conversion card does not pin the exact source `model.pt` revision/hash from which the conversion was built. We can pin the converted artifacts, but cannot reconstruct a cryptographic conversion lineage to upstream. That is a P0 provenance gap for redistribution.

## Input-length finding

Fluid's host config describes a largest 1,800-frame encoder bucket as roughly 108 seconds and truncates features above it. The pinned compiled preprocessor is stricter: its MIL `RangeDim` accepts waveform shape `[1, 3200...480000]`, or only 0.2–30.0 seconds at 16 kHz. The manager does not chunk longer input before this prediction. More-than-30-second input therefore fails at the preprocessor boundary; a five-minute take is unsupported.

The sealed diagnostic probe enforces 3,200...480,000 samples before inference so this mismatch fails closed rather than relying on CoreML validation.

## Product-semantics gap map

| Requirement | Pinned SenseVoice CoreML path | Product consequence |
|---|---|---|
| English ASR | Explicit raw language embed index `4`; auto index `0` | Potentially testable for short explicit-English clips only |
| Russian ASR | No released support, no runtime RU index, no Cyrillic/byte output pieces | Hard reject |
| Language hint | Raw `Int32`; no public BCP-47 validation/map | Adapter must reject unsupported hints before inference |
| Detected language | Meta output is stripped | Cannot preserve product result |
| Token/word timestamps | No Fluid output; CTC frame sequence discarded | Cannot preserve product result |
| Confidence | Logits and token scores discarded | Cannot preserve product result |
| Developer vocabulary | No hotword/candidateRegions input or fusion | Cannot preserve shipping vocabulary semantics |
| Long recordings | Compiled preprocessor max 30 s; no long-form chunker | Not a dictation replacement |
| Cancellation | Synchronous CoreML prediction calls | No proof of prompt native cancellation |
| Offline/privacy | Safe only through verified local install + `ModelHub.offlineMode=true` + `SenseVoiceModels.load(from:)` | Never call default `SenseVoiceManager.load()` in product |
| macOS support | Package declares macOS 14/iOS 17; int8 encoder requests CPU+ANE; preprocessor CPU-only | Declaration is not M1/macOS14 qualification evidence |
| Fallback | fp32 requests `.all`, is a different 944,421,839-byte artifact route | Never silently substitute it for int8 |

## Network and privacy surface

The normal Fluid loader uses `ModelHub.download` and mutable `main` URLs:

- `https://huggingface.co/api/models/{repo}/tree/main...`
- `https://huggingface.co/{repo}/resolve/main/{path}`

It observes registry, authentication, proxy, and Hugging Face token environment variables; redirects may involve Hugging Face LFS/Xet hosts. This is not a reproducible product installer.

The only acceptable diagnostic flow is:

1. Download the nine paths from the exact `cdea352...` revision into a new staging directory.
2. Verify every byte count and SHA-256; atomically publish the directory.
3. Consume a mode-0600 one-use authorization token before any CoreML-capable call.
4. Set Fluid offline mode and an invalid localhost registry.
5. Call only `SenseVoiceModels.load(from:precision:.int8)`.

The sealed downloader implements steps 1–2 but is inert without an explicit GO environment value. It was syntax/guard tested only and was not run.

## License surface

- Fluid source: Apache-2.0, pinned text SHA-256 `c71d239d...`.
- SenseVoice source: MIT, pinned text SHA-256 `4bc3bffe...`.
- SenseVoiceSmall weights: FunASR Model Open Source License Agreement v1.1, pinned text SHA-256 `7dba975a...`.

The model license is not a standard SPDX permissive license. It includes attribution/source/model-name retention requirements and unusual conduct/revision language. Legal approval is required before bundling or distributing any derived CoreML artifact. The conversion card's `license: other` / `sensevoice-upstream` metadata does not remove this obligation.

## Frozen tiny smoke

`TINY_SMOKE_PREREG.json` seals four real fixtures before candidate inference:

- 2 English: LibriSpeech 7.06 s, VOiCES 3.40 s.
- 2 Russian: FLEURS 7.44 s and 4.80 s.
- Source manifest SHA-256: `1143305176fc436795395019f0051d8db8670d691f7c6470a81f4d872b79470c`.
- Candidate sequence: verify all four source hashes/sample counts before load; load; prewarm; 16 measured requests (two forward passes and two reverse passes); shutdown/reap.
- Shipping sequence remains the pinned production path with the frozen 28-term vocabulary and per-fixture hints.

Hard gates include zero empty/error outputs, zero Russian outputs lacking Cyrillic, zero missing timings/confidence, zero vocabulary false negatives, no more than +0.01 observed WER per language, candidate/shipping warm p95 ratio at most 0.8, max ratio at most 1.0, RSS at most 1 GiB, zero swap growth, normal pressure, and clean reap.

The smoke is sealed but blocked. A pass would be diagnostic only; it cannot override the static source capability rejection.

## Frozen 204-fixture A/B

`CORPUS_204_PREREG.json` seals `openramble-dominant-short-quality-v1`:

- manifest SHA-256 `340314c63357f2ec0bcb4091438a71b43668ecba4ad376dc8844e9785d86faf6`;
- 204 real utterances, 102 English and 102 Russian;
- per language: 34 clips in each 1–2 s, 2–3 s, and 3–4 s bin;
- 547.184125 total audio seconds;
- paired, language/bin-stratified bootstrap with 20,000 iterations and frozen seed;
- no optional stopping, metric-driven reruns, or candidate outputs inspected.

Its exact quality, latency, resource, privacy, macOS14/M1, and lifecycle gates are in the JSON. Promotion is forbidden until a new versioned adapter/model closes every static blocker and the frozen tiny smoke passes. Therefore the 204 run is currently forbidden.

## Fallback policy

Eligibility must be decided before candidate inference. The only conceivable experimental subset is exact explicit-English, 3,200...480,000 samples, no vocabulary requirement, and a caller that explicitly accepts text-only output without language/timing/confidence. That is not the normal OpenRamble contract, so current safe product eligibility is effectively zero.

On a preflight mismatch, invoke shipping once without touching SenseVoice. On a candidate load/inference/empty-output failure in a diagnostic route, destroy the candidate generation and invoke shipping exactly once while reporting the full added latency. Never run both speculatively, never silently use fp32, and never adopt candidate output after a post-inference semantic check.

## Resource and run-cost estimate (not measured)

- Exact int8 download: 239,913,642 bytes (228.80 MiB).
- Ideal transfer time excluding TLS/redirect/disk overhead: 19.2 s at 100 Mbit/s, 76.8 s at 25 Mbit/s, 191.9 s at 10 Mbit/s.
- Installer requires at least 600 MB free for staging/margin.
- Shipping model + shipping vocabulary + candidate artifacts: 825,823,156 bytes (787.57 MiB), excluding compiled caches.
- Maximum host CTC logits allocation at the 1,800 bucket: about 180,796,880 bytes (172.42 MiB), before CoreML internal buffers/model pages.
- Conversion-card RSS figures are upstream claims, not evidence on this M4/macOS 26 host. The preregistered hard gate remains measured peak RSS ≤1 GiB with zero swap growth and normal pressure.
- Tiny audio totals 22.70 s; reserve <10 minutes including cold compile/load, symmetric repeats, trace setup, and teardown.
- One 204-corpus audio pass is 547.18 s. Even if the card's slowest claimed ~97× real-time held, candidate inference would be ~5.6 s/pass and four passes ~22.6 s; cold load, shipping baselines, tracing, hashing, and bootstrap dominate. Reserve 30 minutes. This estimate cannot be used as a latency result.

## Primary sources

- [Official paper: Small 5 languages vs Large 50+](https://arxiv.org/abs/2407.04051)
- [Pinned released SenseVoiceSmall checkpoint](https://huggingface.co/FunAudioLLM/SenseVoiceSmall/tree/3847d57b6bdf2dd8875cb1508d2af43d80a16bf7)
- [Pinned upstream source repository](https://github.com/QwenAudio/SenseVoice/tree/b054623cca8f015b73ec471dce4f473ac47413da)
- [Pinned Fluid SenseVoice manager](https://github.com/mikwiseman/FluidAudio/blob/ee9a7f12d91710da53de6d75f8b7160e09eccee4/Sources/FluidAudio/ASR/SenseVoice/SenseVoiceManager.swift)
- [Pinned Fluid SenseVoice models](https://github.com/mikwiseman/FluidAudio/blob/ee9a7f12d91710da53de6d75f8b7160e09eccee4/Sources/FluidAudio/ASR/SenseVoice/SenseVoiceModels.swift)
- [Pinned CoreML conversion](https://huggingface.co/FluidInference/sensevoice-small-coreml/tree/cdea3526163035c19915d4a10268992d018ebd46)

# Experiment and decision ledger

This ledger records both successful and unsuccessful work. Numbers are local
engineering evidence on one Apple M4 unless explicitly stated otherwise. They
are not public product claims.

## Decision vocabulary

- **Integrated**: committed to `perf/asr-phase-timing` and covered by tests.
- **Proven prototype**: result is real and reproducible, but production safety
  or product semantics are unresolved.
- **Rejected**: a preregistered or structural gate failed. Do not repeat without
  a new hypothesis.
- **Source-only candidate**: no model inference was authorized or run.
- **Inconclusive**: harness or resource instrumentation stopped before the
  candidate result existed.

## 1. Shipping hot-path work

### 1.1 Benchmark-only phase timing

**Status: Integrated.** Commit `027b61d`.

`ASRPhaseTimings` travels immutably with `ASRResult`. Collection defaults off
and is enabled only by `asr-bench serve-jsonl`. The JSON protocol remains v1;
the persisted report schema is v4. The timing object includes:

- primary TDT inference/decode;
- lexical candidate gating;
- summed CTC model-call wall time and invocation count;
- rescore/fusion through punctuation repair;
- vocabulary outcome;
- a scheduling flag warning that phases may overlap.

`elapsed_ns` remains the authoritative total. The runner rejects booleans as
integers, negative timings, outcome/phase contradictions, a CTC duration/count
mismatch, bad scopes, bad clocks, and old report schemas on resume.

Key evidence:

- `evidence/curated/openramble-phase-timing-m4-20260814.json`
- branch diff in `Packages/DictationCore`, `Packages/LocalASR`,
  `scripts/benchmark-local-asr.py`, and `docs/benchmarks.md`

### 1.2 Remove redundant fixed-input clearing

**Status: Integrated.** Commit `d49d63b`.

The cached 240,000-sample TDT input was cleared after each request even though
the next preprocessor call overwrites the whole buffer. The pinned fork now
skips the reset only for this fully overwritten path.

| Fixture | Before p50 | After p50 | Change |
|---|---:|---:|---:|
| LibriSpeech EN 7.06 s | 62.034 ms | 50.930 ms | -17.9% |
| VOiCES EN 3.53 s | 52.622 ms | 40.260 ms | -23.5% |
| FLEURS RU 7.44 s | 60.854 ms | 49.027 ms | -19.4% |
| FLEURS RU 3.40 s | 60.233 ms | 47.869 ms | -20.5% |
| Boundary 29.9 s | 144.997 ms | 127.410 ms | -12.1% |

All raw and normalized transcript hashes were unchanged.

### 1.3 Typed CTC tensor access

**Status: Integrated.** Commit `c4124b6`.

The optional vocabulary path wrote up to 240,000 Float16 samples and read about
188×1,025 logits through generic `MLMultiArray` subscripts, boxing every scalar
through `NSNumber`. The direct path uses contiguous/strided typed storage while
preserving the algorithm.

| Path | Before total p50 | After total p50 | Before CTC p50 | After CTC p50 |
|---|---:|---:|---:|---:|
| One CTC invocation | 210.403 ms | 120.285 ms | 101.989 ms | 11.399 ms |
| Two CTC invocations | 413.418 ms | 218.891 ms | 218.091 ms | 29.821 ms |

Float16/Float32, rank-3/rank-4, non-contiguous-stride, AddressSanitizer, and
ThreadSanitizer tests passed. Transcript hashes, outcome, and invocation counts
were unchanged.

### 1.4 Scope rescoring to candidate terms

**Status: Integrated.** Commit `f2b6e8c`.

The conservative lexical gate now returns the exact vocabulary term indices
that could pass. The final rescorer keeps the complete vocabulary for collision
and acoustic-rescue policy but avoids rebuilding/comparing unrelated forms.

- Total p50: 119.003 → 83.341 ms (-30.0%) against the typed-I/O baseline.
- Fusion p50: 37.499 → 2.099 ms.
- Original-before-both vs final: 212.013 → 84.477 ms (-60.2%).
- No-candidate control: 48.040 → 48.088 ms (+0.10%, noise).
- Every paired result kept identical transcript hashes, outcome, and CTC count.

Key evidence files are the archived `openramble-ctc-*.json` reports.

## 2. Fair Handy benchmark infrastructure

### 2.1 Persistent paired runner

**Status: Integrated infrastructure; public speed claim rejected.**

The runner uses persistent JSONL processes, canonical 16 kHz mono Float32 PCM,
balanced OH/HO order, frozen hashes, warmups, bootstrap confidence intervals,
resume identity, and no persisted plaintext transcripts. The Handy backend is a
locally patched pinned backend, not the official GUI app.

Fair n=50 evidence:

- 8 fixtures, 400 complete pairs, 800 observations;
- exactly 25 OH and 25 HO per fixture;
- thermal state nominal before/after;
- all four real fixtures had stable normalized outputs and matching WER;
- report marked `public_claim_eligible=false`.

Real-fixture Handy/OpenRamble p50 ratios:

| Fixture | Ratio | Bootstrap 95% CI |
|---|---:|---:|
| LibriSpeech EN | 1.8745× | [1.8530, 1.8981] |
| VOiCES EN | 1.5196× | [1.4580, 1.5551] |
| FLEURS RU long | 6.5982× | [1.9981, 7.2190] |
| FLEURS RU short | 4.9078× | [4.3927, 5.3316] |

Synthetic boundaries showed larger ratios but lacked frozen references and
often produced different transcripts. They are diagnostic only.

Evidence:

- `evidence/curated/openramble-fair-paired-n50-20260814.json`
- `evidence/curated/openramble-fair-paired-n50-20260814-evidence.json`
- `evidence/curated/openramble-fair-n50-manifest.json`

### 2.2 Long-cache vs Handy n=20

**Status: Diagnostic only.**

With exact closed-window cache hits, OpenRamble stop latency was much lower than
the patched Handy backend on two long real files:

| Fixture | OpenRamble cached p50 | Handy p50 | Ratio |
|---|---:|---:|---:|
| Product-names 56.1 s | 52.455 ms | 924.747 ms | 17.629× |
| Whole-earth 84.4 s | 97.449 ms | 5,715.875 ms | 58.655× |

Quality noninferiority failed: OpenRamble had worse WER on both. Precomputation
cost was not counted in stop latency because it ran during speech, and the Handy
patch artifact was not the exact official app recipe. No public claim is allowed.

## 3. Short-model and graph experiments

### 3.1 Static 7.5 s encoder

**Status: Rejected as universal; standalone speed proven.**

Against static 15 s, the 7.5 s graph reduced M4 p50/p95 by roughly 32–40% on
four frozen real fixtures with parity on those four. It failed universal long
quality on product-names audio: WER 16.04% → 30.19%, +14.15 percentage points.
The number of long-form windows rose from 5 to 11.

The broad 122-utterance engineering gate had combined ΔWER +0.323 pp, but six
regressions and up to two added word errors. A candidate-region fallback did not
catch the ordinary non-vocabulary regressions.

Evidence:

- `evidence/curated/openramble-short-shape/EVIDENCE.md`
- `evidence/curated/openramble-short-shape/UNIVERSAL_7_5_HARD_STOP.md`
- `evidence/curated/openramble-short-quality-gate/reports/QUALITY_GATE.md`

### 3.2 Static 10.0 and 12.5 s encoders

**Status: Rejected by sealed untouched holdout.**

The holdout used pinned FLEURS validation rows with zero overlap against the
engineering set.

- 10.0 s: n=200, combined ΔWER -0.0595 pp; two English fixtures added two word
  errors and failed the hard per-utterance gate.
- 12.5 s: n=300, combined ΔWER -0.1639 pp; one English fixture added two word
  errors and failed the same gate.
- Aggregate/language confidence intervals, integrity, timing alignment,
  structure, and zero vocabulary-candidate false negatives otherwise passed.

A post-hoc 12.5 s “fallback on vocabulary candidate” policy reran 9.33% of
requests and repaired aggregate quality, but predicted stop latency was worse:
mean -6.82% and p95 about 128 ms vs 74 ms shipping. Packaging added roughly
445 MiB and shared zero exact encoder bytes.

Evidence:

- `evidence/curated/openramble-intermediate-quality-gate/reports/FINAL_GATE_REPORT.md`
- `evidence/curated/openramble-static12_5-no-vocab-fallback-v1/PRIOR_EVIDENCE_REPORT.json`

### 3.3 EnumeratedShapes and MultiFunction packaging

**Status: Rejected.**

- Vanilla enumerated encoder compiled but failed at runtime on dynamic `tile`
  with Core ML error -7.
- A broadcast patch removed that crash but ANE compilation failed, falling back
  to about 241–246 ms for 7.5 s and 416–423 ms for 15 s with about 3.11 GiB RSS.
- 7.5 s parity failed one of four fixtures.
- MultiFunction failed conversion on `constexpr_lut_to_dense` and would require
  macOS 15, while the product supports macOS 14.
- A hardlink overlay could reduce incremental disk bytes, but the current
  installer cannot safely encode/preserve the hardlink graph and semantic
  tensor attestation was incomplete.

### 3.4 Four-bit and int8 encoder variants

**Status: Rejected.**

- Four-bit encoder: smaller artifact, but slower and failed parity.
- Historical int8 encoder: no useful speed win and no basis for product change.

Evidence:

- `evidence/curated/openramble-encoder-4bit/EVIDENCE.md`
- `evidence/curated/openramble-int8-encoder-e2c2449/EVIDENCE.md`

### 3.5 Lean JointDecision

**Status: Rejected as insufficient.**

The lean graph omits top-k outputs, uses the same 12,642,764-byte weight blob,
and preserved transcript/token/timing/confidence parity on four auto-language
fixtures. Joint work improved about 37.7%, but pooled end-to-end only improved
6.16% (1.2–8.0% by fixture), below the 10% gate and not validated with explicit
language/vocabulary product settings.

Evidence: `evidence/curated/openramble-jointdecision-auto-aed0274/EVIDENCE.md`.

### 3.6 Fused Decoder+JointDecisionCached

**Status: Permanently rejected under the preregistered design.**

The fused graph preserved exact text, tokens, timings, confidence bits, and
transactional replay. The first version was slower. A final one-shot ping-pong
experiment supplied two preallocated h/c/decoder output backing sets and kept
all finite, bounds, and alias checks.

- A total p50: 45.379 ms.
- B total p50: 45.964 ms.
- B regression: +0.584 ms / +1.288%.
- Every fixture was slower by 1.25–2.56%.
- Fused prediction itself improved only about 4.92 µs/call; host validation and
  preparation consumed about 0.986 ms total.

It failed both gates: no fixture may be slower, and overall win must be ≥5%.
Do not remove safety scans or tune this graph further.

Evidence:

- `evidence/trees/openramble-fused-tdt-cached/smoke/pingpong-smoke-report.json`
- `source-patches/26-openramble-fused-tdt-cached__FluidAudio/changes.patch`

### 3.7 Decoder/joint compute placement

**Status: Rejected.**

Baseline-bracket drift was about 2%. Joint CPU-only/GPU and decoder CPU-only
variants remained within or behind that drift. No option approached a stable
10% end-to-end improvement; parity did not justify product complexity.

Evidence: `evidence/curated/openramble-phase-breakdown-ee9a7f12/`.

## 4. Long-form precomputation and cache experiments

### 4.1 Exact closed-window cache

**Status: Proven prototype; not integrated.**

For silence-aligned, provably closed non-final windows, caching raw TokenWindow
results preserved transcript and full token-timing hashes exactly.

| Audio | Baseline p50/p95 | Cached p50/p95 | Cached/final windows |
|---|---:|---:|---:|
| Real 56.1 s | 174.248/185.886 ms | 57.755/58.961 ms | 4/5 |
| Real 84.4 s | 233.775/238.552 ms | 67.210/68.706 ms | 6/7 |
| Synthetic 60 s | 179.618/181.040 ms | 73.136/75.061 ms | 4/5 |
| Synthetic 120 s | 300.806/303.585 ms | 54.511/54.862 ms | 9/10 |
| Synthetic 300 s | 747.686/756.985 ms | 64.766/71.516 ms | 23/24 |

All 25 pairs kept exact transcript and full token-timing hashes. Precompute
speech duty was about 0.46–0.56%; minimum sequential slack was 2.0–10.1 s.
Process high-water RSS was 2.139 GiB, not incremental cache RSS.

Evidence:

- `evidence/curated/openramble-stop-precompute-ee9a7f12/EVIDENCE_MEMO.md`
- `evidence/curated/openramble-stop-precompute-ee9a7f12/ARCHITECTURE_REVIEW.md`
- `source-patches/53-openramble-stop-precompute-ee9a7f12__FluidAudio/changes.patch`

### 4.2 Same-process active speculation

**Status: Architecture rejection for worst-boundary guarantee.**

With one non-preemptible Core ML lane and concurrency 4, an active speculative
window can still own the lane when Stop arrives. At the first-job interval,
ordinary final cost is `ceil(N/4)` waves while the stop path is one residual
wave plus `ceil((N-k-1)/4)`. With `k=0`, speculation cannot be strictly better
at every boundary and can be one wave worse. A logical discard cannot preempt
the native operation.

### 4.3 Endpoint snapshot cache

**Status: Rejected under current raw-sample semantics.**

The experiment varied exact suffix length/zero tail, developer vocabulary, and
resume behavior across 49 PCM inputs ×2 runs.

- Eligible canonical snapshot/final digests matched 14/14.
- Resumed speech invalidated 5/5.
- Parameter mutations invalidated 20/20.
- Canonical vs current raw transcript matched 11/14; normalized 13/14.
- Raw token timings matched 0/14; product word timings matched 0/14.
- Even exact-zero suffixes changed token/word timing because TDT/CTC behavior is
  sample-count dependent in about 80 ms buckets.
- Warm candidate median/max: 49.63/95.19 ms.
- Serialized mismatch worst case: 139.09 ms vs normal 83.29 ms.

Current capture exposes lossless PCM only at freeze; `onSamples` is intentionally
lossy and may not feed ASR. Integration would require a new immutable prefix
snapshot and a new canonical endpoint contract, not a cache patch.

Evidence:

- `evidence/trees/openramble-endpoint-cache/harness/ENDPOINT_CACHE_FALSIFICATION.md`
- `source-patches/19-openramble-endpoint-cache/changes.patch`

### 4.4 Dual-process speculative cache falsifier

**Status: Inconclusive; no product claim.**

The CPU harness was extensive: exact executable/model/config/hardware identity,
bounded transfer, direct authoritative PCM comparison, SIGKILL/waitpid lifecycle,
resource sampling, 100-cycle fault soak, and ThreadSanitizer coverage. The model
matrix never completed:

1. Live `vm.swapusage` was not an exact-byte API.
2. Optional Swift descriptor fields mismatched the Python wire schema.
3. The portable validator incorrectly rejected window zero's legitimate stable
   range semantics.
4. The final authorized run stopped when the 10 ms sampler raced a normally
   exiting child and `proc_pidinfo` returned ESRCH.

Useful partial evidence showed exact PREPARE-stage kill→waitpid around 24.5–27.4
ms, zero swap delta, pressure 1→1, and no global ANE tail in an exclusive
bracket. Core ML trace rows lacked PID attribution, so exact native route was
never proven. No parity or p95/max matrix exists.

Evidence:

- `evidence/trees/openramble-dual-cache-model-preflight/harness/README.md`
- all `tiny-*` failure directories under the same archived tree

### 4.5 GPU/CPU producer for independent speculation

**Status: Rejected.**

- `.cpuAndGPU` crashed in MPSGraph:
  `shape.count = 0 != strides.count = 3`.
- GPU encoder plus CPU decoder/joint produced exact transcript text on 4/4 but
  exact full token/timing/confidence on 0/4.
- Confidence differed on all four; one Libri token boundary shifted 80 ms.
- p50 100.7–108.5 ms vs ANE 37.6–46.4 ms, about 2.3× slower.
- Load was 5.25 s; process high-water RSS 2.63 GiB.

Evidence: `evidence/curated/openramble-gpu-cache-parity-ee9a7f12/EVIDENCE.md`.

## 5. Streaming and endpoint alternatives

### 5.1 Current FluidAudio SlidingWindow path

**Status: Rejected as exact final path.**

Source audit found:

- production does not call preview; capture `onSamples` feeds waveform only;
- the preview creates a different manager with no language hint, mel context on,
  maxTokens 150, and no shipping candidateRegions semantics;
- it is fixed-15 s pseudo-streaming, repeatedly padding/running the full
  preprocessor+encoder, not a cache-aware encoder;
- for ≤15 s final flush still runs the 240k full frontend;
- the input stream is unbounded, yield has no acknowledgement, finish can return
  partial output after failures, cancel does not join, and reset cannot recreate
  a finished one-shot stream.

Evidence:

- `evidence/curated/openramble-streaming-tdt-audit-ee9a7f12/STREAMING_TDT_SOURCE_AUDIT.md`
- archived six-test bounded frame/fence/hash CPU prototype under `evidence/trees`.

### 5.2 Canonical endpoint/VAD proposal

**Status: Static rejection before ASR inference.**

The endpoint lane preserved a Silero 256 ms Core ML artifact/license and a
fail-closed endpoint contract prototype. Two eligibility blockers remain:

- the untouched 204-utterance quality corpus has no independent speech-end
  labels, so it cannot validate canonical tail trimming without leaking the
  candidate decision into label construction;
- a 256 ms analysis window plus end hysteresis causally cannot finish before an
  exact speech-boundary Stop, so it cannot deliver the required 10× win at every
  boundary. It can only help when the user pauses before releasing the key.

No ASR/CoreML run was made. Evidence is under
`evidence/trees/openramble-canonical-endpoint-v1.QLyMSY/`.

### 5.3 PengChengStarling streaming Zipformer

**Status: Source-only future candidate. No weights downloaded.**

This was the only audited candidate satisfying the initial architecture filter:

- explicit English and Russian support;
- causal/chunk training and real reusable encoder caches;
- offline macOS arm64 CPU route through sherpa-onnx C API;
- Apache-2.0 source/model packaging path;
- payload metadata 339,349,396 bytes; estimated persistent state 2,999,808 bytes.

Blockers before a smoke:

- the model requires an EN/RU language token as the initial decoder token;
  upstream sherpa starts with blank=0;
- an author fork sets `lang_id` too late and is not fail-closed;
- no published EN/RU WER exists;
- no Core ML or Metal path is proven, so CPU latency/RSS may fail immediately.

The next agent may implement only a minimal initial-token API seam and CPU tiny
smoke after sealing exact artifacts and gates. Do not integrate on source claims.

Evidence: `evidence/curated/openramble-asr-candidate-audit-f2b6ee9a/MEMO.md`.

## 6. Alternate model/runtime experiments

### 6.1 NVIDIA Nemotron 3.5 streaming GGUF

**Status: Hard-stopped/incomplete; no retry of R6.**

The official C ABI/runtime source path built with portable Metal. R6 cold load
was 6.20 s. The harness stopped on a missing model-emitted language tag for a
Russian clip; later audit proved that gate was a false positive because the
explicit RU prompt token had been selected correctly and the tag is optional.
The exception path then leaked the recognizer and hit a Metal residency-set
destructor assertion. No measured release matrix was produced. Known streaming
and finish costs did not support the 10× target, so R13 was not run.

Evidence: `evidence/curated/nemotron35-stage1.UhkPS6/R6_STAGE1_HARD_STOP.md`.

### 6.2 Nemotron Core ML 2240/R0

**Status: Rejected.**

Finish latency around 36.5 ms was interesting, but tiny quality was worse than
shipping: 10/49 vs 4/49 errors. The candidate did not justify a broad gate.

Evidence: `evidence/curated/openramble-nemotron-coreml-smoke/EVIDENCE.md`.

### 6.3 SenseVoice Small int8 Core ML

**Status: Static HARD NO for EN+RU; no model download/inference.**

The released Small model supports Mandarin, Cantonese, English, Japanese, and
Korean, not Russian. A dead `<|ru|>` metadata token exists, but the vocabulary
contains no Cyrillic or byte-fallback output pieces. The Fluid wrapper returns
only text and discards language, token timing, confidence, and vocabulary
semantics. The compiled preprocessor accepts only 0.2–30 s. Model provenance is
not cryptographically tied to the upstream checkpoint, and the model license is
non-standard.

Evidence: `evidence/trees/openramble-sensevoice-source-checkpoint/REPORT.md`.

### 6.4 Apple SpeechTranscriber

**Status: Rejected.**

English behavior was promising, but measured latency was about 60.7 ms and the
route did not satisfy Russian/product semantics. It cannot beat the current
short path enough to justify a platform-specific split.

Evidence:

- `evidence/curated/openramble-speech-analyzer-probe/EVIDENCE.md`
- `evidence/curated/openramble-speech-analyzer-probe/SPEECH_TRANSCRIBER_EVIDENCE.md`

### 6.5 Other source audits

GigaAM, Whisper/transcribe.cpp, Qwen3-ASR, Vosk, and other source trees were
audited or built in isolated roots. None produced a candidate satisfying all of
EN+RU, real streaming state, offline macOS fit, ≤16 GiB resources, quality, and
the required short latency. Their exact revisions are preserved in
`source-patches/*/metadata.json`; no unmeasured route should be promoted.

## 7. Reliability, recovery, and release work already incorporated on main

These lanes were not the final speed branch, but they matter for continuation:

- **Capture start containment:** synchronous AVAudioEngine prepare/start moved
  off the capture actor into a globally bounded exact-generation lane; focused,
  ThreadSanitizer, controller, and full-package tests passed.
- **Freeze/contain/discard hardening:** permanent converter callbacks are bounded
  by committed-prefix sealing; memory release is single-flight and bounded.
- **Causal next-session admission:** cancel/technical containment cannot publish
  a misleading reusable idle state before the older generation is fenced.
- **Durable recording disposal/recovery:** exact intents, batch manifests,
  cross-directory discovery, live creator file leases, stale partial repair,
  and fail-closed storage-fault behavior were implemented and tested.
- **Clipboard insertion:** targeted Return uses the captured PID; delayed
  clipboard restoration is serialized in the same process-wide insertion lane.
- **Worker supervisor soak:** 1,000 and 10,000-cycle runs showed no FD growth,
  bounded RSS, clean cancellation/descriptor reuse, and zero orphan children.
- **Release hardening:** strict nested signature checks without `--deep`, exact
  packaged-worker recognition under OS network denial, honest CFNetwork wording,
  and artifact provenance gates were added before 0.7.0.

Many corresponding logs remain represented in
`manifests/ALL_TEMP_FILE_PATHS.tsv.gz`; the authoritative production code is on
`main`, not in temp worktrees.

### 7.1 Main-actor return under CPU and disk pressure (2026-08-21)

**Status: Validated local candidate; not released.**

Unified-log phase timing isolated two old outliers after recognition had
already finished:

| Audio | Total | Engine | Main-actor return |
|---:|---:|---:|---:|
| 10.37 s | 2.74 s | 0.19 s | 2.53 s |
| 23.37 s | 4.85 s | 0.39 s | 4.43 s |

Both used the in-memory pool frame, so disk decoding and worker handover were
not the missing seconds. Process sampling found that dismissing the AppKit
panel only ordered its window out: the retained SwiftUI host continued the
transcribing symbol effect through the Liquid Glass surface. The idle process
therefore kept driving `RBSymbolAnimator`, RenderBox, Core Animation commits,
and Metal work. The same animation was active while a completed result waited
to return to the main actor.

The candidate makes panel visibility published, removes all composited panel
children while the window is hidden, resets hidden work state to idle, and
uses a static waveform during the short visible transcribing state. Liquid
Glass remains. A settled visible transcribing panel and a dismissed panel both
measured 0.0-0.1% process CPU; samples showed the main run loop asleep and no
continuous symbol-animation or glass commit stack.

The real-path stress check used the signed archive application, the normal
Right Command hotkey, speaker output captured through the real microphone,
local recognition, TextEdit insertion, and the production unified-log timing
line. Load was 14 bounded `/usr/bin/yes` workers plus repeated 160 MiB writes
with `fsync` to one temporary file. All created PIDs and temporary files were
removed after each bounded run.

| Audio | Total | Engine | Main-actor return | Frame |
|---:|---:|---:|---:|---|
| 28.00 s | 0.46 s | 0.45 s | 0.00 s | pool |
| 11.88 s | 0.22 s | 0.21 s | 0.00 s | pool |
| 19.60 s | 0.49 s | 0.41 s | 0.00 s | pool |
| 20.39 s | 2.81 s | 2.70 s | 0.00 s | pool |
| 19.27 s | 1.26 s | 1.22 s | 0.00 s | pool |
| 37.59 s | 1.00 s | 0.97 s | 0.00 s | pool |

No 2.53-4.43 s main-actor-return tail occurred in this n=6 candidate run.
There was no matched pre-change control using this exact harness, so six clean
rows do not estimate the probability of a rare tail by themselves. The 20.39 s
row is the load-validity check: the saturated machine produced a multi-second
completion, but 2.70 of its 2.81 seconds were measured inside the ASR engine
and main-actor return remained below the log's 0.01 s resolution. In these six
rows, disk transport, pool return, engine dispatch, and main-actor delivery did
not explain the remaining variance.

One of seven synthetic hotkey attempts never entered the Accessibility
`recording` state. It is a hotkey-harness reliability observation under
saturation, not a recognition-delivery sample, and was excluded before any
speech or recognition occurred. The final sample was admitted only after the
recording state was observed and was considered complete only after the app
returned to `ready to dictate`.

The archive was locally signed but intentionally not notarized and did not pass
the release script's offline distribution gate. These measurements validate a
development candidate, not a Sparkle release.

## 8. Current architectural conclusion

The current full-context Parakeet v3 encoder uses full relative-position
attention (`att_context_size: [-1, -1]`) and non-causal downsampling. Earlier
prefix representations can change when suffix samples arrive. Exact incremental
short inference is therefore mathematically unavailable without either:

1. changing the canonical endpoint semantics;
2. adopting a model trained for causal/limited-context streaming; or
3. accepting a separate speculative worker/lane with measured cost and a safe
   fallback.

The third route failed parity/speed or remained inconclusive. Endpoint trimming
cannot improve exact speech-boundary stop. The next serious branch is a genuinely
trained EN+RU streaming model, with PengChengStarling as the single current
source-only candidate.

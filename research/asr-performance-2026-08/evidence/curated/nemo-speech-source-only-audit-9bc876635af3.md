# NeMo-Speech.cpp / Nemotron 3.5 source-only audit

Date: 2026-08-14 (Europe/Moscow)

Scope: TEMP-only, read-only against the OpenRamble worktree. The target Nemotron GGUF was not downloaded and no ASR inference, Core ML, or ANE run was performed. This memo is an audit and a preregistered gate proposal, not a feasibility or adoption claim.

## Verdict

The official native runtime is source-clean enough to justify one tightly gated model smoke after explicit approval. Its C ABI is a more complete incremental ASR surface than the current FluidAudio multilingual Core ML manager: true cache-aware state, explicit `push`/`next`/`finish`, final word timestamps, language tags, and RNNT context bias are present. It is not product-ready from this audit alone.

FluidAudio remains the lower-integration-cost Apple path because OpenRamble already ships that runtime and it avoids a second 5.19 MB native stack. Its actor/state ownership is Apple-native, but the current public path has weaker artifact pinning/provenance, token rather than word timings, no streaming context bias, and materially different EOS behavior. A model run is required before choosing either lane.

Hard gaps found in the official C surface: no cancellation call, no public stream reset/reuse, no public warmup, no token IDs/call counts, no exposed partial stability, `interim_results` is declared but ignored by the C-to-C++ mapper, unknown language strings silently fall back to `auto`, repeated `finish()` can enqueue another final, and push-after-finish becomes a silent no-op. A product wrapper must fail closed around all of these.

## Exact source and build pin

- Repository: `https://github.com/NVIDIA/NeMo-Speech.cpp.git`
- Commit: `9bc876635af36df537d9bc6d3f57ad1b76e4f74a`
- Tree: `1948a2f0797c2b2102620ad1ef13cc4c3f691df1`
- Commit timestamp/subject: `2026-08-12T16:34:55+05:30`, `fix(install): windows arch detection with PS (#11)`
- Source version: `1.0.0`
- Commit carries a GitHub-verified valid GPG signature. Local verification was not possible because the signing public key is not installed.
- Source checkout: `$TMP/nemo-speech-cpp-audit-9bc876635af3`; detached, recursively initialized, clean.
- No GitHub releases and no fetched tags at this pin. The only GitHub Actions workflow is Ubuntu pre-commit lint/format; it is not a runtime build/test matrix. This is a maturity risk.

Recursive submodule pins:

| Path | Commit |
|---|---|
| `ggml` | `c03b4e2bcece5134827881af90242086daf75be5` |
| `llama.cpp` | `560445bf34c87356ad0f8d80fb03ec5488850b65` |
| `proto/riva-common` | `71df98266725320a6b6b3a9f32a6da832dc93691` |
| `third_party/cpp-httplib` | `62d899feac3cf9215a55f2b43da250fdd98d2156` |
| `third_party/cppjieba` | `b3602bef7d1f67521a61788a74fb5801a0e62cd3` |
| `third_party/cppjieba/deps/limonp` | `9d74077dfcdf8073536c97a00bb79d7a3c3fdaba` |
| `third_party/flashlight-text` | `49e163ab1e7b8108922512c294ab8513b89f404c` |
| `third_party/kenlm` | `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5` |
| `third_party/open_jtalk` | `1e52154e6677d02dcb4b7f15453e65b5ca1cb6aa` |

The recursive `llama.cpp` source checkout contains 19 small vocabulary-test GGUF files totaling 77,556,152 bytes. None is the target Nemotron model and none is in the runtime install.

Build tools were downloaded into `$TMP` only:

- CMake 3.31.10 universal archive SHA-256: `be9f3faeeaf7921cc2d77cea711dd5e6f72c63af2810cacd9205b3ce8d1593c9`
- Ninja 1.13.2 archive SHA-256: `c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b`
- SentencePiece source commit: `17d7580d6407802f85855d2cc9190634e2c95624`, tree `6d2b48ff57265838b00264c0d99aeb159ac8aa95`, clean.
- `libsentencepiece.a`: 0.2.0, SHA-256 `729bdc48da305a5af22b6697179a31cd0c295c07bb3c528e7f7e618ff073db39`
- Installed header SHA-256: `e7c8810acbb62a7d872b28f4aab13112da47323893134038f37afa2e9b5fec0a`
- Upstream helper script SHA-256: `f026ca503328a8ff38b40b931271d3a21e6352571c9929795ee1fe7dc78b975a`

Host/toolchain: macOS 26.4 build 25E246, Apple M4 arm64, Apple clang 21.0.0. Common build was Release/arm64/minimum macOS 14.0, ASR+CLI only, stock pinned ggml, BLAS on, Flashlight/Vulkan/HTTP/gRPC/diarization/NMT/TTS off.

Build evidence:

| Build | Configure | Build | Peak build RSS | Result |
|---|---:|---:|---:|---|
| CPU, `GGML_METAL=OFF` | 0.77 s | 11.91 s | 304,021,504 B | pass |
| Metal, upstream default `GGML_NATIVE=ON` | 3.06 s | 12.40 s | 303,448,064 B | pass but not portable |
| Metal, `GGML_NATIVE=OFF` | 0.86 s | 10.34 s | 304,365,568 B | pass; selected artifact |

Critical deployment finding: upstream default `GGML_NATIVE=ON` emitted M4-specific `-mcpu=native+dotprod+i8mm+nosve+sme`. It must not ship as a generic Apple Silicon binary. The selected portable build has no `-mcpu` flags, is thin arm64, and every runtime Mach-O has minimum macOS 14.0 (SDK 26.5). x86_64/universal2 was not built or claimed.

The upstream `scripts/build_sentencepiece_static.sh` compiled the archive/header, then failed on macOS license installation because it uses GNU-only `install -D`. The audit passed the exact archive/header to CMake without modifying source. Packaging must not reuse that broken license-install step uncorrected.

## Source-only tests

After enabling tests without supplying any model:

- `ctest`: 4/4 registered tests pass in 11.04 s (`shared_utilities`, `subtitles`, `installed_sdk_consumer`, `cli_contract`).
- Manual safe binaries pass: `test_audio_decoder`, `test_audio_resampler`, `test_batching`, `test_decoders`, `test_endpointer` policy cases, and `test_postproc`.
- `asr_c_smoke` passes header/link/version (`nemo-speech-asr 1.0.0`); `asr_c_dlopen ./libnemo_speech_asr_c.1.dylib` passes.
- `test_oov_boost` correctly skips because Flashlight was intentionally disabled.
- Model-backed endpointer integration correctly skips because no model was provided.
- Many compiled unit executables are not registered with CTest; upstream CI also does not run them. The passes above do not substitute for model inference.

## Runtime ABI and lifecycle

The installed C dylib exports exactly 27 `nemo_speech_asr_*` and 13 `nemo_speech_diar_*` symbols, with no other public exports. The ASR ABI uses opaque recognizer/stream/result handles, POD append-only size-prefixed configuration structs, explicit result destruction, no C++ types, and thread-local errors.

Observed ASR call graph:

1. `nemo_speech_asr_create`: loads one local GGUF into a persistent recognizer.
2. `nemo_speech_asr_streaming_recognize`: rejects a non-cache transducer and creates isolated encoder-cache and RNNT predictor state for one stream.
3. `stream_push_f32`: validates, optionally resamples synchronously, then copies PCM into stream-owned storage. In the proposed ASR-only lane it performs no neural/mel compute, so return is a safe copied-PCM acknowledgement and caller memory can be released. Exception: if optional diarization is enabled, diarization mel/inference may occur synchronously during push; keep it disabled in this gate.
4. `stream_next`: synchronously computes new mel frames, each ready non-overlapping encoder chunk, and RNNT decoding. It returns one partial/final or `NULL` when more audio is needed.
5. `stream_finish`: synchronously flushes resampler/VAD and the acoustic/RNNT tail, stores a pending final, and is the operation whose duration represents stop-to-result compute. The following `stream_next` only transfers that final once.
6. Destroy every result, close the stream, and destroy the recognizer only after all streams and calls are quiescent.

Incrementality is real: every stream retains device encoder self-attention K/V and convolution caches, RNNT predictor LSTM/token state, and incremental front-end cursors. Chunks are fixed and non-overlapping; only new audio is encoded. Multiple streams may share one recognizer/model but each stream is single-caller-thread only. There is no stream mutex; never close/destroy concurrently with `push`, `next`, or `finish`. Optional batching owns worker threads; destructors drain queues and join them.

EOS semantics: finalization pads zero mel by `chunk_size + shift_size`, lets the last real frames see complete right context, gives RNNT a zero-frame tail, enables the terminal punctuation floor, finalizes an open word, and returns one final. Natural midstream EOU preserves already-buffered future audio; forced EOU commits all audio already supplied. At EOU the encoder/predictor state resets while the absolute stream timeline continues.

Public lifecycle limitations:

- No public stream reset/reuse. Close and create a new stream. Internal reset exists but is not ABI.
- No ASR cancel function despite the `CANCELLED` enum; source never returns that status. A blocking Metal `next`/`finish` cannot be interrupted safely.
- Repeated C `finish()` calls invoke finalization again and can enqueue the final again. Push after finish reaches a finalized runner and silently no-ops. The wrapper must reject both before calling C.
- `force_endpoint` only latches a flag for the next `next`; it performs no compute.
- No C warmup API although the C++ recognizer has warmup. Use a separately recorded throwaway fixture stream and keep cold-load metrics distinct.

Errors: `bad_alloc` maps to OOM, `invalid_argument` to INVALID_ARGUMENT, other exceptions to RUNTIME. `last_error` is thread-local and valid until the next ASR-family call on that thread. Some immediate null-handle/null-output guards return INVALID_ARGUMENT without refreshing it, so a wrapper must not surface a stale message for those cases.

Partials/finals:

- Partial = current raw top hypothesis, confidence 0, no words, and may revise. Internal stability is 0 but the C ABI exposes no stability accessor.
- Final internal stability is 1; optional postprocessing is applied, language tags are removed from visible text/word lists, and detected languages are exposed separately.
- Final words have int32 millisecond start/end values derived from decoder encoder-frame spans. There is no token-ID/timing accessor. RNNT transcript/word confidence is generally 1.0 and is not calibrated.
- `recognition_options.interim_results` is currently ignored by `to_options()`: native streams produce partials whenever the transcript advances. Filter locally and treat this as an upstream ABI implementation bug.
- Prompt lookup is exact/case-sensitive. Unknown or empty language falls silently to `auto` when available, otherwise `-1`. A wrapper must validate exact `en-US`, `ru-RU`, and `auto` entries from the loaded GGUF instead of trusting success.

## Context bias identity

For RNNT, the GGUF embeds a SentencePiece model. Each request's literal phrases are tokenized and compiled into a token-level Aho-Corasick trie (NeMo/Riva-style shallow fusion). `$[A-Z_]+` class hints are skipped rather than treated as literal phrases.

Exact source defaults at this pin:

- global tree alpha: `1.0`
- depth scaling: `2.0`
- maximum positive request boost across all contexts, clamped to `[0.1, 5.0]`
- if no positive request boost exists, effective phrase score defaults to `1.0`

The C recognizer config does not expose those three RNNT tuning knobs; its decoder `max_boost` field maps to the separate Flashlight/CTC path. Therefore configuration identity for an RNNT gate must include the runtime commit and these constants.

Biasing cannot flip blank versus nonblank: the runtime first makes that choice using unboosted logits, then performs a second blank-excluded argmax to re-rank which nonblank token wins. This reduces insertion risk but can add joint work and may limit phrase rescue. Gate base quality with bias off, then test bias in a separate preregistered entity-recall/insertion lane.

## Network, dependencies, signing, and license obligations

The selected runtime build has HTTP and gRPC disabled. Its CLI exposes local transcribe/bench/model/doctor/help only; no downloader or libcurl/network framework is linked. The model loader accepts a local path. Optional HTTP/gRPC servers and download/install scripts exist in source but are not in this artifact; keep them off and run the worker network-denied if desired.

Transitive system dependencies are only libc++, libSystem, libobjc, Accelerate, CoreFoundation, Foundation, Metal, and MetalKit, plus the packaged NeMo/ggml dylibs. The selected binary is ad-hoc linker-signed with no team ID; product packaging must apply the OpenRamble Developer ID signature and notarize it. Runtime install:

- logical bytes: `5,190,382`
- allocated bytes: `5,300,224`
- `bin/` + `lib/`: `5,021,789` bytes
- gzip tar: `1,730,869` bytes, SHA-256 `93d605f4ec0622dd1f8f613c18760d450c8716f3a70ddfa9c5126360dfa54c68`

Principal binaries (bytes, SHA-256):

| File | Bytes | SHA-256 |
|---|---:|---|
| `nemo-speech` | 363,560 | `e7f623f3b37869e116ae3a4731dae9c0267f165e3dce55e150bbb667792dc4bb` |
| `libnemo_speech_asr.dylib` | 2,070,056 | `ece08d1c8ac9f8c20e8d475ec9b9a2368ec92aa04c6ac20ddecde79cf38758e7` |
| `libnemo_speech_asr_c.1.dylib` | 96,080 | `d637d02b7ee5b4b07b8d02ac218363e17fce6c7def2ae1853d35bd95914826e3` |
| `libggml-metal.0.12.0.dylib` | 833,624 | `1029c8524eb64a710789315658f2cc691b2dc29c239bf4bd7bccf43fe1d04f99` |
| `libggml-cpu.0.12.0.dylib` | 829,208 | `375f23a16100f95507eeb2ee41f2dc7ac3705d1693a5b561a33723a29157e0d9` |
| `libggml-base.0.12.0.dylib` | 705,448 | `36dc36a1abcecfd91d19719e323bd0721ba70fd82dc8c3e2d1f7dc9d887fea67` |
| `libggml.0.12.0.dylib` | 59,816 | `5288cddfb3062e867d743683db6549b732ead9a3975aa0f1e51b0437ed2da096` |
| `libggml-blas.0.12.0.dylib` | 58,776 | `c3c8191f727ca13c9ac0c7e317663f51d9f9e8a649f62c028497531a1ddec4b9` |

Licensing findings (not legal advice):

- Runtime root is Apache-2.0. Exact hashes: `LICENSE` `eaaca34b26b27c7be5a5099a0b9ddf9913f2db0aa96f6d5854435f2916d6fdc3`; `NOTICE` `d5ea773d67035e676503579ecf7d5836a124649d7fe99d59ec3c50cd101e1a80`; `THIRD_PARTY_NOTICES.md` `839016ca9e42f2d9a58f69c52b0c257f3c4f44054a65221a6476b1cac2dcb2a6`.
- ggml is MIT; license SHA-256 `94f29bbed7dc88ef72f620a33d1f1acf3898e1473fd85ed2abc6af1b5f98f299`.
- Static SentencePiece is Apache-2.0, license SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`; bundled runtime-relevant notices include absl `d3e2f59e1d71176dfdb555ece6a41f7a5aa0f52ff21211010ace314f57695f6b`, darts-clone `155f59997298ee336602c49f9c1110f268ac394ca2197eb02647a3555935ad52`, and protobuf-lite `6e5e117324afd944dcf67f36cf329843bc1a92229a8cd9bb573d7a83130fea7d`. esaxx is trainer-only and not in the runtime archive.
- Upstream runtime install includes root/NOTICE/THIRD-PARTY and ggml license but does not merge the separately built SentencePiece notice tree. Product packaging must add it explicitly.
- Optional recursive-source KenLM/Flashlight and other submodules were disabled and are not linked or needed in the product runtime. Do not redistribute their source or claim their licenses as runtime dependencies unless enabled.
- The model is separately governed by OpenMDW-1.1. Distribution must retain a copy of that agreement and all applicable copyright/origin notices bundled with the model materials.

## Official model provenance and payload

Metadata was queried from the official NVIDIA Hugging Face repository without downloading the GGUF body:

- Repository: `nvidia/nemotron-3.5-asr-streaming-0.6b`
- Exact revision: `1c8deaecc64b91f034d73e08dd8b64625eb3395d`
- File: `nemotron-3.5-asr-streaming-0.6b.q8_0.gguf`
- Pinned URL: `https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf`
- Exact body size: `741,548,352` bytes (`707.195618 MiB`)
- LFS SHA-256 / linked ETag: `a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae`
- Hugging Face blob ID: `bad5b6d6102ccfdbb71797e721f2039f808cbc75`
- Xet hash: `f01b59f39469308f0d5621999a050abcfcc205bf82dd091042e1eeaf06746745`
- Pinned model-card SHA-256: `a3344caadf796c084c6b90a9fa5978068fd45e3a019790bebe50489bb3c0f7b7`
- License: OpenMDW-1.1.

The official card describes a 600M cache-aware FastConformer-RNNT, 40 locales, with `en-US` and `ru-RU` in the 19-locale transcription-ready tier. Supported inference chunks are 80/160/320/560/1120 ms, with strictly non-overlapping new frames and cached self-attention/convolution states. Runtime geometry uses 80 ms encoder frames and `current + R`: 560 ms is `rnnt_right_context=6`; 1120 ms is `13`. The runtime does not strongly validate requested R against the trained maximum, so the wrapper must allowlist `{6,13}` for this gate and verify GGUF metadata reports max R=13 after download.

Payload accounting:

- Network body: exactly `741,548,352` bytes plus negligible metadata/HTTP overhead.
- Runtime + model steady logical disk: `746,738,734` bytes (`712.145552 MiB`).
- Approximate 4 KiB allocated steady total: `746,852,352` bytes.
- Keep at least 1.6 GB free for safe partial download, verified atomic promotion, and rollback/coexistence headroom. A same-directory `.partial` -> final rename does not itself duplicate the file.
- The loader does not mmap weights. It reads tensors through a reusable largest-tensor buffer, uploads into backend buffers, closes the GGUF, and releases the read buffer. Model-loaded RSS was deliberately not measured. Planning range only: roughly 0.8-1.2 GiB incremental warmed unified-memory/RSS for the streaming path, with a higher cold peak from scratch/graph construction. This is not acceptance evidence. Avoid the offline `recognize_f32` path in the streaming gate because it can lazily create an additional encoder session and duplicate resources.

## Comparison with current FluidAudio/Core ML path

Pinned local FluidAudio checkout:

- commit `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- tree `02dc7895b0e4b1ce087e943e3bde5a92f8d85855`
- clean; already part of OpenRamble's macOS 14 arm64 runtime.

It exposes a `StreamingNemotronMultilingualAsrManager` actor, persistent shared `MLModel` objects, and per-stream cache/predictor state. macOS 14 uses explicit `MLMultiArray` cache I/O; the optional MLState path is macOS 15+. This avoids a second native runtime and uses Core ML/ANE (`.cpuAndNeuralEngine`; source notes `.all` can be much slower for this graph).

Important semantic gaps versus the official runtime:

- `process(samples:)` consumes exact full chunks and persists encoder and LSTM state.
- `finish()` zero-pads one remaining partial chunk; if audio lands exactly on a chunk boundary it does not run an additional EOS tail chunk. Official GGUF finalization does. Terminal punctuation and last-token/timing parity must therefore be measured, not assumed.
- `finishWithTokenTimings()` returns per-token seconds, not ready word offsets. The caller must group tokens into words; confidence is hard-coded 1.0.
- No streaming speech-context/hotword bias.
- Language mapping is more forgiving, which is convenient but makes strict config identity harder.
- Cleanup nils the main encoder/decoder/joint/tokenizer/cache references, but optional fused resources deserve a leak/retention test before adoption.

Current public Core ML artifact metadata (queried, not downloaded):

- repo `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`
- current revision `1a41b75758b0337ff67db7d5408280aaaf23074e`
- `multilingual/2240ms/`: 22 files, `664,846,846` bytes
- encoder weights: `565,336,640` B, SHA-256 `2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f`
- decoder weights: `29,870,592` B, SHA-256 `dcdeccd4ccf46e2675224f9f030d46c1a89e2bda4abb316e901e1a21f1597f8f`
- joint weights: `18,911,744` B, SHA-256 `c0ef0a3a6598f962d2aad598dc6850e4428874033419817121e11f1fff4a9cfe`
- fused B1 decoder+joint weights: `48,782,272` B, SHA-256 `01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b`
- preprocessor weights: `592,384` B, SHA-256 `297514e2b211d14b0e53cb97193d679bb89ead98d28e578f3f1d049ddbcc36b3` (native Swift mel path does not use it)

The current generic downloader constructs `tree/main` / `resolve/main` URLs rather than revision-pinned URLs. The Core ML card says it derives from NVIDIA's base, but the conversion manifest identifies the base only by an update date rather than an exact NVIDIA source revision/weight SHA. Product use must bypass or extend that downloader with a signed exact file manifest. Do not use the 2240 ms payload as a matched-latency comparator for official 560/1120 ms; pin equivalent Fluid shapes first or compare official modes only against the shipping baseline.

## Deterministic wrapper seam

Use a dedicated existing-style ASR worker process, not a CLI subprocess per utterance. Keep HTTP/gRPC/server targets absent.

State machine: `unloaded -> ready -> open -> finishing -> drained -> closed`.

- One persistent recognizer per R setting; use separate processes/recognizers for R=6 and R=13 because the encoder session/cache graph is lazily built using final R.
- One actor/serial executor per stream. Never call C concurrently on one handle.
- Canonical input: mono float32, 16 kHz. Every push message carries stream ID, monotonic sequence, sample count, cumulative sample count, and SHA-256 of PCM bytes.
- ACK `push` only after C returns; at that point ASR-only PCM has been copied.
- After each push, drain `next` until `NULL`; optionally suppress partial delivery locally. Hash every raw partial for diagnostics but never call it stable.
- On stop, transition once to `finishing`, time the synchronous `stream_finish`, call `next` exactly once for the final, require non-null/final, then require the next call to return `NULL`. Hash raw text, normalized text, detected languages, and ordered `(word,start_ms,end_ms)`.
- Destroy every result exactly once; close every stream. On graceful worker shutdown stop admissions, wait for in-flight synchronous calls, close streams, destroy recognizer, then exit.
- Since no cancellation exists, a hard timeout must terminate only the exact dedicated child PID, await it, and restart a clean worker. Never close/destroy from another thread while a call is active.
- Reject unknown language, repeated finish, post-finish push, missing/duplicate final, non-monotonic/out-of-range times, NaN/non-finite results, and stale error strings in the wrapper.
- Record exact runtime/model/config hashes in every response. A temp internal C++ probe is required if token-ID/timing and encoder/joint call hashes are mandatory; the stable C ABI cannot supply them.

## Compact preregistered model gate

### Stage 1: four-fixture smoke

Only after explicit download/model-window approval:

1. Verify exact body size/SHA, inspect GGUF metadata, require cache-aware RNNT, max R=13, and exact prompts `en-US`, `ru-RU`, `auto`.
2. Freeze four real canonical PCM fixtures: two en-US and two ru-RU, with one short and one >1.12 s per language. Record PCM SHA, gold/frozen reference, and normalizer SHA before results.
3. Run every fixture at R=6 (560 ms) and R=13 (1120 ms) in separate persistent Metal workers. Per worker: one true cold load/first-stream measurement, two discarded warmups, then three identical measured repeats. Context bias off.
4. Capture load, first cache specialization, per-push/next under-speech duty, stop=`finish` latency, exact raw/normalized text, detected language, words/ms, repeat hashes, RSS/peak, energy/thermal, and deterministic shutdown.
5. Hard stop before broad testing on any hash/metadata/load/Metal/cache failure; silent language fallback; empty/catastrophic transcript; missing/duplicate final; repeat hash mismatch; invalid/non-monotonic timing; RTF >=1; crash/leak/lingering process; or any OpenRamble cache/output parity mismatch introduced by the harness.

This smoke is a correctness screen, not statistical evidence and not a product claim.

### Stage 2: preregistered broad quality/stop-tail lane

Proceed only if Stage 1 passes. Freeze corpus, goldens, PCM, normalizer, model/config hashes, ordering seed, and thresholds first. Balance en-US/ru-RU and include short speech, silence/noise, names/hotwords, long speech, and seams within +/-0.1 s of 560/1120 ms and their multiples.

Use symmetric randomized paired persistent runs versus exact pinned shipping Parakeet; compare pinned equivalent Fluid Core ML shapes separately if desired. Require at least n=30 latency repeats per real fixture/cell after symmetric warmup and paired bootstrap 95% CIs. Report WER/CER, exact/normalized match, catastrophic utterances, entity recall/false insertion, language accuracy, word-timing MAE, partial churn/time-to-first-stable, under-speech duty, stop-to-final p50/p95, load/cold specialization, RSS/peak, energy/thermal, and 100 create/finish/close/shutdown cycles.

Proposed hard defaults to freeze before running:

- one-sided paired-bootstrap 95% upper bound on delta WER <= +0.5 percentage points independently for en-US and ru-RU;
- no entity-recall regression and no catastrophic utterance;
- deterministic final transcript/language/word-time hashes across identical repeats;
- stop p50 at least 10% better than shipping and stop p95 non-regressing;
- per-chunk p95 RTF <= 0.7, plus no thermal-throttle invalidation;
- peak RSS within a preregistered product cap; no monotonic growth over 100 lifecycles;
- orderly shutdown <=2 s when idle, with no child/thread/process left behind.

Test RNNT speech contexts in a separate off/on paired lane because they change decoding and joint-call count. Gate both entity recall and false insertion/overall WER.

## Minimal first-download/run commands (proposal only; not executed)

```zsh
nemo_model_dir=$(mktemp -d $TMP/nemotron35.XXXXXX)
nemo_partial="$nemo_model_dir/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf.partial"
nemo_model="$nemo_model_dir/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"
nemo_url='https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf'

df -k $TMP
ps -axo pid=,etime=,command= | rg -i 'coreml|nemo-speech|FluidAudio|Parakeet' || true
pmset -g therm

curl --proto '=https' --tlsv1.2 --fail --location --retry 3 \
  --output "$nemo_partial" "$nemo_url"
test "$(stat -f %z "$nemo_partial")" = 741548352
printf '%s  %s\n' \
  a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae \
  "$nemo_partial" | shasum -a 256 -c -
mv "$nemo_partial" "$nemo_model"

nemo_bin=$TMP/nemo-speech-install-metal-portable-9bc876635af3/bin/nemo-speech
"$nemo_bin" model info "$nemo_model"

# One non-gating CLI sanity only; the fair gate uses the persistent C ABI worker.
NEMO_SPEECH_TIMING=1 /usr/bin/time -lp "$nemo_bin" transcribe /path/to/en_fixture.wav \
  --model "$nemo_model" --device metal --stream --language en-US \
  --word-times --format json --asr.streaming.rnnt_right_context 6 --no-warmup
```

The actual Stage 1 should use the deterministic C ABI wrapper above, not eight independent CLI loads. After any authorized run: graceful protocol shutdown, exact-process check, thermal check, and runner-free ping before handing the model slot onward.

## Final state

- Target GGUF search under `$TMP`: absent.
- No NeMo-Speech, Core ML, FluidAudio benchmark, or Parakeet benchmark process running.
- `pmset -g therm`: no thermal or performance warning recorded.
- OpenRamble shared `git status --short`: clean.
- Temp artifacts are frozen; no further model download/run is authorized. Fused TDT retains the next model slot.

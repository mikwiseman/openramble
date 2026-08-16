# Nemotron 3.5 Stage 1 — R=6 / 560 ms hard-stop evidence

Date: 2026-08-14 (Europe/Moscow)
Host: Apple M4, 16 GiB, arm64, macOS 26.4 (25E246)
Scope: TEMP-only. The OpenRamble shared worktree stayed clean. R=13 was not run.

## Verdict

**FAIL-CLOSED / INCOMPLETE. Do not retry and do not run R=13 without a new decision.**

The pinned GGUF loaded on the portable Metal runtime and returned valid single finals for two English fixtures and a non-empty single final for the 1.0 s Russian fixture. The harness then stopped because the Russian final's optional `detected_languages` list was empty. Source audit after the stop shows that this check conflated two distinct API concepts:

- the request's explicit `language_code` selects the prompt;
- the result's `language_codes` contains model-emitted/detected `<lang>` tags **if any**.

At this exact model/source pin, the requested `ru-RU` string exists and maps to prompt index 11, so the empty detected-tag list is not evidence that the runtime fell back to `auto`. The C ABI does not expose the selected prompt index, however, so product verification would have to rely on pinned model metadata/source or add an accessor. The Stage 1 language gate was therefore a harness false positive, while the run remains incomplete and cannot be counted as a pass.

A second harness-only failure occurred after the intentional stop: the exception path skipped `nemo_speech_asr_destroy`, leaving the Metal residency set live until global teardown, where pinned ggml asserted and raised SIGABRT. This does not show that a normal runtime destroy fails; normal destroy was never called. It does show that this probe did not meet the deterministic-shutdown gate.

No measured repeats or release-phase offsets ran, so there are no legitimate warm p50/p95, no worst-offset finish p50/p95/max, no stability hash, and no R=13 evidence.

## Exact pins

### Runtime

- repository: `https://github.com/NVIDIA/NeMo-Speech.cpp.git`
- commit: `9bc876635af36df537d9bc6d3f57ad1b76e4f74a`
- tree: `1948a2f0797c2b2102620ad1ef13cc4c3f691df1`
- version: `nemo-speech-asr 1.0.0`
- recursively pinned submodules: ggml `c03b4e2bcece5134827881af90242086daf75be5`; llama.cpp `560445bf34c87356ad0f8d80fb03ec5488850b65`; riva-common `71df98266725320a6b6b3a9f32a6da832dc93691`; cpp-httplib `62d899feac3cf9215a55f2b43da250fdd98d2156`; cppjieba `b3602bef7d1f67521a61788a74fb5801a0e62cd3`; limonp `9d74077dfcdf8073536c97a00bb79d7a3c3fdaba`; flashlight-text `49e163ab1e7b8108922512c294ab8513b89f404c`; kenlm `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5`; open_jtalk `1e52154e6677d02dcb4b7f15453e65b5ca1cb6aa`
- build: Release, arm64, min macOS 14.0, `GGML_METAL=ON`, `GGML_NATIVE=OFF`, Accelerate on, HTTP/gRPC/Vulkan/Flashlight off
- runtime regular-file logical bytes: `5,190,382`; allocated by `du`: `5,300,224`
- deterministic installed-file manifest SHA-256: `b10db5a60ba10c209ae2d2f5f8de6ad0ce5a7b399b5fa92610af89f89a806a83`

Licenses/notices reverified:

- root `LICENSE`: `eaaca34b26b27c7be5a5099a0b9ddf9913f2db0aa96f6d5854435f2916d6fdc3`
- root `NOTICE`: `d5ea773d67035e676503579ecf7d5836a124649d7fe99d59ec3c50cd101e1a80`
- `THIRD_PARTY_NOTICES.md`: `839016ca9e42f2d9a58f69c52b0c257f3c4f44054a65221a6476b1cac2dcb2a6`
- ggml MIT `LICENSE`: `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d`

Erratum: the earlier source-only memo contains an incorrect ggml-license hash beginning `94f29bbed7dc...`; the value directly rehashed above is authoritative.

### Official model

- repository: `nvidia/nemotron-3.5-asr-streaming-0.6b`
- exact revision: `1c8deaecc64b91f034d73e08dd8b64625eb3395d`
- file: `nemotron-3.5-asr-streaming-0.6b.q8_0.gguf`
- pinned URL: `https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b/resolve/1c8deaecc64b91f034d73e08dd8b64625eb3395d/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf`
- exact bytes: `741,548,352`
- SHA-256: `a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae`
- HF blob: `bad5b6d6102ccfdbb71797e721f2039f808cbc75`
- Xet hash: `f01b59f39469308f0d5621999a050abcfcc205bf82dd091042e1eeaf06746745`
- model-card SHA-256: `a3344caadf796c084c6b90a9fa5978068fd45e3a019790bebe50489bb3c0f7b7`
- license: OpenMDW-1.1; distribution must retain the agreement and applicable copyright/origin notices
- local inode/nlink: `5504978` / `1`; allocated bytes at seal: `741,552,128`
- download: isolated same-directory partial, exact size/SHA verification, atomic rename; filesystem timestamps 21:34:45–21:36:53 +0300 (`128 s`, about `5.525 MiB/s`); partial no longer exists
- inspected GGUF: runtime-compatible ASR, 657 tensors, 272 Q8_0 / 30 F16 / 355 F32, no companion roles, exact `en-US`, `ru-RU`, and `auto` prompt names

## Frozen configuration and fixtures

The 351-byte canonical logical configuration JSON (sorted as shown in the harness protocol) hashes to `bc932090b5992dc48bdaa16aa9c72416ecac2bf4c4f5ab5f63ccda44e7c6819e`:

```json
{"backend_gpu":0,"context_bias":false,"enable_automatic_punctuation":true,"enable_word_time_offsets":true,"endpointing":null,"interim_results":true,"languages":["en-US","ru-RU"],"max_alternatives":1,"model_sha256":"a5c435f294eea8f88ce68dd27b8c3bfea7f777cb2fbba04fcd30eaa555f429ae","rnnt_right_context":6,"sample_rate":16000,"stream_feed_samples":2560}
```

The arm64 `nemo_speech_asr_streaming_config` is 24 bytes. Its exact little-endian bytes were:

```text
18 00 00 00 00 00 00 00  00 00 70 41  00 00 00 00
00 00 00 00  06 00 00 00
```

That is `size=24`, `chunk_size=15.0f`, CTC left/right `0.0f`, R=`6`; SHA-256 `5761f8c0ddc8a674fac908cdb247ef82acf0197ecc26bc9fd5e785a56850818a`.

- `en-US\0` bytes `65 6e 2d 55 53 00`, SHA-256 `8f180e8eb56eb34fc37481110a73f7205f34abe32ea1249ead41d5dd22fa6195`
- `ru-RU\0` bytes `72 75 2d 52 55 00`, SHA-256 `cea57f188abb6b76399fa0358e70723eb2f82a371840771ab5be2df67946d13d`
- raw GGUF strings prove `en-US:0`, `ru-RU:11`, `auto:101`
- C ABI recognition-options layout is 72 bytes on this arm64 build; relevant values were `interim=true`, word offsets=true, automatic punctuation=true, verbatim/profanity/diarization=false, max alternatives=1, no speech contexts

All four planned inputs are real public Google FLEURS validation audio, CC BY 4.0, dataset revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd`. The two 1.0 s inputs are sample-count views of exact source PCM, not rewritten files; their segment-level gold text is unavailable and they were not WER-scored.

| Fixture | Speech duration | Source PCM SHA-256 | Effective speech PCM SHA-256 | Full reference |
|---|---:|---|---|---|
| `en_short_1.000` | 1.000 s | `35e1ce4c8a1238d9439f4a86a600f228ae1c194be1b79e5d86d4893a3769eade` | `ead6f83bfbde3e192d3c4a42ee752efdd1b74347b9b43ddf36fbf2e36f39cd20` | source utterance: “he built a wifi door bell he said” |
| `en_long_3.600` | 3.600 s | `fed9414d3bcfef4de1c917296e63d33dc2a3cdc840388754e5b3e5b076fc04b9` | same | “u.s. president george w bush welcomed the announcement” |
| `ru_short_1.000` | 1.000 s | `006b2bd5cc43fa66bf705d70bbcdf3fe536403d08518a32a1bff5a8b14715508` | `992d4c6ffa824bf6c01ce1efc1cfc3317f4293a273a987aa514f7e222e628b8c` | source utterance SHA-256 `f856dddd6b4084d0905712e56bf9c37d1aef6ac6a98294e7e7687154930f44f6` |
| `ru_long_4.800` | 4.800 s | `204acd7577005f722abdf78ae21edd53cc5a9ee88093a9f7d050d73d7fe537f0` | same | reference SHA-256 `d836b3f1e90bbe795fe2cd1a8cfc0462fa94563ea63b4f8cde16bcdf7b669868` |

Harness source SHA-256: `0a9dcbc140ac0bc845f40ce4194a3e118bdd7fb23544128e102c3631ff702705`
Harness binary SHA-256: `6f0306c80cb55da173ce852ae5d0e1a0f6bbe53e3cd9ef0062e17da3c158f3ea`

## What ran

Preflight at `2026-08-14T18:52:48Z` rehashed model, source, and worker; verified exact sizes; found no competing NeMo/Nemotron/Core ML worker; showed no thermal or performance warning; and confirmed a clean shared worktree. Worker PID 15364 launched at `2026-08-14T18:53:06.9746Z` and exited at approximately `18:53:14.2965Z` (`/usr/bin/time` real `7.32 s`).

Cold/load and the only persisted fixture timings:

| Phase | Load / wall | Under-speech duty | `finish` | RTF | RSS / footprint / peak |
|---|---:|---:|---:|---:|---:|
| recognizer load | 6,201.184 ms | — | — | — | 137,773,056 / 113,263,312 / 137,773,056 B |
| first cache specialization, EN 1.0 s | 642.143 ms | 514.831 ms | 127.146 ms | 0.642 | 1,068,613,632 / 1,090,750,048 / 1,068,613,632 B |
| warm EN 3.6 s | 288.590 ms | 222.559 ms | 66.004 ms | 0.080 | 1,070,612,480 / 1,092,650,592 / 1,070,710,784 B |

Metal library initialization itself logged `6.160 s` during create. The first 1.0 s stream then built/cache-specialized the R=6 graph and pipelines. Whole-process peak from `/usr/bin/time`: RSS `1,071,218,688 B`; peak memory footprint `1,092,765,280 B`. No power sample was collected; the 7.32 s aborted run is too short for an energy claim. `pmset` reported no thermal/performance warning before or after.

### Exact persisted output

`en_short_1.000` returned one final and no duplicate:

```text
You built a wifi. Are you
```

- detected languages: `["en-US"]`
- ordered words/ms: `You 560–640`, `built 720–880`, `a 960–1040`, `wifi. 1120–1440`, `Are 1360–1440`, `you 1440–1520`
- raw text SHA-256: `b6d59a5f1ed9bcf227aa0420fabd1e7ef5a2f5e8a3e37ca0a6b499fd11f6a616`
- canonical `{text,languages,words}` SHA-256: `ef8290937357875c4b4db40a17e047fbc6bd687a1fd95de6001c3c2fb74976e0`
- not scored: the 1.0 s prefix has no segment gold. The extra “Are you” and word ends extending to 1.52 s are a quality/timestamp red flag requiring the release-phase gate; they are not a pass.

`en_long_3.600` returned one final and no duplicate:

```text
US President George W. Bush welcomed the announcement.
```

- detected languages: `["en-US"]`
- ordered words/ms: `US 720–960`, `President 1040–1280`, `George 1360–1520`, `W. 1680–1920`, `Bush 2000–2320`, `welcomed 2400–2640`, `the 2640–2720`, `announcement. 2800–3440`
- raw text SHA-256: `b50b7b05a5084e7b04207ff25503e2c31c4131573b4a0fd20a0a824a7a0efe72`
- canonical `{text,languages,words}` SHA-256: `ede077ee5afa7237dbb8134e111f4b9ef7afdcfdcc1f94cd6107d385f7f23ec5`
- raw equality to reference: false
- frozen corpus normalizer output/reference SHA-256: `00de98190ab1b1c3a8de39392df4d3c2b3876e9625a46f4012c24058655bba7e` / `b17fcbd4ad5255198f193d92ecb2d3ee9ede5a352d69a51c0317431279b4e17b`; equality false (`US` versus reference tokenization `U S`)
- WER under that normalizer: `2/9 = 22.222%`; this single warm observation is not a quality estimate

For `ru_short_1.000`, the harness established in order: exactly one final, no duplicate final, and non-empty transcript; then `languages.empty()` triggered. Because validation occurred before serialization, the Russian text and words were not persisted and cannot be reconstructed honestly. Exact known state is therefore: `final_count=1`, `duplicate_final_count=0`, `text_nonempty=true`, `detected_language_count=0`; text/timing SHA unavailable. This logging order is a probe defect to fix before any authorized retry.

`ru_long_4.800`, measured rounds, and every release-phase case were never reached.

## Prompt selection is not detected-language output

Primary-source control flow at the pinned commit:

- `include/nemo_speech/asr.h:167–175`: `language_code` is explicitly documented as **prompt selection**.
- `src/asr/c_api.cpp:229–233`: the exact C string is copied into the C++ request.
- `src/asr/recognizer.cpp:461–469`: a prompt-capable model calls `set_prompt_index(model_->prompt_index_for_lang(language_code))`.
- `src/asr/model.cpp:1594–1608`: the exact GGUF prompt dictionary is loaded.
- `src/asr/model.cpp:1738–1747`: exact dictionary hit returns its prompt index; only unknown/empty strings fall back to `auto`.
- the pinned GGUF contains `ru-RU:11`, so this request selected 11, not `auto:101`.
- `src/asr/runner.cpp:925–940`: detected languages are populated only by extracting emitted `<lang>` tokens from decoded text.
- `src/asr/types.h:44–60`: a word language is empty unless detection tagged it, and alternative language codes are “detected languages, if any.”
- `src/asr/recognizer.cpp:327–365`: those optional detected tags, not the requested prompt, are copied into result alternatives.

Conclusion: an empty language result under an exact forced prompt is permitted by this ABI and does not prove silent fallback. A corrected gate must fail before inference if the requested exact prompt key is absent; it may record an empty detected tag but must not treat that alone as fallback. For stronger product evidence, add/read a selected-prompt accessor rather than infer it from decoded tags.

## Teardown root cause and bounded harness-only correction

The probe stores the recognizer in a raw pointer at `stage1_worker.cpp:406`, destroys it only on the normal path at line 537, and catches validation exceptions at lines 550–554. The Russian validation exception jumped directly to that catch, so the recognizer, its worker threads, and Metal residency set remained live. At process exit ggml asserted:

```text
GGML_ASSERT([rsets->data count] == 0) failed
```

The crash report shows `SIGABRT`, termination code 6, with `ggml_metal_rsets_free -> ggml_metal_device_free` during `__cxa_finalize_ranges`; it does not show a call to the ASR recognizer destructor.

Smallest safe harness-only correction, **not applied in this sealed run**:

1. Wrap recognizer, stream, and result handles in `unique_ptr`-style RAII deleters immediately after each successful C create; explicitly reset recognizer before returning either success or failure.
2. Serialize the complete result before validation so a hard-stop preserves exact output.
3. Replace `languages.empty()` failure for forced prompts with exact preflight membership/selected-prompt verification; continue hashing optional emitted tags.
4. Preserve all other hard gates, including final multiplicity, non-empty/catastrophic output, timing, measured RTF, release-phase exactness, and process reap.

No source/runtime/model fix is implicated by this teardown evidence. No retry was performed.

## Sealed artifacts

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| raw JSONL | 2,962 | `1884133ab53f025491e1cbd121e400b9239a9b2beff15b6bfbdf58f50772d0b7` |
| stderr + `/usr/bin/time` | 18,067 | `616e5f43f6d867c78d3ecc047688dbd12d87035310daf74a63d89b6acda47040` |
| model-info JSON | — | `81f4de76dfc88627abc6197cea9a740b557e8479678c438f2d86f0993c27970e` |
| crash report `stage1_worker-2026-08-14-215321.ips` | 16,992 | `1b4a553b23601c3fef1450b29c68e12f3493c7a67792ceefe678c0a293ffdb02` |
| pre-run thermal record | — | `96de6076213225f787270bff80efd2011e0ad142953c37697dc547f77d302892` |

Paths:

- `$TMP/nemotron35-stage1.UhkPS6/r6-results.jsonl`
- `$TMP/nemotron35-stage1.UhkPS6/r6-stderr.log`
- `$TMP/nemotron35-stage1.UhkPS6/model-info.json`
- `$HOME/Library/Logs/DiagnosticReports/stage1_worker-2026-08-14-215321.ips`

PID 15364 is reaped; no NeMo/Nemotron/stage1 worker remains; runner is free. Shared `git status --short` is empty.

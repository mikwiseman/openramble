# Exact closed-window precompute — temp-only evidence memo

Status: `DONE_WITH_CONCERNS`. Prototype establishes exact reuse of every provably closed non-final TDT long-form window on the tested English fixtures. It does not make the dormant preview state reusable, does not cover the optional CTC latency path, and is not product-ready.

## Pinned scope

- OpenRamble HEAD: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- FluidAudio base: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- Main model: `$HOME/Library/Application Support/OpenRamble/Models/parakeet-tdt-0.6b-v3/aed02740059203c4a87495924f685de3722ae9ce/parakeet-tdt-0.6b-v3`
- Configuration: `.all`; encoder `.int8/.all` (shipping 6-bit palettized encoder); preprocessor CPU; `melChunkContext=false`; parallel long-form concurrency 4; max tokens 600; dual decode off; pooled preprocessor input return uses `resetData:false`.
- Persistent warm process; five paired repetitions per fixture. Baseline was followed by cached in every pair, so latency magnitude is directional until a symmetric/randomized run; exact parity is unaffected.
- Shared checkout remained clean. All code and results live under `$TMP/openramble-stop-precompute-ee9a7f12`.

## Exactness condition

Shipping v3/no-mel uses a 239,360-sample (14.96 s) window, 32,000-sample (2.0 s) overlap, and 207,360-sample (12.96 s) regular stride. Silence-aligned start `i` searches around target `i * 207360` through the full ±4 s radius in 1,280-sample frames, with a ±1,280-sample energy window. A candidate is cached only after:

1. every recursively preceding start is stable;
2. prefix contains the complete ±4 s search plus the 80 ms right energy half-window;
3. complete 14.96 s window input exists;
4. at least one sample exists beyond candidate end, proving `isLastChunk == false`;
5. audio has crossed 240,000 samples, proving the final route is long-form.

At stop the prototype recomputes the complete shipping plan and rejects reuse unless manager identity, language, every plan field, and every Float input bit match. Cached windows were decoded from a fresh/reset `TdtDecoderState` with `isLastChunk=false`; the final window is always recomputed because `isLastChunk=true` activates a distinct boundary flush. Cached token IDs, timestamps, confidences, and durations enter the unchanged ordered merge, timestamp sort, and seam-dedup path.

## Benchmark result

All transcript and full token-timing hashes were stable within baseline and cached lanes and exactly equal across lanes for all 25 pairs. All scheduled non-final windows were ready before simulated stop.

| Fixture | windows final/cached | stop baseline p50/p95 ms | stop cached p50/p95 ms | p50 speedup | total precompute ms | speech duty | minimum ready slack | duplicated cache input | transcript SHA-256 | timing SHA-256 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| real product-names 56.104 s | 5/4 | 174.248 / 185.886 | 57.755 / 58.961 | 3.02x | 312.465 | 0.5569% | 2.025 s | 3,829,760 B | `0f2125c9be9e66cd13f68f63934321b36e3ad2695b3ca42a05e104f0ed7fdba8` | `b354d9e15956f1facd5a08941aabbddcaf00d079e3f916ed43850131a0e93e0b` |
| real whole-earth 84.381 s | 7/6 | 233.775 / 238.552 | 67.210 / 68.706 | 3.48x | 462.786 | 0.5484% | 8.315 s | 5,744,640 B | `05e6026aacc3bc492774953e81aa2900281e16a39e19d962b690b0cc88de0fb1` | `b654366739108cf21d3c54aaea40342b17730c37d509864bb9149c1ee8f30f2f` |
| synthetic repeat 60 s | 5/4 | 179.618 / 181.040 | 73.136 / 75.061 | 2.46x | 276.294 | 0.4605% | 10.096 s | 3,829,760 B | `3ea89c7ba5c94a327cdd16cbef24c7c10b43fbf681a8e42bb3882de7e4275f18` | `d33402af9a5d76ba73eb6eabf36a8584422eca5f3bf4acff53be629a42034032` |
| synthetic repeat 120 s | 10/9 | 300.806 / 303.585 | 54.511 / 54.862 | 5.52x | 569.439 | 0.4745% | 4.815 s | 8,616,960 B | `5d76ba3657cc90c8c653cbb74fea8043718d3ee082b743c0b6d2d0fbe03d2b28` | `7c67b0971478c3dd96bd7fe0f77ec0601aaac15a0a437d173d67bf50c04f5600` |
| synthetic repeat 300 s | 24/23 | 747.686 / 756.985 | 64.766 / 71.516 | 11.54x | 1,635.115 | 0.5450% | 3.604 s | 22,021,120 B | `a1ce53b6f729e8b4315090a0a269f4359ac045742a98b8d0704100dc370f3141` | `88a244d404a5d75fb3017504a05f39d0a88de3087b38c513b7f7eb69c7d7e2b4` |

Synthetic audio is an in-memory cyclic repeat of frozen `boundary-en-repeat-15.1s` (source file SHA-256 `e8a97e9ec6534cdf5cb7b22ee6a9cfa9dc8bdeaa633d43c4a098a28eff5fddec`). Sample-data hashes are recorded in the JSON report.

The schedule is reconstructed from exact earliest-safe prefixes but the benchmark invokes precompute back-to-back on already frozen audio; it is not a live microphone/event-loop run. Measured warm calls were about 63–84 ms and windows closed roughly 13 s apart, so no simulated backlog occurred. The shortest measured slack was 2.025 s. A prior 15.1 s boundary run had only about 100 ms of speech slack for the first cache and is contention-sensitive.

The preceding first-window-only boundary proof (`closed-cache-n5.json`, five pairs) also had exact stable transcript/timing hashes: 15.1 s p50 77.798→42.648 ms (1.82x, earliest-safe prefix 15.0000625 s, only 99.94 ms speech slack); 29.9 s 107.759→78.603 ms (1.37x); 30.1 s 109.383→100.615 ms (1.09x); real 56.104 s 170.720→168.831 ms (1.01x). The weak long-audio improvement is expected because this earlier prototype removed only window zero while shipping concurrency 4 hid it; it motivated the all-closed schedule above.

## Resources and environment

- Model load: 13,547.969 ms.
- Process-wide lifetime peak RSS: 2,296,676,352 B (2.139 GiB). This includes loaded models plus all fixture/sample/cache allocations and is not incremental cache RSS.
- Exact duplicated Float input retained for the research bit-equality guard: 0.96 MB per cached window; 22,021,120 B (21.001 MiB) at 300 s. Token arrays add a small unisolated amount. Product should use immutable capture storage/range identity instead of duplicating each window.
- Power/energy: not instrumented; no mW/J claim is supported. Inference duty as a fraction of speech wall time was 0.4605–0.5569%, but this is not a power measurement.
- Thermal: no macOS thermal-pressure warning was present in the preflight used for the run; no continuous sensor/powermetrics trace was captured, so no thermal-neutral claim is supported.
- ANE/runner was released immediately after this benchmark; no further Core ML lane was started.

## Why existing preview cannot seed exact final output

Production currently streams capture samples only into waveform peak calculation, then sends the complete frozen Float buffer through the worker after stop. The worker protocol exposes whole-buffer/file transcription only and serializes operations through one gate.

The dormant `FluidAudioAdapter.startPreview` creates `SlidingWindowAsrManager` with 1.0 s center, 0.5 s hypothesis, 0.5 s left and 0.25 s right context. It always uses language autodetection, keeps a private sequential decoder state and accumulated tokens, publishes only confirmed/volatile strings to the adapter, and `stopPreview` calls `cancel()` and discards the manager rather than `finish()`. This is a pseudo-streaming offline encoder over a different overlap/merge/state history. Offline final long-form instead uses independent 14.96 s windows, a fresh decoder state per window, silence-aligned starts and its own token/timing merge. Preview state is therefore not an exact reusable seam.

## Short-audio verdict

For audio at or below 15 s, exact partial-prefix continuation is impossible with the installed shipping encoder graph. It has fixed input `[1,128,1501]`, output `[1,1024,188]`, empty Core ML state schema, and 24 full `[1,8,188,188]` attention softmax blocks. `mel_length` changes the full attention mask; future valid frames can alter earlier encoder representations and the subsequent greedy TDT path. A prefix result can be speculative only and must be fully replayed at stop. A real exact streaming route requires a separately trained/exported cache-aware encoder, not the dormant sliding-window preview.

## Product seam and unresolved risks

Minimal seam is a session/generation-keyed worker protocol that accepts append-only PCM prefixes, coalesces one background non-final-window job at a time, and hands completed/in-flight cache ownership to final transcription. It must fingerprint model revision, configuration, language and vocabulary; invalidate on restart/change; prioritize stop over background work; preserve cancellation/progress; and reuse the existing model instance.

Optional vocabulary CTC remains unresolved. Final TDT text/timings determine selected CTC candidate regions, so exact TDT caching preserves candidate selection, but this prototype does not cache CTC. With vocabulary active CTC can remain on the stop critical path and may dominate.

Other gaps before integration: live capture/worker contention and stop-race tests, auto/multilingual parity, continuous power/thermal evidence, incremental RSS measurement, bounded cache lifetime, symmetric randomized latency repetitions, and failure-safe fallback when any final-plan or sample identity check misses.

## Audit hashes

- Main report: `all-closed-cache-n5.json`
- Main report SHA-256: `1d1d12808efd58a351470d7f38f0034254619258b5eae014fbc7ebad6f08c7a0`
- Prototype git diff SHA-256: `ebb5383dca4d1bb3ea08d9d84f7c39be005b9383420118a73f3864cced1b59be`
- Earlier first-window-only report SHA-256: `d205304469cb1df7716c5e5acb89a0911cd8dedaf23972c57ccf76df3adb2cef`

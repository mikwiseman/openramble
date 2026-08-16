# Cross-platform notes (parked 2026-08-16)

Status: **parked by Mik** — "forget cross-platform for now"; recorded here so the
findings survive until the discussion reopens. Source: code-level study of
Handy `db003f38` (+ main `98a4d80`) and the `transcribe-cpp` 0.1.3 crates,
2026-08-16.

## Decisions already taken (provisional, to re-confirm when reopened)

- Shell stack: **Tauri v2 + Rust** (Handy proves the whole category for
  dictation: global hotkeys, tray, paste, overlay, updater). UI = webview,
  i.e. any HTML/CSS design — matches Mik's taste (dislikes Swift/native feel).
- Second platform: **Windows** (ONNX Runtime + DirectML for GPU on any
  vendor), Linux after.
- **Open question, deliberately deferred** (Mik wants to re-discuss): keep the
  Swift/Core ML worker as the macOS engine behind the existing
  `ASRWorkerProtocol` framed-pipe seam (preserves the measured 1.5–6.6× speed
  edge over ggml on macOS and the whole tested worker lifecycle; Swift hidden
  inside one binary) vs one engine everywhere (simpler; the archive already
  measured the macOS cost: transcribe.cpp 123.49 ms vs Core ML/NE 71.30 ms p50
  feature-parity, long fixtures ~2.7× worse).

## How Handy is built (facts)

- Tauri v2; engine manager `src-tauri/src/managers/transcription.rs`.
- STT crates: `transcribe-cpp` 0.1.3 (+`-sys`, crates.io) — MIT, from
  github.com/handy-computer/transcribe.cpp @ `a94e021e`; **not** a whisper.cpp
  fork; from-scratch multi-arch ASR runtime on vendored ggml (MIT). macOS
  backend Metal (`GGML_METAL_EMBED_LIBRARY=ON`), Linux/Win-x64 Vulkan,
  Win-ARM64 static CPU. Legacy `transcribe-rs` 0.3.8 = ONNX path only.
  `vad-rs` (Silero v4) for VAD.
- Model: `handy-computer/parakeet-tdt-0.6b-v3-gguf` Q8_0, 739,508,576 B,
  CC-BY-4.0 (base `nvidia/parakeet-tdt-0.6b-v3`).
- **No mmap.** Loader streams GGUF tensors via `ifstream` into backend
  buffers (`transcribe-load-common.cpp:438-490`) — dirty anonymous memory.
- Why reload is cheap anyway: plain ~705 MB sequential read (~0.2–2 s), and
  the **Metal device/shader library/pipeline cache are process-lifetime
  statics that survive model unload** — no equivalent of Core ML's e5rt/ANE
  specialization at load. Cold *first* Metal library init ~6.6 s once; later
  loads ~0.2 s; model load median ~208 ms.
- Residency habits (the part we adopted for v0.8.0): load kicked at
  hotkey-down concurrently with recording; `transcribe()` blocks on a Condvar
  until loaded (wait-and-insert); idle unload via `ModelUnloadTimeout`
  (Never/Immediately/2/5/10/15 min/1 h, default 5 min), watcher wakes every
  10 s, `touch_activity()` during recording; panic containment via
  `catch_unwind` → engine dropped → auto-reload next attempt.
- ggml has a real anti-eviction mechanism (`MTLResidencySet` + 5 ms heartbeat,
  `keep_alive_s` 180) — Handy main **disables** it
  (`GGML_METAL_NO_RESIDENCY=1`, teardown-assert workaround, #1902).
- Per-chip logic: none. Only a capability gate — pre-`MTLGPUFamilyApple7`
  GPUs skipped under AUTO because ggml fallback matmul silently corrupts
  transcripts (#1608). Threads: crate defaults, affinity-aware.
- No memory-pressure handling, no warmup inference, no App Nap handling.
- Other techniques worth remembering: short-clip pad to 1.25 s of zeros
  (mel front-end NaNs under 2 frames); receipt-sequenced clipboard restore
  (restores old clipboard only after the OS reports a consumer read it,
  #502); Secure Event Input detection with Carbon shadow-registration
  fallback; 30 ms hotkey debounce / 50 ms release grace; GGUF metadata as
  capability ground truth (validated pre-download via HTTP Range header
  read); explicit engine drop before Tauri exit (ggml-metal static-destructor
  SIGABRT).
- Critique (why not to copy wholesale): engine runs in-process — no crash
  isolation (our supervised worker + generation fencing is stronger and
  should carry over to any future shell); settings sprawl; quality/latency
  on macOS measurably behind our Core ML path.

## Licenses

Handy MIT (© 2025 CJ Pais); transcribe-cpp/-sys MIT; vendored ggml MIT;
Parakeet GGUF CC-BY-4.0. Code and techniques adoptable with attribution.

## Where the deep evidence lives

- This repo: `research/asr-performance-2026-08/` (engine audits, fair n=50
  Handy benchmark, transcribe.cpp rejection memo
  `evidence/curated/openramble-short-engine.SpfSeY/REPORT.md`).
- Plan-file git history for the v0.8.0 program and the parked long-form
  speculative-cache design.

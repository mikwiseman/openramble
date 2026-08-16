You are an independent senior performance engineer. Work READ-ONLY: do not edit or write any repository files. Think deeply and inspect both codebases with available read/search tools.

Primary repository (cwd): $REPO
Comparison repository: /tmp/handy-source.xMtr8W at commit 549cbde3ebb72459f7f7230783931a45222018a1

Goal: make OpenRamble macOS dictation stop-to-text latency at least as fast as Handy when the user selects the same base model, NVIDIA Parakeet TDT 0.6B v3, without degrading mixed Russian/English recognition, long dictation reliability, local-only privacy, personal vocabulary, or minimal UX.

Known observation to verify, not assume: Handy's GGUF path uses transcribe-cpp/Metal and opens a stream at recording start, feeding 16 kHz PCM and calling finalize at release. OpenRamble uses FluidAudio/Core ML; it runs SlidingWindowAsrManager for visual preview during recording, then cancels that preview and re-runs the complete WAV through AsrManager batch transcription. User observes OpenRamble about 2–3x slower.

Inspect the complete relevant pipelines, not just these files. In OpenRamble prioritize FluidAudioAdapter.swift, LocalTranscriber.swift, DictationController.swift, MicrophoneCapture.swift, AppState.swift, benchmark/test files, and the pinned FluidAudio checkout. In Handy prioritize managers/transcription.rs, managers/audio.rs, actions/coordinator, catalog and dependency code/lockfile, plus transcribe-cpp/transcribe-rs behavior visible from sources or metadata.

Deliver:
1. A phase-by-phase latency comparison from key release to paste, separating capture drain, copies/file I/O, feature extraction, encoder/decoder, language detection, vocabulary, post-processing, and paste.
2. Ranked root causes with confidence and expected size.
3. Three architecture options: promote FluidAudio streaming finalization, adopt Handy's transcribe-cpp native GGUF backend, or optimize current Core ML batch path. Include accuracy, memory, packaging/license/security, maintenance, and implementation risk.
4. A concrete recommended implementation plan with exact symbols/files, tests and benchmarks. Be explicit about whether C++ is necessary.
5. Look for hidden pitfalls: current preview config quality, language hint absence, acoustic vocabulary behavior, duplicated inference, audio copies, actor serialization, Core ML compute units, 15s chunking, VAD differences, release/debug build effects.

Do not produce generic advice. Cite exact code locations and call flows. Challenge the premise if evidence points elsewhere.

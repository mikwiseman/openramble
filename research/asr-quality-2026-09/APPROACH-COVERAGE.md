# Approach coverage on the current runtime

The archived [experiment inventory](../asr-performance-2026-08/EXPERIMENTS.md)
contains Core ML/FluidAudio work. It is evidence about that retired backend;
it does not establish the speed or quality of transcribe.cpp 0.2.3. The current
study follows each applicable question without reusing those numerical claims.

| Question or approach | Current evidence and next step |
|---|---|
| Model accuracy and resources | All three original Q8 models completed 2000 main, 72 grouped short synthetic and 1422 FLEURS examples each; domain-level results and failures are retained in [RESULTS](RESULTS.md) |
| A faster Russian specialist | GigaAM E2E CTC completed 100 RU development, 1500 main RU, 30 short synthetic RU and 775 FLEURS RU examples; faster, better Common Voice, worse Crowd/technical scripts, and one missing-word-timing failure |
| Other compatible checkpoints | primeLine regresses on the 100 RU + 100 EN development screen. GigaAM RNN-T ties CTC on 100 RU, is slower and has no confirmed gain on its extra 15-RU critical development screen; no universal replacement |
| Decoder hints/context | Shipping Parakeet weights contain no prompt table; source inspection of 0.2.3 makes language conditioning depend on that absent table. Do not infer a working prompt from the generic C parameter or a family-level documentation claim |
| Acoustic vocabulary rescoring | The former secondary FluidAudio CTC path is removed. Current evidence measures the shipping Rust starter/phonetic text pipeline, not an unmeasured acoustic rescue |
| Exact text corrections | A narrow mixed-script alias improved two development outputs, with zero changes on main, synthetic holdout and FLEURS; retain as research until independent benefit is shown |
| Shorter windows / VAD endpoints | Short takes stay unsplit. An observed 37-word mixed omission is recovered on a short crop of identical PCM. One isolated 20s-window development experiment lowers mixed WER 14.50% relative, but negative-marker nonmatches rise 3 to 5; reject for production. Independent labels/seam evidence remain required. See [window diagnostic](window20-diagnostic/PROTOCOL.md) |
| Long files / seams | Unique offline full RU/EN/mixed parents last 24m24s/18m19s/22m32s; Parakeet succeeds in 31.665/23.418/29.037s with app WER 2.88/1.11/17.21%. Mixed omissions/negative markers fail a general safety gate; Turbo/Breeze fail with native code 12. Independent reference seam timings and primary Eleven v4 4/5/8/15-minute tracks still await quota reset. See [RU](system-long-diagnostic/PROTOCOL.md) and [EN/mixed](system-long-extra/PROTOCOL.md) protocols |
| Closed-window caching / speculation | Historical exact-cache timings exclude work during speech and have no current-runtime or GUI guarantee; no shortcut may discard PCM or preempt a native call merely by ignoring its result |
| Streaming alternatives | Canary requires a language hint, Moonshine lacks RU and timestamps, SenseVoice lacks RU. These fail the current automatic RU/EN file-pipeline compatibility filter |
| Zipformer, Nemotron, Apple Speech and other runtimes | The archived inventory records language-token/adapter blockers for Zipformer, incomplete or rejected Nemotron runs, unsupported RU/product semantics for Apple Speech, and source-only Qwen/Vosk audits. None runs through this study's existing adapter; no archived speed claim is promoted as a current result |
| Encoder quantization and graph fusion | The old Core ML static shapes, MultiFunction packaging, int8/four-bit and fused joint graphs are backend-specific and previously rejected. Five additional precisions of the exact shipping GGUF completed 200 development examples each; none reaches the accuracy gate. Q4 reduces process memory by about 29%; first-pass timing is not an idle speed gate. See [precision screen](QUANTIZATION.md) |
| Thread topology / scheduler | Keep the shipping one-thread Parakeet decoder and predeclared four-thread Whisper controls. Queue and native inference timers remain separate; no rerun of the already established thread experiment |
| Application Stop-to-insertion | Published 0.31.2 installed and native model load verified. CUA cannot bind its menu-bar-only surface and rejects the actual modifier-only Right Control before sending input; GUI timer remains unmeasured |
| Profile and idle latency | Completed frozen ABBA predecoded short timing and a separate five-second native profile. Parakeet RU p95 is 151-152 ms, GigaAM CTC 75 ms; neither timer includes GUI insertion. Profiled rows are excluded from acceptance |

Primary compatibility sources are the pinned
[Canary](https://github.com/handy-computer/transcribe.cpp/blob/63a44d9239d610b3908e8a66b384924cd4a77217/docs/models/canary.md),
[Moonshine](https://github.com/handy-computer/transcribe.cpp/blob/63a44d9239d610b3908e8a66b384924cd4a77217/docs/models/moonshine.md),
[SenseVoice](https://github.com/handy-computer/transcribe.cpp/blob/63a44d9239d610b3908e8a66b384924cd4a77217/docs/models/sensevoice-small.md),
[GigaAM](https://github.com/handy-computer/transcribe.cpp/blob/63a44d9239d610b3908e8a66b384924cd4a77217/docs/models/gigaam.md)
and [primeLine](https://github.com/handy-computer/transcribe.cpp/blob/63a44d9239d610b3908e8a66b384924cd4a77217/docs/models/parakeet-primeline.md)
contracts. Published model-card WER, including scores on FLEURS, is outside
this study's measurements and may share training/evaluation exposure.

For language conditioning, inspected `src/arch/parakeet/weights.cpp` and
`model.cpp` at that same commit. The actual shipping GGUF has 58 metadata
fields ending at offset 180009 and no prompt key. This reconciles the generic
prompt-capable code with the shipping checkpoint; it does not justify adding
a language switch or retrying the retired configuration sweep.

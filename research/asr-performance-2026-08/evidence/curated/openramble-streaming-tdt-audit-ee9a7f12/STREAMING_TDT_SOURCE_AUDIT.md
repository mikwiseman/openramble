# Stateful SlidingWindow TDT source/CPU audit

Date: 2026-08-14
Scope: read-only shared repository; temp-only CPU prototype; **no Core ML/model inference was run**.
Decision state: source gate complete; model gate not requested and not authorized.

## Executive verdict

The pinned `SlidingWindowAsrManager` is not an exact incremental form of OpenRamble's shipping recognizer. It is explicitly an offline, fixed-input TDT encoder repeatedly applied to overlapping windows. FluidAudio's own compile-time test intentionally excludes it from the `StreamingAsrManager` protocol for that reason.

Three consequences are decisive:

1. The production app does not currently call the preview API. During capture, its `onSamples` path only computes a UI waveform peak. On Stop it freezes complete PCM and starts the authoritative offline worker request.
2. The existing preview cannot be promoted to final. It has no language input, is configured with FluidAudio defaults (`melChunkContext=true`, `maxTokensPerChunk=150`) rather than shipping (`false`, `600`), uses a different window/dedup algorithm, and `stopPreview()` cancels and discards it. Its streaming vocabulary path is also not OpenRamble's final `candidateRegions` scheduler.
3. For recordings up to 15 seconds, no exact offline-equivalent Stop-latency saving is exposed by this graph. Every final partial window is padded to 240,000 samples and executes the full preprocessor + non-causal offline encoder after the final sample. There is decoder state, but no encoder/mel/KV cache. Earlier prefix encodings cannot be reused as the exact full-context offline encoding after more samples arrive.

Therefore this lane is viable only as a speculative, quality-gated candidate with the already-lossless complete PCM as an unconditional offline fallback. It must hard-stop on a four-fixture engineering smoke before touching the untouched 204-fixture corpus. The source shape predicts that the current one-second preview geometry is unlikely to clear a material short-utterance Stop-latency gate: a 1–4 second take performs 2–4 fixed-15-second frontend calls in total and still requires one fixed frontend call during final flush.

For exact long-form acceleration, the stateful manager is the wrong seam. Shipping long-form uses independently reset, silence-aligned ~14.96-second windows, parallel workers, and timestamp-aware merge. Reusing only byte-identical, already-closed shipping windows is the exact architecture; it is a separate cache design, not `SlidingWindowAsrManager` state reuse.

## Pins and evidence identity

- OpenRamble commit: `f2b6e8cc66d20f7a07094f79af0faf3ba861af64`
- OpenRamble tree: `74c38d68771de3f50ac0d78f79182d2b725d8d2d`
- FluidAudio commit: `ee9a7f12d91710da53de6d75f8b7160e09eccee4`
- FluidAudio tree: `02dc7895b0e4b1ce087e943e3bde5a92f8d85855`
- Main manifest SHA-256: `05046d2b0b12fcfcf82625256bbf606eed198a064a73f979b5b2b3a617f0f78b`
- Main model revision: `aed02740059203c4a87495924f685de3722ae9ce`; 21 manifest files; 483,105,645 bytes
- Installed main model tree digest: `66e79161c28717a7869b552453eab474975e801ba5dee28a964d79f952690dff`
- Vocabulary manifest SHA-256: `79948cb9dcc9da6410b8fcefb9eba40bec05be50e3a7e98de52f6e87c9bbc3c9`
- Vocabulary model revision: `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`; 16 manifest files; 102,803,869 bytes
- Installed vocabulary model tree digest: `eb90809a5ac7ead5b2f3c3ca95b4040945b43f9deeeb6de6cbde6e4152c48a2a`
- Shipping config SHA-256: `98338d07767b45d3abaf222a790b6070b4a0dae6291343034cd7b91f16f3c59b`
- Host used only for CPU audit: macOS 26.4 build 25E246, arm64; Swift 6.3.3.

The tree-digest recipe is SHA-256 over sorted lines of `file_sha256 + two spaces + relative_path`. No model file was opened through Core ML in this task.

Important source hashes:

| Source | SHA-256 |
|---|---|
| `SlidingWindowAsrManager.swift` | `714fb83c15f6d53955a5240205f90b85890731c9a1632aa82108bace7e81b14a` |
| `AsrManager+Transcription.swift` | `46da4ac172e1cfc0ecfd747565860704edc79f0dcdbd8e894fd8890e2fc731f5` |
| `AsrManager+Pipeline.swift` | `52f97ede69ea78302326a75d46964f11fec1a9982576fadb8b0d343291fa88ab` |
| `TdtDecoderState.swift` | `594c949dd47aa9b4015054fe04386d4f4229c4888571c36052e7d4656261f087` |
| `TdtDecoderV3.swift` | `d4f6c1f78b83bdcc7ea241fb1c5be3fbc5aebf8e3dd158c301a5d44eb8cb9cb8` |
| `TdtFrameNavigation.swift` | `07b109a94dfc771e596478b696523e8113f34bdf87712d27c49bc776a8b91e84` |
| `ChunkProcessor.swift` | `90bc4f094badb2a622b5bf11df420421a7cd849bedde6c1688a745a62f263014` |
| `FluidAudioAdapter.swift` | `dccb9d2099bc53dfcd3d8f67a505d97d8a22e5acfd86f889e6da18de3dba8d06` |
| `MicrophoneCapture.swift` | `561d9c959d9a62155eb59517cb2d38319507a0d7103e13c46c98ffdb299906b3` |
| `ASRWorkerProtocol.swift` | `e7e7ca6c123d1c4e8004c29f2842630af132b02ef9d9bd6eea13dd6566b2d8e1` |
| `ASRWorkerSupervisor.swift` | `740760db07b69efd65895e2b6ec91d6794250e778bdd112a652b4c7c2de6807f` |
| `WorkerRuntime.swift` | `5342f6d6784abe68d0db57182f6b0c41ac25d2ed3997183cd290feca32cbb889` |

## Actual current call graphs

### Shipping product final

```text
hotkey down
  -> DictationController.begin
  -> MicrophoneCapture tap (2048 input frames)
  -> ordered conversion to 16 kHz mono Float32
  -> RecordingPCMBuffer.append (lossless immutable chunk chain)
  -> disk best effort + coalescing UI peak only

Stop/key up
  -> DictationController.finish/finalize
  -> MicrophoneCapture.freezeRecording
       close callback admission
       cancel pending conversions
       detach engine/context
       wait for already-entered conversion callbacks
       flatten exact PCM once
  -> ASRWorkerSupervisor.transcribe(samples:languageHint:)
  -> one whole-PCM wire request
  -> WorkerRuntime -> LocalTranscriber -> FluidAudioAdapter
  -> AsrManager.transcribe
       <=15 s: one padded fixed frontend + TDT final decode
       >15 s: stateless ChunkProcessor plan + merge
  -> lexical candidateRegions from final TDT text/timings
  -> selected CTC windows + final rescore
  -> result -> controller -> text pipeline/insertion
```

Evidence:

- `AppState.system()` constructs the worker supervisor and capture at `apps/macos/OpenRamble/AppState.swift:173-215`.
- The only production `onSamples` work is peak metering at `AppState.swift:625-630`.
- Stop is single-entry and records the monotonic user Stop at `DictationController.swift:628-687`.
- Capture freeze is separately capped at 500 ms by default at `DictationController.swift:698-718`; authoritative PCM is selected at `837-943`.
- Freeze closes admission, waits for in-flight CPU conversion, and returns the complete snapshot at `MicrophoneCapture.swift:3091-3164`.
- The worker currently receives all samples in one request at `ASRWorkerSupervisor.swift:321-349` and copies payload into a new `[Float]` at `WorkerRuntime.swift:153-172`.
- Offline TDT followed by product vocabulary scheduling is at `FluidAudioAdapter.swift:748-929`.

### Dormant eyes-only preview

```text
LocalTranscriber.startPreview
  -> FluidAudioAdapter.startPreview
  -> new SlidingWindowAsrManager using the already-loaded AsrModels references
  -> manager.startStreaming
  -> one Task consumes an AsyncStream<AVAudioPCMBuffer>

feedPreview([Float])
  -> allocate AVAudioPCMBuffer + copy samples
  -> manager.streamAudio (unacknowledged AsyncStream.yield)
  -> stateless resample per buffer
  -> appendSamplesAndProcess
  -> transcribeChunk for every assembled window
  -> fixed preprocessor + fixed encoder + stateful TDT decoder/joint
  -> heuristic prefix-token dedup + volatile/confirmed update

stopPreview
  -> cancel update consumer
  -> manager.cancel
  -> discard manager and all preview text
  -> shipping offline final still starts from full PCM
```

`rg` over all Swift production sources found no app call to `startPreview`, `feedPreview`, or `stopPreview`; only `LocalTranscriber` wrappers and tests refer to them. The source itself labels preview text as eyes-only at `FluidAudioAdapter.swift:258-260`.

## Exact SlidingWindow state and processing semantics

`SlidingWindowAsrManager` is an actor. Its mutable session state is:

- immutable, one-shot input `AsyncStream` + continuation;
- one `AsrManager` holding shared model references;
- one recognizer task;
- `TdtDecoderState`;
- current segment/frame counters and all accumulated token IDs;
- raw sample buffer plus absolute buffer/window indices;
- volatile and confirmed text;
- processed/failed window counters;
- optional streaming vocabulary spotter/rescorer.

Source: `SlidingWindowAsrManager.swift:10-64`.

The only actual cross-window neural state is the TDT predictor state:

- LSTM hidden and cell arrays shaped `[decoderLayers, 1, 640]`;
- last token;
- cached predictor output;
- `timeJump` decoder position.

`finalizeLastChunk()` clears predictor output and `timeJump` but preserves LSTM state and last token (`TdtDecoderState.swift:4-95`). There is no encoder activation, attention KV, convolution, or mel cache.

Every window executes:

1. frame alignment and padding to `ASRConstants.maxModelSamples = 240000`;
2. preprocessor prediction;
3. encoder prediction;
4. TDT decoder/joint loop using the persisted decoder state.

Source: `AsrManager+Transcription.swift:55-90` and `AsrManager+Pipeline.swift:6-93`. Cancellation is checked before preprocessor and encoder and inside decoder loops, but the awaited Core ML prediction itself has no stronger wrapper (`MLModel+Prediction.swift:4-11`).

For the app's current preview geometry (`chunk=1.0`, `left=.5`, `right=.25`):

- first processing becomes eligible at 1.25 seconds;
- subsequent center starts advance exactly one second;
- steady windows contain up to 1.75 seconds of real audio;
- all are nevertheless padded to 15 seconds;
- a 1–4 second fixture produces `ceil(duration_seconds)` frontend calls total;
- because right lookahead keeps the next center behind the audio end, Stop flush has a remaining final window and executes one last fixed frontend call.

The loop and trimming are at `SlidingWindowAsrManager.swift:346-383`; flush removes the right-context requirement and marks only the last remaining window as `isLastChunk=true` at `385-424`. TDT finalization runs an extra decoder/joint loop until blank termination or its bound at `TdtDecoderV3.swift:469-600`; it is not equivalent to returning the last partial update.

The public `hypothesisChunkSeconds` value is never read by the manager's processing path. Its only source uses are declaration, initialization, copying, and an unused computed sample property (`SlidingWindowAsrManager.swift:709-853`).

Cross-window stitching is heuristic, not exact offline continuation. `transcribeChunk` passes `contextFrameAdjustment=0`, then removes a suffix/prefix token match capped at 12 and a bounded substring match (`AsrManager+Transcription.swift:55-90`, `AsrManager+TokenProcessing.swift:110-162`). The source calls the dedup a temporary workaround. Frame navigation also has a hard-coded special case that skips the standard 2-second/25-frame overlap when `prevTimeJump==0 && contextFrameAdjustment==0` (`TdtFrameNavigation.swift:20-48`), while the app's physical preview overlap is .75 seconds. This must be treated as a correctness risk, not assumed aligned.

## Why preview final semantics differ from product final

| Dimension | Shipping offline final | Current preview | Required fair temp candidate |
|---|---|---|---|
| Language | Exact explicit `Language` per request or auto | Cannot receive a language hint | Store and pass the exact request language to every window |
| TDT ceiling | 600 tokens/window | FluidAudio default 150 | 600 |
| `melChunkContext` | `false` | Fresh manager uses default `true` | `false` (irrelevant for stateful chunk calls but identity must match) |
| Long concurrency | 4 independent workers | Sequential stateful decoder | Record 4 as product identity; stateful path remains sequential |
| Frontend | One full window for <=15 s; stateless ~14.96 s windows above | 1-second center / .5 left / .25 right | Same preview geometry for the first engineering gate |
| Window boundary | Full utterance or silence-aligned ±4 s search | Fixed one-second centers | Fixed one-second centers; explicitly non-equivalent |
| Decoder state | Fresh for each short take and every long window | Persisted LSTM/token/timeJump | Persisted; one manager per take |
| Merge | Rich timestamp-aware long-window merge | token prefix/substring heuristic | Same stateful candidate; expose exact raw data |
| Vocabulary | Final text/timings -> candidateRegions -> selected CTC windows -> rescore | Optional CTC over each confirmed current window | Disable manager vocab; run exact product final scheduler after `finishDetailed` |
| Stop | Starts authoritative recognition | `cancel()` and discard | Seal/ack every committed frame, `finishDetailed`, then product vocabulary |
| Result | final text, words, vocabulary phase/outcome | `String` from `finish`; partial updates have no final marker | text + raw tokens/strings/times/durations/confidences + words + vocab outcome + counts |

The configuration mismatch is concrete:

- Product adapter defaults are `maxTokensPerChunk=600`, concurrency 4, `melChunkContext=false`, and `candidateRegions` (`FluidAudioAdapter.swift:310-369`, `456-462`).
- `SlidingWindowAsrConfig.asrConfig` constructs `ASRConfig(sampleRate:tdtConfig:)` only (`SlidingWindowAsrManager.swift:815-821`). `ASRConfig` therefore defaults to `melChunkContext=true` (`AsrTypes.swift:64-84`) and `TdtConfig` defaults to 150 tokens (`TdtConfig.swift:10-33`).
- The app source warns that preview cannot accept the selected language (`FluidAudioAdapter.swift:610-618`).

The vocabulary algorithms are also different. Preview's optional path runs CTC on the complete current window when that window happens to cross a confidence/context confirmation threshold (`SlidingWindowAsrManager.swift:487-521`, `578-648`). Shipping first derives lexical candidate regions from the complete final TDT transcript/timings, then executes only the selected exact 15-second CTC windows (`FluidAudioAdapter.swift:836-910`, `958+`). A preview-rescored string cannot stand in for the product vocabulary result or its outcome.

## Lifecycle and correctness blockers in the current API

These are source blockers for production finalization, not observed model failures:

1. **Unbounded, unacknowledged input.** `AsyncStream.makeStream()` defaults to `.unbounded`; the manager uses that default at `SlidingWindowAsrManager.swift:71-74`. `streamAudio` ignores `yield`'s result and returns `Void` at `221-225`. The caller cannot know whether PCM is owned before calling `finish`.
2. **One-shot, non-reusable input.** `finish()` permanently finishes the immutable input continuation. `reset()` clears arrays but cannot create a new stream (`240-319`). Reusing the instance after finish cannot accept audio.
3. **Incomplete start reset.** `startStreaming()` resets segment/tokens/errors but not `processedChunks`, transcripts, sample buffer, or absolute indices (`163-186`). It also has no active-task guard even though an error case named `streamAlreadyExists` exists.
4. **Partial failure is returned as success.** `finish()` throws only when zero windows succeeded. If one succeeds and later windows fail, it logs a warning and returns an incomplete transcript (`256-269`). An authoritative path must fail closed on any failed window.
5. **Cancellation is not a join.** `cancel()` finishes input, calls `recognizerTask.cancel()`, and returns without awaiting task exit (`330-337`). A Core ML call may still occupy compute when offline fallback begins. `cleanup()` immediately proceeds to manager cleanup after that non-join.
6. **Output stream is not finalized by normal finish.** `finish()` never finishes `updateContinuation`; a consumer awaiting updates can remain suspended. `SlidingWindowTranscriptionUpdate` has `isConfirmed`, not an end-of-stream/final identity (`855+`).
7. **Single-subscriber race.** Every access to `transcriptionUpdates` replaces one stored continuation; an older subscriber's asynchronous termination can clear the newer continuation (`227-237`).
8. **No final detailed result.** `finish()` returns only `String`; accumulated token IDs are private, absolute timing/confidence/duration arrays are not returned, and window/error counts are private. Product parity cannot be audited through the public API.
9. **No language seam.** `startStreaming` has no language parameter and `processWindow` does not pass one to `transcribeChunk` (`426-450`).
10. **No frame-partition contract.** `feedPreview` allocates and copies each arbitrary sample array into `AVAudioPCMBuffer` (`FluidAudioAdapter.swift:692-709`); no sequence, absolute offset, PCM digest, bounded ownership, or final count crosses the API.

FluidAudio itself documents the architectural distinction: `StreamingAsrManagerTests.swift:21-27` says SlidingWindow TDT intentionally does not conform because it uses an offline encoder. The true-streaming protocol is separate (`StreamingAsrManager.swift:4-59`).

## Production-like lossless capture API

Do not reuse `CoalescingSampleObserver`. Its source explicitly says frames may be coalesced/dropped, carry no session identity, and must not be used for streaming ASR, VAD, persistence, or any content-sensitive consumer (`MicrophoneCapture.swift:1762-1808`, `2460-2466`).

The minimal capture seam is a synchronous, nonisolated offer after each ordered, successful `RecordingPCMBuffer.append`, still inside the existing conversion-order turn:

```swift
struct CommittedPCMFrame: Sendable {
    let session: DictationSessionID
    let ingressSequence: UInt64
    let startSample: UInt64
    let samples: [Float]       // already-created immutable CoW value
}

enum PCMOfferResult: Sendable {
    case accepted
    case invalidated(Reason)   // overflow/stale/closed; never a silent drop
}

protocol LosslessPCMFrameSink: Sendable {
    nonisolated func offer(_ frame: CommittedPCMFrame) -> PCMOfferResult
    func seal(session: DictationSessionID) async -> SealedPCMStream
    nonisolated func abort(session: DictationSessionID)
}
```

Requirements:

- `offer` takes one short lock, retains the existing array, and returns immediately; it performs no actor hop, Task creation, pipe write, hashing loop, or model work on the capture callback.
- Queue capacity is by samples/bytes, not variable frame count. The prototype cap is 81,920 samples (5.12 seconds, 327,680 payload bytes).
- One serial background drain canonicalizes arbitrary committed tap arrays into 1,280-sample frames, writes them to the supervisor, and waits for worker ownership ACKs.
- The sink maintains exact `sequence`, `startSample`, total count, and SHA-256. Any discontinuity or overflow invalidates only the speculative candidate. The authoritative `RecordingPCMBuffer` continues unchanged.
- At Stop, capture first closes admission and waits for already-entered conversions exactly as today. Only then does the controller seal the speculative sink. Streaming drain/finalization gets its own recognition budget; it must not be folded into the existing 500 ms capture-freeze budget.
- `SealedPCMStream` count/hash must match the newly frozen authoritative PCM before the candidate can be used.

There is no implementation that simultaneously guarantees bounded memory, never blocks the real-time callback, never drops, and survives an arbitrarily stalled consumer. The correct fourth leg is fail-closed invalidation plus offline fallback from the independent lossless PCM.

`FrameSink.swift:17-92` already demonstrates the useful shape: a bounded `.bufferingOldest` queue, one ordered drain, nonblocking submit, and explicit overflow. It needs sample/session/hash fencing and invalidation semantics for ASR; its current drop callback is suitable for disk failure reporting, not silent continuation.

## Worker protocol proposal

Current wire protocol v1 supports whole-sample/file requests only (`ASRWorkerProtocol.swift:8-30`). The supervisor allows one pending request, serializes operations, writes on a dedicated queue, and kills the exact process generation on cancellation/timeout (`ASRWorkerSupervisor.swift:624-704`). Preserve those strengths.

Minimum v2 additions:

- `streamOpen` / `streamOpened`
- `streamFrame` / `streamFrameAck`
- `streamFinish` / normal detailed `result`
- `streamAbort` / `streamAborted`

Do not add unsolicited partial events in the first gate. Serial one-frame-at-a-time requests reuse the existing one-pending-request invariant and ensure that at most one unacknowledged wire frame exists. Preview UI can remain disabled during this correctness/speed experiment.

Every stream message carries:

- supervisor worker generation;
- dictation session identity;
- random stream UUID/nonce;
- exact main model tree/config hash;
- language hint;
- vocabulary revision/config hash;
- frame sequence and absolute start sample;
- frame sample count and payload;
- cumulative owned count in each ACK.

`streamFinish` declares final sequence, total sample count, and SHA-256 over canonical Float32 little-endian bytes. The worker rejects gaps, overlaps, duplicates, stale fences, hash/count mismatch, an extra finish, and frames after terminal state. ACK means the worker owns an immutable copy in a bounded queue; it does not mean inference completed.

The worker creates one `SlidingWindowAsrManager` per stream while sharing immutable `AsrModels` references. `AsrManager.makeWorkerClone()` already reuses one `AsrModels` object (`AsrManager.swift:96-99`), so a session need not duplicate the 483 MB logical model. Decoder state, buffers, and final accumulators remain per-session. Only one active stream lease is allowed.

`WorkerRuntime.handle` must keep frame handling short and run recognition in a separately owned task. On finish it joins that task and returns one detailed result. On abort it cancels and joins. If join misses the bounded deadline, the supervisor uses its existing exact-generation kill/reap mechanism before starting authoritative offline fallback.

The current worker reader also creates a default-unbounded `AsyncStream` (`OpenRambleASRWorker.swift:14-31`). One-frame request/ACK flow control prevents accumulation in the proposed first protocol; a later multi-credit protocol would need a bounded reader queue and explicit credits.

## Session fencing, cancellation, and static memory

### Session state machine

```text
idle
  -> open(generation, dictationSession, streamID, configHash)
  -> accepting contiguous frames
  -> sealed(count, pcmSHA256)
  -> finishing model + exact product vocabulary
  -> result (terminal)

any mismatch/overflow/error
  -> invalid (sticky)
  -> abort + joined task, or exact-generation kill/reap
  -> unchanged offline full-PCM fallback
```

Late ACK/result frames are discarded unless all three fences match. Starting session N+1 never clears or reuses N's state. A manager is not reset/reused after its input stream is finished.

### Memory accounting

Known payload/state bounds, excluding already-loaded model weights and Core ML's measured runtime allocations:

- Authoritative capture PCM: at most 4,800,000 floats = 19,200,000 bytes for five minutes; already shipping.
- App speculative queue: at most 81,920 floats = 327,680 payload bytes.
- One unacknowledged wire frame: at most 1,280 floats = 5,120 bytes plus framing.
- Worker/manager bounded input queue: at most 327,680 payload bytes.
- Preview-geometry sample assembly: about 28,000 floats = 112,000 bytes plus one input frame.
- One padded Swift audio window: 240,000 floats = 960,000 bytes.
- One cached preprocessor audio `MLMultiArray`: about 960,000 bytes; the code returns it with `resetData:false` because it is fully overwritten.
- Two-layer TDT hidden + cell arrays: 2 x 2 x 1 x 640 Float32 = 10,240 bytes, plus predictor output and small metadata.
- Worst configured token-ID count over five minutes at one 600-token ceiling per one-second center is 180,000 IDs (~720 KB before timestamps/confidences/durations and Swift overhead). The detailed final accumulator must use an explicit maximum derived from audio duration and reject overflow.

The proposed hard gate is <=64 MiB candidate incremental peak RSS, <=16 MiB post-warm session-to-session RSS growth, zero FD growth, and no orphan worker. Actual Core ML activation/RSS cost is unmeasured in this source-only task.

## Exactness verdict by duration

### Up to 15 seconds

Shipping constructs the final frame-aligned audio, pads to 240,000 samples, and calls `executeMLInferenceWithTimings(... isLastChunk:true)` once (`AsrManager+Transcription.swift:5-38`). The encoder is an offline full-context graph. Adding final samples changes valid length/masking and can change earlier representations; no source API exposes an encoder cache that could be updated to the exact full-utterance result. Stateful decoder arrays do not solve that dependency.

Thus an exact final must still run the full final frontend after Stop. Current one-second SlidingWindow can move earlier decoder work under speech but still performs the final fixed frontend, changes context and frame navigation, and uses heuristic dedup. It is a quality candidate, not an exact cache.

### Above 15 seconds

Shipping switches to `ChunkProcessor` (`AsrManager+Transcription.swift:40-50`). With product `melChunkContext=false`, its layout is 239,360 samples (~14.96 s), 32,000-sample overlap, 207,360-sample (~12.96 s) regular stride, with silence-aligned starts searched within ±4 seconds and a .5-second valley fallback (`ChunkProcessor.swift:25-28`, `62-79`, `131-209`). It creates a fresh reset decoder state per window, can run four worker clones, then uses timestamp-aware merge and seam cleanup (`ChunkProcessor.swift:397-565`, `641-684`, `730+`).

SlidingWindow instead persists one decoder across fixed one-second centers and deduplicates token sequences. Its windows, starts, `isLastChunk`, worker concurrency, decoder state, and merge are different. No transcript/timing identity can be inferred. The exact long-form precompute seam is to compute only final-plan windows whose PCM ranges and starts are provably closed, then on Stop recompute the same full plan and reuse only exact matches; it is not to substitute stateful SlidingWindow output.

## Frozen A/B gate

The full draft is `PREREGISTRATION_DRAFT.json`. It is deliberately **not armed** because the temp streaming runner, diff, evaluator identity, and output paths do not yet exist. The previously armed 204-corpus preregistration does not authorize this different candidate.

Gate order:

1. CPU/source gate: complete. Protocol model passes happy path and sticky fail-closed sequence-gap, start-offset, stale-fence, overflow, and final-hash cases.
2. Engineering smoke only after explicit GO: four previously used real fixtures (2 EN/2 RU), current preview geometry with shipping final semantics, two symmetric warmups and three measured paired runs. Hard-stop on any protocol/model/window/determinism/quality failure or lack of Stop-latency improvement. Only then run 14.9/15.1/29.9/30.1 boundaries.
3. Only if smoke passes, arm a new one-shot preregistration and consume the untouched 204 real 1–4 second corpus once per arm. Keep its exact existing WER/token/word/timing/vocabulary gates; do not tune or retry.
4. Only if every quality gate passes, run the stratified n=20 short latency subset and the two real long fixtures (56.104 s product-names and 84.381 s whole-earth).

Primary latency is `Stop requested -> complete product result delivered`. Under-speech compute is reported separately, never subtracted. Required submarks include final capture commit, queue seal, last worker-owned ACK, every preprocessor/encoder/decoder-joint phase and call count, flush, final `candidateRegions` CTC/rescore, and result transport. Report queue high water, backlog at Stop, RSS, FDs, PID/generation, cancellation/reap, and thermal state.

The four-fixture command proposal is frozen in `PROPOSED_STAGE1_COMMAND.txt`. It intentionally refers to a not-yet-created temp binary and an armed replacement preregistration, so it cannot be mistaken for present run authority.

## CPU-only protocol prototype

Artifact: `ProtocolModel.swift`.

It models a one-session bounded worker inbox with:

- generation + dictation session + stream UUID fencing;
- contiguous sequence and absolute sample offsets;
- 1,280-sample frame maximum;
- 81,920-sample queue maximum;
- ownership ACK after immutable copy retention;
- sticky invalidation;
- final sample-count and SHA-256 binding.

Six tests passed without importing Core ML or touching model APIs:

```json
{"cpu_protocol_tests":6,"status":"pass","max_frame_samples":1280,"max_queued_samples":81920}
```

This prototype is an executable specification only. It does not modify capture, worker protocol, FluidAudio, or product code.

## Recommendation

Do not integrate the current preview as final and do not consume the 204 holdout yet. If a model slot is later granted, implement only the temp seams above and run the four-fixture engineering smoke. The structural acceptance condition should be material Stop-to-final improvement while keeping the exact product language/vocabulary configuration and passing all protocol/output gates. If that smoke fails—as the fixed-final-frontend analysis predicts for short audio—stop the stateful lane and keep shipping offline final. Pursue exact long Stop latency through byte-identical closed shipping-window precompute instead.

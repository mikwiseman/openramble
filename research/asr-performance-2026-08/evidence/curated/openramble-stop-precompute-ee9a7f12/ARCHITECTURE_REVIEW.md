# Adversarial review: exact all-provably-closed `TokenWindow` cache

Дата: 2026-08-14
Scope: только CPU/static inspection; Core ML не запускался; shared checkout не изменялся.

## Итог

Exact current transcript/token/word/vocabulary semantics для long-form TDT достижимы, если кешировать только сырые результаты независимых окон (`token id`, global timestamp, confidence, duration) и на stop возвращать их в неизменённый final planner/merge/postprocess. Это не новый streaming ASR и не кеш готового текста. Для `<= 240_000` samples и для последнего окна всегда остаётся обычный product path.

Но буквальное требование «single worker и stop никогда не ждёт speculative inference» недостижимо с текущим Core ML вызовом. Уже начатое окно не имеет безопасного preemption. На одном execution lane stop может ждать остаток одного вызова (в имеющемся evidence примерно 63–94 ms). Убийство worker отменяет и тёплую модель, а параллельный второй manager/worker не доказывает отсутствие accelerator contention и резко повышает RSS. Поэтому перед shipping нужна P0 развилка:

1. продукт принимает bounded residual одного активного окна и проверяет p99 stop-to-text; или
2. появляется отдельный реально preemptible execution mechanism / второй isolation lane с приемлемым RSS.

Без этого можно обещать, что capture/freeze не блокируются, queued speculative jobs уступают stop, а stale result не используется; нельзя обещать zero added stop wait.

## Что доказал temp-прототип — и чего не доказал

Временный prototype правильно выбрал единицу кеша и exactness condition:

- shipping layout: окно `239_360` samples (14.96 s), overlap `32_000`, nominal stride `207_360`;
- v3/no-mel start использует silence search `±4 s` с energy half-window `1_280` samples;
- окно разрешено только после полного search horizon, полного input range и хотя бы одного sample после `candidateEnd`, то есть `isLastChunk == false` доказан;
- decoder state создаётся заново/reset для каждого окна;
- на stop план пересчитывается по final audio, а reuse разрешён только при exact plan equality и bitwise input equality;
- final window исполняется заново, поскольку `isLastChunk=true` включает отдельный boundary flush в `TdtDecoderV3`;
- merge, timestamp sort, seam dedup и `processTranscriptionResult` остаются прежними.

На пяти fixtures × пяти paired repetitions prototype дал 25/25 exact transcript и full token-timing hashes. Для 300 s fixture было 24 final windows, 23 cached, stop p50 747.686 → 64.766 ms. Это сильное evidence для raw-window reuse, но не live microphone/scheduler proof: `tempPrecomputeAllProvablyClosedChunks` сначала видит complete audio, затем симулирует каждый prefix. Минимальный measured ready slack был 2.025 s на real fixture, а отдельный 15.1 s fixture оставлял только около 100 ms.

Adversarial gaps самого temp API:

- `ObjectIdentifier(manager)` не переживает `loadModels` на том же manager и не fingerprint-ит weights/config;
- cache key содержит language, но не model epoch, main model revision, decoder/chunk config, base vocabulary или custom-vocabulary revision;
- injection seam принимает словарь по `index`; production API не должен позволять вызывающему подставить произвольные token arrays;
- duplicate index сейчас молча перезапишется, а mismatch duration cardinality превращается в zeros; corrupt cache должен целиком отклоняться;
- scheduling benchmark не покрывает stop/cancel/config/restart races и не измеряет incremental RSS/thermal/energy;
- prototype держит почти 0.96 MB input на каждое cached window: 22,021,120 B при 300 s.

## Наблюдаемые ограничения текущего product path

1. Capture уже имеет правильный источник истины: immutable linked PCM chunks добавляются под lock, а freeze делает единственный full flatten после callback barrier. Но `onSamples` прямо объявлен lossy/UI-only и не имеет session identity; его использовать нельзя.
2. `DictationController.finalize` сначала freeze-ит exact recording, затем передаёт весь `[Float]` в recognizer. Это остаётся authoritative final audio.
3. Wire protocol умеет только whole-buffer/file transcription. `ASRWorkerSupervisor` допускает один pending request и FIFO operation gate.
4. Worker reader читает pipe на отдельном thread, но `for await` вызывает `runtime.handle` последовательно; `handle` ждёт весь Core ML request. Stop frame может быть уже прочитан, но не принят scheduler-ом.
5. Cancellation текущего foreground request синхронно убивает exact worker generation. Этот механизм правильный для user deadline, но непригоден для disposable speculative job.
6. `candidateRegions` CTC начинается только после final TDT text/timings. Поэтому TDT cache может сохранить outcome exact, но не может заранее знать, какие CTC windows product выберет.

## Минимальный end-to-end дизайн

### 1. Capture: coalescible notification поверх lossless storage

Нельзя слать каждый `onSamples`. Нужен отдельный session-scoped commit seam, где notification можно coalesce, потому что сами samples уже losslessly лежат в `RecordingPCMBuffer`.

```swift
public struct ImmutablePCMPrefix: @unchecked Sendable {
    public let session: DictationSessionID
    public let storageEpoch: UInt64
    public let sampleCount: Int

    // Вызывается только off-RT. Возвращает exact Float32 bit patterns.
    public func copyBytes(in range: Range<Int>) throws -> Data
}

public protocol CommittedPCMPrefixSink: Sendable {
    // O(1), nonawaiting; sink хранит только newest watermark/snapshot.
    nonisolated func publish(_ prefix: ImmutablePCMPrefix)
    nonisolated func invalidate(session: DictationSessionID)
}
```

Практическая реализация:

- каждому `RecordingPCMChunk` при append присвоить immutable logical range (`startSample`, `endSample`);
- под существующим PCM lock взять только strong `head` + committed count + storage epoch; historical samples не копировать;
- `copyBytes` обходит retained immutable nodes и копирует только requested delta на utility actor/queue;
- observer использует `bufferingNewest(1)`/atomic latest watermark: потеря notification допустима, потеря PCM — нет;
- callback не входит в actor, не пишет pipe, не хеширует и не flatten-ит history;
- hard-cap prefix тоже публикует точный shortened commit;
- stop сначала делает нынешние `closeAdmission` + callback barrier. Final flattened `[Float]` остаётся единственным authority.

Чтобы final flatten и range copy были bit-identical, logical ordering должен повторять существующий rule: ingress order, а sample-time order только когда все timestamps валидны и monotonic. Поскольку conversion sequencer уже commit-ит ingress последовательно, range offsets можно назначать в commit order; regression test обязан покрыть invalid/reset/equal sampleTime.

### 2. App-side pump: watermark, не очередь PCM copies

```swift
actor ASRPrefixPump {
    func begin(session: DictationSessionID, initialRequestedKey: RequestedASRKey)
    nonisolated func offer(_ newestPrefix: ImmutablePCMPrefix)
    func seal(session: DictationSessionID)       // stop: больше append не создаём
    func cancel(session: DictationSessionID)
}
```

Pump хранит только `sentThrough` и newest snapshot. Он делает максимум один off-RT copy/write за раз (например, <= 16_000 samples / 64 KiB). После write берёт свежий watermark и продолжает. Поэтому pipe/backpressure не создаёт unbounded `[Data]` queue и не касается capture/stop. На stop future deltas не нужны: authoritative final payload уже содержит весь tail. Если worker cold/not-ready, pressure high или backlog cap превышен, pump отключает speculation для этого session; final идёт обычным путём.

### 3. Protocol: worker-internal cache, no token windows over IPC

Добавить protocol v2 kinds:

```swift
case beginPrefixSession       // one-way control
case appendPrefixSamples     // one-way, exact contiguous offset + Float payload
case cancelPrefixSession      // one-way control
case transcribeSessionSamples // foreground request/result; whole frozen PCM
```

```swift
struct ASRRequestedSessionKey: Codable, Equatable {
    let sessionID: UUID
    let captureStorageEpoch: UInt64
    let languageHint: String?
    let vocabularyRevision: UInt64?
    let clientConfigurationEpoch: UInt64
}

struct ASRWorkerAppendPrefix: Codable {
    let key: ASRRequestedSessionKey
    let offsetSamples: Int
    let sampleCount: Int
}

struct ASRWorkerTranscribeSessionSamples: Codable {
    let key: ASRRequestedSessionKey
    let finalSampleCount: Int
}
```

Worker derives and adds an internal execution fingerprint; client may not assert it:

```swift
struct ASRExecutionFingerprint: Hashable {
    let workerGeneration: UInt64
    let managerEpoch: UInt64           // bump on load/cleanup/reset
    let mainModelRevision: String
    let fluidAudioRevision: String
    let modelVersion: AsrModelVersion
    let languageHint: String?
    let baseVocabularyRevision: String
    let customVocabularyRevision: UInt64?
    let vocabularyModelRevision: String?
    let config: ExactASRConfigSnapshot  // every decoder/chunk/placement flag
}
```

`ExactASRConfigSnapshot` должен включать как минимум sample rate, encoder variant/compute placement, `melChunkContext`, `dualDecodeArbitration`, max tokens, every `TdtConfig` field, parallel-concurrency setting, vocabulary scheduling и explicit algorithm revision. Сейчас cache включается только для shipping `v3 + mel=false + dual=false`; любой другой fingerprint означает normal fallback.

Begin/append/cancel не должны занимать существующий foreground `operationHeld` и не должны использовать `request` cancellation handler. Они generation-bound, FIFO записываются через отдельный bounded pump. Foreground final по-прежнему имеет request ID, watchdog и current kill-on-cancel semantics.

### 4. Worker runtime: quick accept + explicit inference arbiter

Input loop должен только валидировать/enqueue и сразу возвращаться, а не await-ить inference:

```swift
for await frame in frames {
    guard await runtime.accept(frame) else { exit(0) }
}
```

`accept` никогда не вызывает Core ML. Отдельный `InferenceArbiter` имеет две очереди:

- foreground: final transcription, prepare/config, explicit warmup;
- speculative: максимум один next closed TDT window.

Правила:

- foreground всегда выбирается раньше queued speculative;
- одновременно исполняется ровно один product operation;
- stop atomically запрещает новые jobs и удаляет queued speculative;
- уже активный speculative job не cancel-ится: он заканчивает безопасно, result либо принимается по epoch/session, либо выбрасывается;
- config mutation инвалидирует все sessions до запуска mutation;
- response writes сериализованы actor-ом; one-way append не создаёт unsolicited failures, которые нынешний supervisor принял бы за stale response.

Worker хранит prefix как immutable `Data` segments с contiguous offsets, а не growing `[Float]`: это исключает O(n²) COW. На каждом append проверяются exact offset, count, payload size, session/key, 16 kHz limit и общий cap 4,800,000 samples. Gap, overlap, duplicate, stale session или non-finite planning input переводят session в `.bypassed(reason)`; user-facing final не падает.

### 5. FluidAudio seam: opaque, raw and self-validating

Не экспортировать `[Int: Window]`. Нужен opaque cache, который может создать только тот же `AsrManager` epoch:

```swift
public struct ClosedWindowPlan: Sendable, Equatable {
    let index: Int
    let chunkStart: Int
    let contextStart: Int
    let chunkEnd: Int
    let contextSamples: Int
    let chunkStartOffset: Int
    let isLastChunk: Bool              // cache требует false
    let emitTokensAfterFrame: Int?
    let initialTimeIndexOverride: Int?
    let stableThroughSampleCount: Int
    let earliestSafePrefixSampleCount: Int
}

public struct OpaqueClosedTokenWindowCache: Sendable { /* fileprivate */ }

extension AsrManager {
    func newlyProvableClosedPlans(
        in immutablePrefix: AudioSampleSource,
        afterIndex: Int,
        language: Language?
    ) throws -> [ClosedWindowPlan]

    func precomputeClosedWindow(
        _ plan: ClosedWindowPlan,
        from immutablePrefix: AudioSampleSource,
        language: Language?
    ) async throws -> OpaqueClosedTokenWindowCache

    func transcribe(
        finalSource: AudioSampleSource,
        language: Language?,
        reusing: [OpaqueClosedTokenWindowCache]
    ) async throws -> ASRResult
}
```

Cache payload — ровно raw `TokenWindow`: token ID, global timestamp frame, confidence Float bits, duration. Никакого text/word conversion, merge, seam collapse или custom-vocab result.

Precompute обязан использовать тот же loaded model epoch и fresh/reset `TdtDecoderState`, как shipping chunk path. Нельзя сохранять predictor state, encoder output, `MLMultiArray` или pooled scratch buffers. Наличие shared `MLArrayCache` означает ещё один adversarial invariant: каждый inference полностью перезаписывает reusable input/output state; cache/no-cache и cancelled-precompute sequences должны быть проверены чередованием, иначе скрытый warmed-buffer side effect может нарушить exactness даже при правильных token arrays.

Final API внутри manager обязано:

1. проверить owner/manager epoch + full execution fingerprint;
2. пересчитать полный shipping plan по final source;
3. для каждого cache exact-сравнить весь descriptor, `isLast=false`, unique index и все input Float bits (либо проверенную immutable lineage, созданную worker после full prefix memcmp);
4. требовать равную cardinality всех четырёх arrays; никакого repair/zero-fill для cache corruption;
5. принять только валидное подмножество; invalid cache не должен ломать dictation — он пропускается, а окно считается normally;
6. подставить raw windows в том же index order и выполнить неизменённые merge/sort/seam-dedup/result timing steps.

Наиболее простой exact witness в worker: до final хранить immutable prefix segments; при final сделать bitwise prefix compare с authoritative whole payload. После успеха cache ranges относятся к той же доказанной lineage. После проверки prefix storage можно освободить до final inference. Если library seam должен быть безопасным для произвольного caller, он хранит shared immutable range witnesses; cryptographic digest один без lineage — практически безопасен, но не буквально bitwise proof.

### 6. LocalTranscriber / FluidAudioAdapter snapshot point

Нужен новый вызов:

```swift
func transcribe(
    session: DictationSessionID,
    samples: [Float],
    languageHint: String?
) async throws -> ASRResult
```

Внутри одного `FluidAudioAdapter` actor turn:

1. parse language;
2. snapshot current custom vocabulary helper/revision;
3. snapshot manager/config epoch;
4. detach только matching opaque cache;
5. вызвать exact final TDT path;
6. из final TDT text/timings вычислить нынешние `candidateRegions`;
7. выполнить нынешний selected-window CTC + rescore.

Это сохраняет нынешнюю семантику «language читается на final invocation» и «vocabulary snapshot берётся один раз на dictation». Если пользователь поменял language/vocab во время речи, speculative key не совпадает и весь cache безопасно пропускается; final использует новые параметры обычным путём. Snapshot при key-down был бы новой семантикой и здесь запрещён.

## State machine и races

Worker session:

```text
absent
  -> collecting(key, contiguousPrefix, nextPlan, cached={}, queued?)
  -> stopping(finalKey, finalPCM)       [no new speculative admission]
  -> finalizing(validatedCacheSubset)
  -> finished / failed

collecting -> bypassed(reason)          [final still normal]
collecting/stopping -> cancelled        [drop buffers/cache/queue]
any state -> invalidated(model/config/worker epoch)
```

Race rules:

- Stop before 240,001 samples: no long-form cache; normal short path.
- Stop exactly at 240,000: route remains short; first window cache must not exist.
- Stop at 240,001 while first job queued: remove it and run baseline.
- Stop while job active: mark stopping, let it finish; accept only if key/epoch/final plan/input still match. This is the unavoidable bounded residual.
- Job completes simultaneously with stop: actor serialization decides once; either it is included after full validation or discarded. Never partial reuse.
- Escape/cancel during speech: drop buffers/queued jobs immediately; active completion is stale and discarded. Do not kill worker for speculative cancel.
- Foreground deadline/cancel: retain current exact-generation kill; all caches die with it.
- Worker crash/relaunch: generation mismatch means cache absent. `transcribeSessionSamples` on a fresh worker must degrade to ordinary whole-buffer transcribe, not `invalidRequest`.
- N+1 after N abort: UUID/session generation and capture storage epoch fence every append/result; late N can never mutate N+1.
- Prepare language/model/vocab/config: invalidate before mutation; active old result carries old epoch and is discarded.
- Any plan/input/cardinality mismatch: per-window miss/fallback, not recognition failure.

## CTC `candidateRegions`

Phase 1 should not precompute CTC. Exact cached TDT produces identical text and timings, therefore `vocabularyCandidateRegions`, selected CTC indices, log-prob stitching and vocabulary outcome remain identical; only selected CTC inference stays on stop path.

Почему нельзя использовать TDT windows для CTC: CTC имеет другой canonical plan — fixed 240,000-sample windows с 32,000 overlap, а selected indices зависят от final lexical candidates. Последний partial CTC chunk дополнительно требует full predecessor для frame grid. До final TDT нельзя доказать, какие acoustic windows нужны product scheduler-у.

Возможная Phase 2: кешировать evidence всех полностью закрытых fixed CTC windows, а на final брать только selected subset и заново считать trailing partial. Это может быть output-exact, но меняет accelerator work/thermal/RSS и хранит крупные log-prob matrices. Это отдельный проект с отдельной parity/energy матрицей; не надо смешивать его с минимальным TDT cache.

## Resource, pressure и cancellation gates

Hard logical caps для 5 min:

- capture authority: существующие 4,800,000 Float = 19.2 MB;
- worker speculative prefix: максимум 19.2 MB segmented bytes, освобождается сразу после final prefix validation;
- one app-side outbound segment: <= 64 KiB; не очередь full prefixes;
- TDT cache: максимум 24 windows и `24 × 600 × 16 B ≈ 225 KiB` raw scalar payload плюс bounded overhead;
- retained Core ML encoder/logit tensors: zero after each job;
- one active speculative Core ML call, zero queued copies of its 0.96 MB input beyond the call lifetime.

Runtime gates:

- warning pressure: перестать запускать новые speculative jobs и освободить prefix/cache, final remains normal;
- critical pressure/unload: invalidate session/generation; никогда не держать engine «idle» только потому, что speculative lane обошёл foreground operation gate;
- thermal `.serious/.critical`: disable speculation for current session; `.fair` — только если product policy явно допускает;
- worker RSS high-water / queued-byte cap: soft-disable cache, never drop capture;
- abort/pressure clear должен освобождать segmented PCM/cache off the audio callback;
- active speculative Core ML нельзя считать отменённым до фактического return; completion обязан release all tensors even when stale.

Release gates, которые надо измерить, а не предположить:

- 300 s incremental peak RSS над warmed baseline и возврат RSS после final/cancel;
- 20 последовательных 5 min simulated sessions без monotonic growth;
- p50/p95/p99 stop-to-text с randomized stop exactly around every job start/end;
- maximum active-job residual and worst-case regression vs baseline at 15.000–15.2 s;
- memory warning/critical while queued, active and finalizing;
- continuous thermal/energy trace. Имеющийся duty 0.46–0.56% — wall-time ratio, не power evidence.

## Test matrix

### CPU/pure P0

1. Planner extension proof: для random/zero/full-scale/tied-energy inputs каждый non-final plan на `earliestSafePrefix` равен plan для всех последующих extensions до 300 s.
2. Boundary lengths: 239,359 / 239,360 / 239,999 / 240,000 / 240,001 и `candidateEnd ± 1` для каждого index.
3. Silence minima точно на обоих краях ±4 s, equal minima, no silence, rapidly alternating valleys; мутации до safe boundary могут менять plan, после safe boundary — нет.
4. Merge injection с fake chunk executor: every subset of hit/miss, empty window, max 600 tokens, out-of-order completion; final token/confidence/duration/timestamp bits identical baseline.
5. Reject duplicate index, last-window cache, wrong descriptor, wrong language/config/model/vocab epoch, one-bit PCM mutation, array cardinality mismatch.
6. Capture prefix parity: overlapped callbacks, equal/nonmonotonic/invalid sample times, hard cap, stop during snapshot copy, cancelled freeze. Каждый published prefix bitwise равен prefix final `CapturedRecording.samples`.
7. Protocol fuzz: fragmented frames, gap/overlap/duplicate offsets, stale UUID, bad counts, >5 min, generation restart, pipe backpressure. Final всегда либо exact reuse, либо ordinary fallback.
8. Deterministic scheduler: stop before queue, queued, active, completion-vs-seal race; abort→N+1; config/vocab mutation; worker crash; pressure/unload; foreground cancel.
9. Cache side effects: baseline→cached→baseline, cache cancel at every await, pressure clear and model rewarm; pooled buffers/decoder state не должны менять следующий baseline result.

### Real Core ML before enablement (not run in this review)

- existing frozen real fixtures + 15.000–15.2 s adversarial boundaries + 56/84/120/300 s;
- `nil` auto, en, ru and mixed language;
- vocabulary absent, no candidate, candidate unchanged, candidate replaced, candidate in trailing partial CTC chunk;
- final cache subsets forced 0…N and randomized stop races;
- exact text, token IDs, Float confidence bits, token durations/timestamps, word text/start/end/confidence, candidate regions, selected CTC indices and vocabulary outcome;
- latency randomized lane order; RSS/pressure/thermal gates above.

`processingDuration` закономерно изменится и не является parity field; `audioDuration` обязан остаться прежним. Phase timing telemetry должно отдельно определить, считает ли primary TDT только stop-path work или total work under speech.

## Blockers

### P0 — без решения не shipping

1. **Stop guarantee:** single non-preemptible Core ML lane не может гарантировать zero wait; нужен явный product/SLO decision либо другой execution mechanism.
2. **Lossless capture seam:** нынешний `onSamples` запрещён; нужен immutable session-scoped prefix snapshot без historical copy на RT callback.
3. **Protocol/runtime scheduler:** protocol v2, one-way bounded append pump, quick command acceptance, foreground-priority arbiter и no-kill speculative cancellation.
4. **Opaque FluidAudio API:** production planner/proof + raw cache injection с final plan/input revalidation. Temp `[Int: Window]` API недостаточен.
5. **Full invalidation:** worker/manager/model/config/language/base-vocab/custom-vocab epochs snapshot-ятся атомарно; mismatch только fallback.
6. **Live stop-race exactness:** end-to-end fake scheduler tests и затем real Core ML randomized race matrix. Frozen-audio simulation этого не заменяет.
7. **Failure containment:** speculative corruption/input fault не ломает dictation; Core ML health fault корректно инвалидирует generation; foreground timeout по-прежнему убивает exact generation.

### P1 — можно после exact TDT MVP, но до широкого rollout

1. CTC closed-window evidence cache для снижения vocabulary stop path (отдельный design/evidence).
2. Auto/Russian/mixed and non-default-config parity breadth; unsupported config пока должен fallback.
3. Incremental RSS, repeated-5-min leak, power/thermal evidence и runtime high-water thresholds.
4. Symmetric/randomized latency benchmark и telemetry: hit/miss reason, ready slack, active residual, cache bytes, fallback reason — без audio/text/token contents.
5. Оптимизация shared immutable segment lineage, чтобы не хранить по 0.96 MB duplicate input на окно.

## Source anchors

- Temp planner/proof: `FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/ChunkProcessor.swift:121`, `TempFirstClosedChunkCache.swift:230`.
- Temp final validation/injection: `TempFirstClosedChunkCache.swift:330`, `ChunkProcessor.swift:472`.
- Distinct final-chunk flush: `TdtDecoderV3.swift:469`.
- Capture immutable chunks/final flatten: `Packages/DictationCore/Sources/DictationAudio/MicrophoneCapture.swift:37`, `:641`, `:3110`.
- Explicit lossy observer warning: same file `:2460`.
- Final whole-buffer product call: `Packages/DictationCore/Sources/DictationCore/DictationController.swift:837`, `:937`.
- Current whole-request wire: `Packages/ASRWorkerProtocol/Sources/ASRWorkerProtocol/ASRWorkerProtocol.swift:18`.
- Sequential worker handling: `apps/macos/OpenRambleASRWorker/OpenRambleASRWorker.swift:30`, `WorkerRuntime.swift:15`.
- Single pending + kill-on-cancel: `apps/macos/OpenRamble/System/ASRWorkerSupervisor.swift:637`, `:664`, `:986`.
- Final TDT→candidateRegions→selected CTC: `Packages/LocalASR/Sources/LocalASR/FluidAudioAdapter.swift:748`, `:846`, `:868`, `:1069`.

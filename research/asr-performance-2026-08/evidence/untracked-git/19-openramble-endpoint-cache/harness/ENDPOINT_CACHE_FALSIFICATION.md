# Endpoint-cached shipping ASR: falsification report

## Решение

Не интегрировать endpoint cache в текущую shipping semantics.

Без изменения входного PCM единственная строгая гарантия — повторно использовать
результат только при полном совпадении raw Float32 PCM и всех параметров. Во время
работающего микрофона такой snapshot почти сразу устаревает. Канонизация trailing
silence делает cache practically useful, но вводит новую acoustic semantics. На
маленькой, намеренно жёсткой матрице она уже не сохраняет raw token/word timings ни
в одном endpoint-eligible случае и меняет raw transcript в трёх случаях.

## Что есть в production сейчас

- `MicrophoneCapture.onSamples` — coalescing/lossy UI-metering seam без session ID.
  Комментарий прямо запрещает использовать его для ASR/VAD/content consumers.
- Lossless PCM становится recognizer-ready только после stop barrier и
  `RecordingPCMBuffer.freeze()`; затем `DictationController` запускает worker.
- Worker protocol принимает только целый `transcribeSamples`/`transcribeFile`.
  Streaming/snapshot/finalize-cache сообщений нет.
- `ASRWorkerSupervisor` single-flights requests. Отмена активного request убивает
  exact worker PID и сбрасывает loaded/Ready generation.
- Для short TDT нули pad-ятся до 15 s, но `audio_length` сначала округляется по
  1,280 samples (80 ms). Поэтому добавленный нулевой suffix меняет valid length.
- CTC также обрезает 188 output frames по исходному sample count. Его effective
  length bucket тоже примерно 1,277 samples (около 80 ms).

Следовательно, «нули всё равно являются padding» не является доказательством
эквивалентности: и TDT, и CTC получают length-dependent semantics.

## Temp-only harness

Shared repository не изменён. Harness находится только в
`$TMP/openramble-endpoint-cache/harness`.

Матрица:

- 5 frozen fixtures: LibriSpeech, VOiCES room, два FLEURS RU, developer terms RU;
- PCM после `afconvert` побитно совпал с ранее frozen canonical hashes всех пяти
  fixtures;
- для каждого fixture: raw append exact-zero `0/0.1/0.25/0.5/1.0 s` и raw trim
  `0.1/0.25/0.5/1.0 s`;
- deterministic canonicalizer: 10 ms RMS frames, threshold `0.002`, fixed 250 ms
  postroll, endpoint settled after 500 ms trailing silence;
- exact SHA-256 cache key over canonical Float32 bytes plus sorted parameters;
- parameters include language, model/FluidAudio revisions, all decoder settings,
  vocabulary model/revision/term digest/similarity/bias/scheduling;
- product path: shipping 15 s model, palettized6bit/automatic, concurrency 4,
  vocabulary `on`, 28 developer terms, candidateRegions;
- 49 unique PCM buffers, 2 warm runs each, one persistent process;
- persisted results contain hashes/counts/timings only, not dictated text or
  individual token strings.

## Результаты

### Determinism и key invalidation

- 98/98 product runs stable across repeats.
- 14/14 endpoint-eligible snapshot/final canonical digests matched.
- 5/5 resumed-speech adversaries invalidated the snapshot digest.
- 20/20 single-parameter mutations invalidated the digest.

Это доказывает correctness самого cache key для **новой canonical semantics**, но
не эквивалентность этой semantics текущему raw product path.

### Current raw semantics против canonical endpoint

Среди 14 endpoint-eligible append-zero случаев:

| Проверка | Parity |
|---|---:|
| raw transcript | 11/14 |
| normalized transcript | 13/14 |
| raw token timings | 0/14 |
| product word timings | 0/14 |
| vocabulary outcome | 14/14 |
| полный acoustic result без `audioDuration` | 0/14 |

Developer-terms fixture оставался `rescored_modified`, но canonicalization меняла
и transcript, и token/word timings при +0.5 s; при +1.0 s transcript совпал, а
timings нет.

Даже более узкая идея «trim только exact zeros, не применять RMS» не спасает
current semantics. Среди 20 positive exact-zero raw suffixes, сравнённых с тем же
fixture без suffix:

- raw transcript parity: 14/20;
- normalized transcript parity: 16/20;
- token timing parity: 0/20;
- word timing parity: 0/20.

Raw trims также небезопасны: transcript parity только 10/20, normalized parity
14/20, token/word timing parity 0/20.

### Latency arithmetic

- warm product inference median/max: `49.63/95.19 ms`;
- developer-terms runs: примерно `81.6–91.5 ms`;
- 11/14 eligible speculative results были бы готовы к stop в искусственной
  матрице, потому что в fixtures уже была тишина или был добавлен длинный suffix;
- при ровно +0.5 s после речи snapshot только запускается у stop: English waits
  `41–50 ms`; developer terms имел 27.8 ms head-start и всё ещё waits `55.8 ms`;
- при +1.0 s все пять были бы ready before stop;
- mismatch на serial worker должен сначала дождаться speculative request, затем
  запустить normal fallback. Худший measured arithmetic: `139.09 ms` вместо
  обычных `83.29 ms` (лишние `55.80 ms`). Для Libri +0.5 s: `100.59 ms` вместо
  `50.44 ms`.

Итого: механизм помогает прежде всего человеку, который держит hotkey ещё
примерно 0.55–0.60 s после окончания речи. При быстром key-up overlap отсутствует.

### RSS

- corrected warm vocabulary process peak: `184.4 MiB`;
- предшествующий cold TDT-only process зафиксировал transient peak `2.15 GiB`;
  это cold Core ML specialization, а не steady-state стоимость cache.

Speculation допустима только после существующего Ready/prewarm proof. Второй
worker/model ради отмены или параллельного fallback запрещён без отдельного RSS
budget: он дублирует сотни мегабайт weights и cold specialization risk.

## Как выглядел бы безопасный **new-semantics** прототип

1. Добавить в `RecordingPCMBuffer` O(1) immutable prefix snapshot: под lock
   удержать текущий chunk head, committed sample count и ingress sequence;
   flatten/hash делать off real-time thread. Никогда не читать `onSamples`.
2. Coalescing notification может только сообщать session/sequence «есть новый
   committed prefix»; потеря notification допустима, потеря PCM — нет.
3. Endpoint canonicalizer должен иметь versioned deterministic spec. Snapshot и
   stop применяют один и тот же код к lossless PCM.
4. Cache key обязан включать session ID, exact canonical PCM digest, sample rate,
   canonicalizer version, app/model/FluidAudio revisions, language,
   configuration epoch, encoder/decoder settings и полный vocabulary snapshot.
5. Держать максимум один in-flight speculation и один result, только для
   `<=15 s`; при resumed speech result становится stale, но active worker request
   **не отменяется**.
6. На stop reuse разрешён только при exact key match и successful result. Любая
   ошибка/mismatch/config change идёт в normal raw fallback.

## Обязательные failure/cancellation/RSS gates

- Никогда не cancel active speculative supervisor request: текущий cancellation
  handler убивает worker generation.
- Escape/session supersession лишь orphan/discard result; request доходит до
  bounded completion. Новый session не должен бесконечно ждать старую speculation.
- Если speculation ещё выполняется при mismatch, budget должен включать остаток
  speculation + normal fallback. Иначе feature выключается до старта, а не после
  того, как заняла worker.
- Speculative timeout/inference failure не может быть user result. Он инвалидирует
  cache; recording сохраняется по обычной recovery policy. Текущая supervisor
  recovery означает, что same-stop warm fallback может быть невозможен.
- Feature включается только после Ready + inference prewarm; запрещена во время
  model/vocabulary preparation, unload/recovery или memory pressure.
- `<=1` snapshot task, `<=1` cached result, session-scoped TTL, release on
  stop/abort/supersession.
- Acceptance soak: 1,000 cycles, parent/worker FD growth `<=2`, steady worker RSS
  growth `<=4 MiB`, no orphan task/result growth, no second worker PID.
- Quality gate before any new semantics: substantially larger multilingual/noisy
  corpus, exact transcript + token/word timing + vocabulary outcome matrix, with
  zero regressions if product still promises current semantics.

## Final verdict

- **Exact current semantics:** технически возможна только с exact raw PCM/params
  match (или полностью доказанным model-input equivalence key). Hit window во
  время продолжающейся записи слишком короткое, чтобы перекрыть 40–95 ms inference,
  особенно с vocabulary.
- **Useful endpoint precompute:** возможно только после принятия новой canonical
  trailing-silence semantics. Текущая матрица уже нашла transcript/timing drift,
  поэтому такой migration сейчас не проходит quality gate.
- **Shipping action:** не интегрировать. Сохранить harness как research evidence;
  продолжать искать exact work reuse внутри shipping model/chunk pipeline либо
  отдельную genuinely streaming model с собственной quality qualification.

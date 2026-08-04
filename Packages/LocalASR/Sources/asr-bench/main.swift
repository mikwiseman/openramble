import DictationCore
import Foundation
import LocalASR

// Инструмент фазы P0: установить модель, проверить её и замерить распознавание.
//
// Существует ради гейта «движок выбран на живой речи, а не на синтезе»: пока
// приложения нет, это единственный способ прогнать реальные записи и получить
// цифры скорости и памяти.

func usage() -> Never {
    print("""
    asr-bench — проверка локального распознавания

    Команды:
      status                    что установлено и где
      install                   скачать и установить модель (~483 МБ)
      install-vocab             скачать акустический подсказчик терминов (~103 МБ)
      import <папка>            взять модель из готовой папки, без сети
      delete                    удалить установленную модель
      transcribe <файл>...      распознать файлы
      bench <файл>...           распознать и замерить скорость и память
      timings <файл>...         распознать и напечатать тайминги слов
      eval <манифест.json>      прогнать корпус и посчитать WER/CER

    Переменные окружения:
      WAI_MODELS_ROOT           корень установки (по умолчанию Application Support)
      WAI_VOCAB=on              включить установленный подсказчик терминов
      WAI_VOCAB_DIR             папка CTC-моделей подсказчика (для замеров)
      WAI_VOCAB_SIMILARITY      порог похожести подсказчика (по умолчанию 0.65)
      WAI_VOCAB_TERMS           оставить первые N терминов (замер цены словаря)
      WAI_EVAL_PIPELINE=on      скорер считает текст после словаря замен
      WAI_ASR_MEL_CONTEXT=on    вернуть mel-контекст FluidAudio на стыке окон
                                (только чтобы повторить замер потери речи)
      WAI_ASR_MODEL_DIR         папка бандлов движка мимо хранилища (для замеров)
      WAI_ASR_ENCODER           palettized6bit (по умолчанию) | int4
      WAI_ASR_ENCODER_PLACEMENT neuralEngine (по умолчанию) | gpu
      WAI_ASR_DUAL_DECODE=on    второй проход декодера с арбитражем
      WAI_ASR_MAX_TOKENS        потолок токенов на окно (по умолчанию 150)
      WAI_ASR_LANGUAGE          принудительный язык (ru, en, …) вместо авто
    """)
    exit(64)
}

func modelsRoot() -> URL? {
    guard let path = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"] else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
}

func makeStore() throws -> (ModelStore, ModelInstallLayout, ModelManifest) {
    let manifest = try ModelManifest.bundled()
    let layout = try ModelInstallLayout(manifest: manifest, root: modelsRoot())
    let store = ModelStore(manifest: manifest, layout: layout)
    return (store, layout, manifest)
}

/// Хранилище акустического подсказчика — тем же механизмом, что и основное:
/// зафиксированная ревизия, проверка сумм, crash-safe promotion.
func makeVocabularyStore() throws -> (ModelStore, ModelInstallLayout, ModelManifest) {
    let manifest = try ModelManifest.bundledVocabulary()
    let layout = try ModelInstallLayout(manifest: manifest, root: modelsRoot())
    let store = ModelStore(manifest: manifest, layout: layout)
    return (store, layout, manifest)
}

/// Скачивание с прогрессом — общий путь обеих моделей.
func install(store: ModelStore, layout: ModelInstallLayout, manifest: ModelManifest) async -> Never {
    print("Скачиваю \(formatBytes(manifest.totalByteCount)) — \(manifest.files.count) файл(ов)")
    print("Источник: \(manifest.repository) @ \(manifest.revision)")

    let states = await store.states()
    let monitor = Task {
        var lastShown = -1
        for await state in states {
            switch state {
            case let .downloading(received, total) where total > 0:
                let percent = Int(Double(received) / Double(total) * 100)
                if percent >= lastShown + 5 {
                    lastShown = percent
                    print("  \(percent)% — \(formatBytes(received))")
                }
            case let .verifying(checked, total):
                print("  проверка \(checked)/\(total)")
            default:
                break
            }
        }
    }

    await store.install()
    monitor.cancel()

    let finalState = await store.currentState()
    printState(finalState, layout: layout, manifest: manifest)
    exit(finalState.isReady ? 0 : 70)
}

func formatBytes(_ bytes: Int64) -> String {
    String(format: "%.1f МБ", Double(bytes) / 1_000_000)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Пиковая память процесса — для гейта «модель влезает в память».
func peakMemoryBytes() -> Int64 {
    var info = rusage()
    guard getrusage(RUSAGE_SELF, &info) == 0 else { return 0 }
    // На Apple-платформах ru_maxrss отдаётся в байтах.
    return Int64(info.ru_maxrss)
}

func printState(_ state: ModelState, layout: ModelInstallLayout, manifest: ModelManifest) {
    switch state {
    case .notInstalled:
        print("Модель не установлена.")
        print("Будет скачано: \(formatBytes(manifest.totalByteCount)) в \(layout.installedDirectory.path)")
    case let .downloading(received, total):
        print("Загрузка: \(formatBytes(received)) из \(formatBytes(total))")
    case let .verifying(checked, total):
        print("Проверка: \(checked) из \(total)")
    case let .ready(directory):
        print("Модель готова: \(directory.path)")
        print("Ревизия: \(manifest.revision)")
        print("Файлов: \(manifest.files.count), \(formatBytes(manifest.totalByteCount))")
    case let .repairRequired(detail):
        print("Модель требует восстановления: \(detail)")
    case let .failed(error):
        print("Ошибка: \(error)")
    case .deleting:
        print("Удаление…")
    }
}

func isOn(_ name: String) -> Bool {
    ProcessInfo.processInfo.environment[name]?.lowercased() == "on"
}

func prepareTranscriber() async throws -> LocalTranscriber {
    // Явная папка бандлов — единственный способ сравнить два энкодера: хранилище
    // проверяет установку по манифесту и справедливо отвергает лишний файл
    // (`EncoderInt4.mlmodelc` в манифест не входит). Тот же приём уже применён к
    // подсказчику через `WAI_VOCAB_DIR`.
    let explicitModelDirectory = ProcessInfo.processInfo.environment["WAI_ASR_MODEL_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    let engineDirectory: URL
    if let explicitModelDirectory {
        print("Папка движка задана явно: \(explicitModelDirectory.path) (замер, мимо хранилища)")
        engineDirectory = explicitModelDirectory
    } else {
        let (store, layout, _) = try makeStore()
        let state = await store.refreshState()
        guard state.isReady else {
            print("Модель не установлена. Запустите: asr-bench install")
            exit(69)
        }
        engineDirectory = layout.engineDirectory
    }

    // Переключатель существует ради повторяемости замера: именно он показал,
    // что текст на стыке окон теряет включённый mel-контекст, а не длина куска.
    let melChunkContext = isOn("WAI_ASR_MEL_CONTEXT")
    if melChunkContext { print("Mel-контекст на стыке окон включён (замер, не рабочий режим)") }

    // Ручки движка. Неизвестное значение — видимая ошибка, а не тихий откат к
    // умолчанию: иначе замер молча мерил бы не то, что написано в команде.
    let encoder: EncoderVariant
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_ENCODER"] {
        guard let parsed = EncoderVariant(rawValue: raw) else {
            print("WAI_ASR_ENCODER: неизвестный вариант «\(raw)»")
            exit(64)
        }
        encoder = parsed
        print("Энкодер: \(raw)")
    } else {
        encoder = .palettized6bit
    }

    let placement: EncoderPlacement
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_ENCODER_PLACEMENT"] {
        guard let parsed = EncoderPlacement(rawValue: raw) else {
            print("WAI_ASR_ENCODER_PLACEMENT: неизвестное значение «\(raw)»")
            exit(64)
        }
        placement = parsed
        print("Энкодер считается на: \(raw)")
    } else {
        placement = .neuralEngine
    }

    let dualDecode = isOn("WAI_ASR_DUAL_DECODE")
    if dualDecode { print("Второй проход декодера с арбитражем включён") }

    // Потолок токенов не дублируется здесь числом: умолчание живёт в адаптере,
    // и bench обязан мерить ровно то, что стоит в продукте. Переменная только
    // переопределяет его — например чтобы повторить замер на прежних 150.
    var maxTokens: Int?
    if let raw = ProcessInfo.processInfo.environment["WAI_ASR_MAX_TOKENS"] {
        guard let parsed = Int(raw), parsed > 0 else {
            print("WAI_ASR_MAX_TOKENS: нужно положительное число, получено «\(raw)»")
            exit(64)
        }
        maxTokens = parsed
        print("Потолок токенов на окно: \(parsed)")
    }

    let adapter: FluidAudioAdapter
    if let maxTokens {
        adapter = FluidAudioAdapter(
            melChunkContext: melChunkContext,
            encoder: encoder,
            encoderPlacement: placement,
            dualDecodeArbitration: dualDecode,
            maxTokensPerChunk: maxTokens
        )
    } else {
        adapter = FluidAudioAdapter(
            melChunkContext: melChunkContext,
            encoder: encoder,
            encoderPlacement: placement,
            dualDecodeArbitration: dualDecode
        )
    }
    let transcriber = LocalTranscriber(engine: adapter)
    let started = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: engineDirectory)
    print(String(format: "Модель загружена за %.2f с", seconds(started.duration(to: .now))))

    // Акустический подсказчик терминов: сравнение «с ним и без него» — ровно
    // тот замер, ради которого переключатель существует. `WAI_VOCAB=on` берёт
    // установленный подсказчик (install-vocab); `WAI_VOCAB_DIR` — явную папку.
    var vocabularyDirectory = ProcessInfo.processInfo.environment["WAI_VOCAB_DIR"]
    if vocabularyDirectory == nil, isOn("WAI_VOCAB") {
        let (vocabStore, vocabLayout, _) = try makeVocabularyStore()
        guard await vocabStore.refreshState().isReady else {
            print("Подсказчик не установлен. Запустите: asr-bench install-vocab")
            exit(69)
        }
        vocabularyDirectory = vocabLayout.engineDirectory.path
    }
    if let vocabDirectory = vocabularyDirectory {
        let similarity = ProcessInfo.processInfo.environment["WAI_VOCAB_SIMILARITY"]
            .flatMap(Float.init)
        let biasWeight = ProcessInfo.processInfo.environment["WAI_VOCAB_CBW"]
            .flatMap(Float.init)
        let defaults = VocabularyBoost.developerDefault()
        // Урезание списка существует ради одного вопроса: цена подсказчика
        // растёт от числа терминов или от длины записи? Ответ решает, есть ли
        // смысл сужать словарь ради скорости.
        var terms = defaults.terms
        if let raw = ProcessInfo.processInfo.environment["WAI_VOCAB_TERMS"] {
            guard let limit = Int(raw), limit > 0 else {
                print("WAI_VOCAB_TERMS: нужно положительное число, получено «\(raw)»")
                exit(64)
            }
            terms = Array(terms.prefix(limit))
            print("Терминов оставлено: \(terms.count)")
        }
        let boost = VocabularyBoost(
            terms: terms,
            minSimilarity: similarity ?? defaults.minSimilarity,
            biasWeight: biasWeight ?? defaults.biasWeight
        )
        if let similarity {
            print("Порог похожести подсказчика: \(similarity) (WAI_VOCAB_SIMILARITY)")
        }
        if let biasWeight {
            print("Вес акустической улики: \(biasWeight) (WAI_VOCAB_CBW)")
        }
        let vocabStarted = ContinuousClock.now
        try await transcriber.prepareVocabulary(
            modelDirectory: URL(fileURLWithPath: vocabDirectory, isDirectory: true),
            boost: boost
        )
        print(
            String(
                format: "Подсказчик загружен за %.2f с — %d терминов",
                seconds(vocabStarted.duration(to: .now)),
                boost.terms.count
            )
        )
    }
    return transcriber
}

/// Словарь замен приложения поверх сырого ответа — то, что видит человек.
///
/// Включается `WAI_EVAL_PIPELINE=on`. Позволяет сравнивать не движки, а
/// продукт: сырой ответ печатается рядом, скорер считает обработанный.
func makeEvalPipeline() -> TextPipeline? {
    let mode = ProcessInfo.processInfo.environment["WAI_EVAL_PIPELINE"]?.lowercased()
    switch mode {
    case "on":
        print("Скорер считает текст после словаря замен (WAI_EVAL_PIPELINE=on)")
        return TextPipeline(replacements: StarterDictionary.developer)
    case "exact":
        print("Словарь без фонетического добора (WAI_EVAL_PIPELINE=exact)")
        return TextPipeline(replacements: StarterDictionary.developer, phoneticMatching: false)
    default:
        return nil
    }
}

/// Принудительный язык вместо автоопределения — ровно то, что выбирает человек
/// в настройках. Существует, чтобы гипотезу «жёсткий язык помогает» можно было
/// проверить прогоном, а не обсуждением.
func languageHint() -> String? {
    guard let raw = ProcessInfo.processInfo.environment["WAI_ASR_LANGUAGE"] else { return nil }
    guard FluidAudioAdapter.supportedLanguageHints.contains(raw) else {
        print("WAI_ASR_LANGUAGE: движок не знает языка «\(raw)»")
        exit(64)
    }
    print("Принудительный язык: \(raw)")
    return raw
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let operands = Array(arguments.dropFirst())

switch command {
case "status":
    let (store, layout, manifest) = try makeStore()
    let state = await store.refreshState()
    printState(state, layout: layout, manifest: manifest)
    let (vocabStore, vocabLayout, vocabManifest) = try makeVocabularyStore()
    let vocabState = await vocabStore.refreshState()
    print("\nПодсказчик терминов:")
    printState(vocabState, layout: vocabLayout, manifest: vocabManifest)
    exit(state.isReady ? 0 : 69)

case "install":
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Модель уже установлена: \(layout.installedDirectory.path)")
        exit(0)
    }
    await install(store: store, layout: layout, manifest: manifest)

case "install-vocab":
    let (store, layout, manifest) = try makeVocabularyStore()
    if await store.refreshState().isReady {
        print("Подсказчик уже установлен: \(layout.installedDirectory.path)")
        exit(0)
    }
    await install(store: store, layout: layout, manifest: manifest)

case "import":
    guard let sourcePath = operands.first else { usage() }
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Модель уже установлена: \(layout.installedDirectory.path)")
        exit(0)
    }

    let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
    print("Беру модель из \(source.path)")
    print("Проверю все \(manifest.files.count) контрольных сумм — источник доверия не меняется")

    await store.importModel(from: source)
    let importedState = await store.currentState()
    printState(importedState, layout: layout, manifest: manifest)
    exit(importedState.isReady ? 0 : 70)

case "delete":
    let (store, layout, _) = try makeStore()
    await store.delete()
    print("Удалено: \(layout.modelDirectory.path)")
    let (vocabStore, vocabLayout, _) = try makeVocabularyStore()
    await vocabStore.delete()
    print("Удалено: \(vocabLayout.modelDirectory.path)")

case "eval":
    guard let manifestPath = operands.first else { usage() }
    let items = try Evaluation.loadManifest(at: manifestPath)
    let transcriber = try await prepareTranscriber()
    let pipeline = makeEvalPipeline()
    let language = languageHint()

    var outcomes: [EvalOutcome] = []
    for item in items {
        let started = ContinuousClock.now
        let result: ASRResult
        do {
            result = try await transcriber.transcribe(
                fileURL: URL(fileURLWithPath: item.file),
                languageHint: language
            )
        } catch {
            print("\n=== \(URL(fileURLWithPath: item.file).lastPathComponent) ===")
            print("Ошибка: \(error)")
            continue
        }
        let hypothesis = pipeline.map { $0.process(result.text).text } ?? result.text
        let outcome = EvalOutcome(
            item: item,
            report: TranscriptScorer.score(reference: item.reference, hypothesis: hypothesis),
            result: result,
            wallClock: seconds(started.duration(to: .now)),
            peakMemory: peakMemoryBytes()
        )
        outcomes.append(outcome)
        print(Evaluation.describe(outcome, showDifferences: true))
        fflush(stdout)
    }

    print(Evaluation.summary(outcomes))
    print("\nпиковая память процесса: \(formatBytes(peakMemoryBytes()))")

case "timings":
    guard !operands.isEmpty else { usage() }
    let transcriber = try await prepareTranscriber()
    for path in operands {
        let result = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: path))
        print("\n=== \(URL(fileURLWithPath: path).lastPathComponent) ===")
        print(String(format: "аудио %.2f с, слов %d", result.audioDuration, result.words.count))
        for word in result.words {
            print(String(format: "%8.2f %8.2f  %@", word.start, word.end, word.text))
        }
    }

case "transcribe", "bench":
    guard !operands.isEmpty else { usage() }
    let transcriber = try await prepareTranscriber()
    let measure = command == "bench"
    let language = languageHint()

    for path in operands {
        let url = URL(fileURLWithPath: path)
        let started = ContinuousClock.now
        do {
            let result = try await transcriber.transcribe(fileURL: url, languageHint: language)
            let wall = seconds(started.duration(to: .now))

            print("\n=== \(url.lastPathComponent) ===")
            print(result.text)

            if measure {
                let realtimeFactor = wall > 0 ? result.audioDuration / wall : 0
                print("---")
                print(String(format: "аудио:      %.2f с", result.audioDuration))
                print(String(format: "распознано: %.2f с", wall))
                print(String(format: "быстрее реального времени в %.1f раз", realtimeFactor))
                print("слов с таймингами: \(result.words.count)")
                print("пиковая память: \(formatBytes(peakMemoryBytes()))")
            }
        } catch {
            print("\n=== \(url.lastPathComponent) ===")
            print("Ошибка: \(error)")
            exit(70)
        }
    }

default:
    usage()
}

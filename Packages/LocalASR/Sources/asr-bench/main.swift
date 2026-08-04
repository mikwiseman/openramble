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
      WAI_EVAL_PIPELINE=on      скорер считает текст после словаря замен
      WAI_ASR_MEL_CONTEXT=on    вернуть mel-контекст FluidAudio на стыке окон
                                (только чтобы повторить замер потери речи)
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
    let (store, layout, _) = try makeStore()
    let state = await store.refreshState()
    guard state.isReady else {
        print("Модель не установлена. Запустите: asr-bench install")
        exit(69)
    }

    // Переключатель существует ради повторяемости замера: именно он показал,
    // что текст на стыке окон теряет включённый mel-контекст, а не длина куска.
    let melChunkContext = isOn("WAI_ASR_MEL_CONTEXT")
    if melChunkContext { print("Mel-контекст на стыке окон включён (замер, не рабочий режим)") }

    let transcriber = LocalTranscriber(engine: FluidAudioAdapter(melChunkContext: melChunkContext))
    let started = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: layout.engineDirectory)
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
        let boost = VocabularyBoost(
            terms: defaults.terms,
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
    guard isOn("WAI_EVAL_PIPELINE") else { return nil }
    print("Скорер считает текст после словаря замен (WAI_EVAL_PIPELINE=on)")
    return TextPipeline(replacements: StarterDictionary.developer)
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

    var outcomes: [EvalOutcome] = []
    for item in items {
        let started = ContinuousClock.now
        let result: ASRResult
        do {
            result = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: item.file))
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

    for path in operands {
        let url = URL(fileURLWithPath: path)
        let started = ContinuousClock.now
        do {
            let result = try await transcriber.transcribe(fileURL: url)
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

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
      delete                    удалить установленную модель
      transcribe <файл>...      распознать файлы
      bench <файл>...           распознать и замерить скорость и память

    Переменные окружения:
      WAI_MODELS_ROOT           корень установки (по умолчанию Application Support)
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
    case let .failed(error):
        print("Ошибка: \(error)")
    case .deleting:
        print("Удаление…")
    }
}

func prepareTranscriber() async throws -> LocalTranscriber {
    let (store, layout, _) = try makeStore()
    let state = await store.refreshState()
    guard state.isReady else {
        print("Модель не установлена. Запустите: asr-bench install")
        exit(69)
    }

    let transcriber = LocalTranscriber()
    let started = ContinuousClock.now
    try await transcriber.prepare(modelDirectory: layout.engineDirectory)
    print(String(format: "Модель загружена за %.2f с", seconds(started.duration(to: .now))))
    return transcriber
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let operands = Array(arguments.dropFirst())

switch command {
case "status":
    let (store, layout, manifest) = try makeStore()
    let state = await store.refreshState()
    printState(state, layout: layout, manifest: manifest)
    exit(state.isReady ? 0 : 69)

case "install":
    let (store, layout, manifest) = try makeStore()
    if await store.refreshState().isReady {
        print("Модель уже установлена: \(layout.installedDirectory.path)")
        exit(0)
    }

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

case "delete":
    let (store, layout, _) = try makeStore()
    await store.delete()
    print("Удалено: \(layout.modelDirectory.path)")

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

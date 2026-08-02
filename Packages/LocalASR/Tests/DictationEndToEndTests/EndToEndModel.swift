import DictationCore
import Foundation
import LocalASR
import XCTest

/// Модель распознавания для сквозных тестов — одна на весь процесс.
///
/// Загрузка стоит дорого: первый раз после установки модель компилируется под
/// нейромодуль (секунды), дальше — доли секунды. Держать её на каждый тест
/// значило бы мерить компилятор, а не продукт.
///
/// Отсутствие модели — не провал, а причина пропустить: в форке без
/// установленных 483 МБ сквозные тесты обязаны сказать почему, а не упасть.
actor EndToEndModel {
    static let shared = EndToEndModel()

    enum Availability: Sendable {
        case ready(LocalTranscriber)
        case unavailable(String)
    }

    private var resolved: Availability?

    func availability() async -> Availability {
        if let resolved { return resolved }
        let value = await Self.resolve()
        resolved = value
        return value
    }

    private static func resolve() async -> Availability {
        let manifest: ModelManifest
        do {
            manifest = try ModelManifest.bundled()
        } catch {
            return .unavailable("не читается вкомпилированный манифест модели: \(error)")
        }

        // Корень установки берётся так же, как его берёт asr-bench: иначе тесты
        // искали бы модель не там, где её поставили.
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let layout: ModelInstallLayout
        do {
            layout = try ModelInstallLayout(manifest: manifest, root: root)
        } catch {
            return .unavailable("не строится раскладка модели: \(error)")
        }

        let store = ModelStore(manifest: manifest, layout: layout)
        guard await store.refreshState().isReady else {
            return .unavailable(
                """
                модель Parakeet не установлена в \(layout.installedDirectory.path). \
                Поставить: swift build --package-path Packages/LocalASR -c release --product asr-bench \
                && ./Packages/LocalASR/.build/release/asr-bench install
                """
            )
        }

        let transcriber = LocalTranscriber()
        do {
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
        } catch {
            return .unavailable("модель установлена, но не загрузилась: \(error)")
        }
        return .ready(transcriber)
    }
}

/// Взять загруженную модель или внятно пропустить тест.
func requireEndToEndTranscriber() async throws -> LocalTranscriber {
    switch await EndToEndModel.shared.availability() {
    case let .ready(transcriber):
        return transcriber
    case let .unavailable(reason):
        throw XCTSkip("Сквозной тест пропущен — \(reason)")
    }
}

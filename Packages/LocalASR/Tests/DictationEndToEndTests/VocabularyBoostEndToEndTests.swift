import DictationCore
import Foundation
import LocalASR
import XCTest

/// Сквозная проверка акустического подсказчика: настоящий звук, обе модели.
///
/// Подсказчик меняет сам результат распознавания, поэтому проверять его можно
/// только на живом пути. Транскрайбер здесь свой, не общий: подсказки, один
/// раз загруженные в общий, поменяли бы результаты всех остальных сквозных
/// тестов в зависимости от порядка запуска.
final class VocabularyBoostEndToEndTests: XCTestCase {
    private static func resolveCtcDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["WAI_CTC_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // Основной путь — собственная установка приложения: тот же манифест,
        // те же суммы и раскладка, что и у пользователя.
        let manifest = try ModelManifest.bundledVocabulary()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let layout = try ModelInstallLayout(manifest: manifest, root: root)
        return layout.engineDirectory
    }

    private var transcriber: LocalTranscriber!
    private var workspace: URL!

    override func setUp() async throws {
        try await super.setUp()

        let ctcDirectory = try Self.resolveCtcDirectory()
        guard FileManager.default.fileExists(atPath: ctcDirectory.path) else {
            throw XCTSkip(
                "Подсказчик не установлен в \(ctcDirectory.path). "
                    + "Поставить: asr-bench install-vocab; либо задайте WAI_CTC_DIR"
            )
        }

        // Основная модель ищется так же, как в остальных сквозных тестах,
        // но экземпляр транскрайбера собственный — см. комментарий класса.
        guard case .ready = await EndToEndModel.shared.availability() else {
            throw XCTSkip("модель Parakeet не установлена — как и остальные сквозные тесты")
        }
        let manifest = try ModelManifest.bundled()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let layout = try ModelInstallLayout(manifest: manifest, root: root)

        transcriber = LocalTranscriber()
        try await transcriber.prepare(modelDirectory: layout.engineDirectory)
        try await transcriber.prepareVocabulary(
            modelDirectory: ctcDirectory,
            boost: .developerDefault()
        )

        workspace = FileManager.default.temporaryDirectory
            .appending(path: "vocab-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let transcriber { await transcriber.unload() }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        try await super.tearDown()
    }

    /// Обычная русская речь с ловушками не подхватывает термины.
    ///
    /// «Тёплой» звучит как deploy, «в центре» — как Sentry, «комета» — как
    /// commit. Ровно поэтому эти три термина исключены из акустического
    /// набора; тест держит блиндаж: если их вернуть, он падает первым.
    func testОбычнаяРечьСЛовушкамиОстаётсяРусской() async throws {
        let recording = try await synthesize(
            "Тёплой осенью мы обедали в центре, а комета висела над городом."
        )

        let result = try await transcriber.transcribe(fileURL: recording)

        for term in ["deploy", "sentry", "commit"] {
            XCTAssertFalse(
                result.text.lowercased().contains(term),
                "Термин «\(term)» пролез в обычную русскую фразу: \(result.text)"
            )
        }
    }

    /// Термин, который словарь замен не берёт принципиально, приходит латиницей.
    ///
    /// «Postgres» модель пишет разорванным («поуст герз», «постгриз»), и
    /// плоская замена бессильна — это задокументированная граница словаря.
    /// Акустический подсказчик ловит термин по звуку, а не по написанию.
    ///
    /// Фраза — из замеренного корпуса: на ней подсказчик срабатывает
    /// подтверждённо. Полнота по всем фразам частичная и задокументирована в
    /// docs/benchmarks.md; тест держит именно наличие способности, а не 100%.
    func testСловарноНедосягаемыйТерминПриходитЛатиницей() async throws {
        let recording = try await synthesize(
            "Данные лежат в Postgres, а горячий кэш мы держим отдельно."
        )

        let result = try await transcriber.transcribe(fileURL: recording)

        XCTAssertTrue(
            result.text.contains("Postgres"),
            "Postgres обязан прийти латиницей из подсказчика. Пришло: \(result.text)"
        )
    }

    // MARK: - Синтез

    private func synthesize(_ text: String) async throws -> URL {
        let aiff = workspace.appending(path: "\(UUID().uuidString).aiff")
        let wav = workspace.appending(path: "\(UUID().uuidString).wav")
        // Скорость совпадает с корпусом замера: написание разорванного термина
        // зависит и от темпа речи, а тест держит замеренное поведение.
        try await run("/usr/bin/say", ["-v", "Milena", "-r", "200", "-o", aiff.path, text])
        try await run(
            "/usr/bin/afconvert",
            ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]
        )
        return wav
    }

    private func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(tool) завершился с кодом \(process.terminationStatus)")
        }
    }
}

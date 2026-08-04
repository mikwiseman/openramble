import DictationCore
import FluidAudio
import XCTest
@testable import LocalASR

/// Проверки склейки токенов в слова.
///
/// Модель здесь не нужна: `words(from:)` — чистая функция, а именно она решает,
/// как выглядят пословные тайминги, на которые потом опирается вся пост-обработка.
final class FluidAudioAdapterTests: XCTestCase {
    private func timing(_ token: String, _ start: Double, _ end: Double, confidence: Float = 1) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: confidence)
    }

    func testEmptyTimingsProduceNoWords() {
        XCTAssertTrue(FluidAudioAdapter.words(from: nil).isEmpty)
        XCTAssertTrue(FluidAudioAdapter.words(from: []).isEmpty)
    }

    func testJoinsSubwordTokensIntoSingleWord() {
        // Parakeet режет слова на подслова: начало слова помечено "▁",
        // продолжение идёт без метки.
        let words = FluidAudioAdapter.words(from: [
            timing("▁при", 0.0, 0.2),
            timing("вет", 0.2, 0.4),
            timing("▁мир", 0.5, 0.7),
        ])

        XCTAssertEqual(words.map(\.text), ["привет", "мир"])
        XCTAssertEqual(words[0].start, 0.0)
        // Конец слова — конец последнего его токена, а не первого.
        XCTAssertEqual(words[0].end, 0.4)
        XCTAssertEqual(words[1].start, 0.5)
    }

    func testHandlesLeadingSpaceStyleTokens() {
        let words = FluidAudioAdapter.words(from: [
            timing(" hello", 0.0, 0.3),
            timing(" world", 0.4, 0.8),
        ])

        XCTAssertEqual(words.map(\.text), ["hello", "world"])
    }

    func testWordConfidenceTakesTheWeakestToken() {
        // Слово настолько надёжно, насколько надёжен его худший кусок —
        // иначе уверенность завышается там, где модель как раз сомневалась.
        let words = FluidAudioAdapter.words(from: [
            timing("▁дик", 0.0, 0.2, confidence: 0.95),
            timing("тов", 0.2, 0.3, confidence: 0.40),
            timing("ка", 0.3, 0.4, confidence: 0.90),
        ])

        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].text, "диктовка")
        XCTAssertEqual(try XCTUnwrap(words[0].confidence), 0.40, accuracy: 0.001)
    }

    func testSkipsEmptyTokens() {
        let words = FluidAudioAdapter.words(from: [
            timing("▁", 0.0, 0.1),
            timing("▁тест", 0.1, 0.3),
            timing("  ", 0.3, 0.4),
        ])

        XCTAssertEqual(words.map(\.text), ["тест"])
    }

    func testTimingsStayMonotonic() {
        let words = FluidAudioAdapter.words(from: [
            timing("▁раз", 0.0, 0.3),
            timing("▁два", 0.35, 0.6),
            timing("▁три", 0.7, 1.0),
        ])

        for index in 1..<words.count {
            XCTAssertLessThanOrEqual(
                words[index - 1].end,
                words[index].start,
                "Слова не должны накладываться друг на друга"
            )
        }
    }

    /// Значение флага — не мелочь настройки, а вывод замера: с включённым
    /// mel-контекстом на записях с переключением языка пропадали концы
    /// предложений, без предупреждения и без ошибки. Тест держит выбор на месте,
    /// потому что вернуть значение по умолчанию библиотеки — одна строка, а
    /// заметить потерю можно только по пропавшему тексту.
    func testMelChunkContextIsOffByDefault() async {
        let adapter = FluidAudioAdapter()

        let enabled = await adapter.usesMelChunkContext

        XCTAssertFalse(enabled, "Включённый mel-контекст молча съедает текст на стыке окон")
    }

    /// Потолок токенов на окно — тоже вывод замера, а не настройка вкуса.
    /// Библиотечные 150 на плотной речи молча обрывают разбор окна: у фразы
    /// пропадает середина, ошибки нет. Тест сторожит выбранное значение по той
    /// же причине, что и mel-контекст: вернуть умолчание — одна строка, а
    /// заметить потерю можно только по пропавшему тексту.
    func testChunkTokenCeilingIsRaisedAboveTheLibraryDefault() async {
        let adapter = FluidAudioAdapter()

        let ceiling = await adapter.chunkTokenCeiling

        XCTAssertGreaterThan(
            ceiling,
            150,
            "Потолок 150 молча съедает речь на плотной диктовке"
        )
        // Выше теоретического максимума окна защита от зацикливания перестаёт
        // существовать: 187 кадров × 10 токенов на кадр = 1870.
        XCTAssertLessThan(ceiling, 1_870, "Потолок выше максимума окна — это отсутствие защиты")
    }

    /// Папка установленного подсказчика или внятный пропуск.
    private func ctcDirectoryOrSkip() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["WAI_CTC_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let manifest = try ModelManifest.bundledVocabulary()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = try ModelInstallLayout(manifest: manifest, root: root).engineDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip(
                "Подсказчик не установлен в \(directory.path). "
                    + "Поставить: asr-bench install-vocab; либо задайте WAI_CTC_DIR"
            )
        }
        return directory
    }

    /// Правка словаря обязана доходить до акустики без перезапуска.
    ///
    /// Раньше повторная загрузка выходила на `guard spotter == nil` и молча
    /// ничего не делала: текстовые замены подхватывали новый термин сразу, а
    /// акустический набор оставался тем, каким был на старте приложения.
    /// Словарь вёл себя по-разному в двух своих половинах, и увидеть это
    /// снаружи было нельзя.
    func testСписокТерминовПересобираетсяБезПерезапуска() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()

        try await adapter.loadVocabularyModels(from: directory, boost: .developerDefault())
        let initial = await adapter.boostedTermCount
        XCTAssertGreaterThan(initial, 2, "Стартовый набор должен быть непустым")

        let narrowed = VocabularyBoost(terms: [
            .init(text: "Postgres", aliases: ["постгрес"]),
            .init(text: "Kubernetes", aliases: ["кубернетес"]),
        ])
        try await adapter.loadVocabularyModels(from: directory, boost: narrowed)

        let rebuilt = await adapter.boostedTermCount
        XCTAssertEqual(rebuilt, 2, "Новый список обязан заменить прежний, а не быть проигнорированным")

        await adapter.unload()
    }

    /// Стёртый словарь — тоже правка: подсказчик снимается, а не остаётся
    /// висеть с прежними терминами до перезапуска.
    func testПустойСписокВыключаетПодсказчик() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()

        try await adapter.loadVocabularyModels(from: directory, boost: .developerDefault())
        let loaded = await adapter.boostedTermCount
        XCTAssertGreaterThan(loaded, 0)

        try await adapter.loadVocabularyModels(from: directory, boost: VocabularyBoost(terms: []))

        let afterClearing = await adapter.boostedTermCount
        XCTAssertEqual(afterClearing, 0, "Пустой словарь обязан выключить акустические подсказки")

        await adapter.unload()
    }

    /// Беда со словарём не имеет права выглядеть как повреждение модели.
    ///
    /// Разница видна пользователю глазами: `modelsUnavailable` означает
    /// «перекачайте 483 МБ», и приложение честно это предлагает. Термину такая
    /// перекачка не помогает ничем — он останется прежним. Поэтому проблемы со
    /// списком терминов ходят своим типом.
    func testПроблемаСоСпискомНеВыдаётСебяЗаПорчуМодели() async throws {
        let directory = try ctcDirectoryOrSkip()
        let adapter = FluidAudioAdapter()
        // Термины, которых нет ни в одном подсловаре: эмодзи, иероглифы,
        // клинопись. Ровно те, на которых токенизация могла бы сдаться.
        let exotic = VocabularyBoost(terms: [
            .init(text: "😀🎉"),
            .init(text: "漢字テスト"),
            .init(text: "𐎠𐎡𐎢"),
        ])

        do {
            try await adapter.loadVocabularyModels(from: directory, boost: exotic)
        } catch let error as VocabularyBoostError {
            guard case .termNotTokenizable = error else {
                return XCTFail("Неожиданная ошибка словаря: \(error)")
            }
        } catch let error as ASREngineError {
            XCTFail("Список терминов выдан за порчу модели: \(error)")
        }

        await adapter.unload()
    }

    /// Папка установленной основной модели или внятный пропуск.
    private func modelDirectoryOrSkip() throws -> URL {
        let manifest = try ModelManifest.bundled()
        let root = ProcessInfo.processInfo.environment["WAI_MODELS_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = try ModelInstallLayout(manifest: manifest, root: root).engineDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Модель не установлена в \(directory.path). Поставить: asr-bench install")
        }
        return directory
    }

    /// Остановка, попавшая внутрь запуска предпросмотра, обязана его остановить.
    ///
    /// Актор не держит очередь: пока запуск ждал загрузку весов, `stopPreview`
    /// входил внутрь, видел пустой `previewManager` и уходил ни с чем, а запуск
    /// потом доводил дело до конца. Предпросмотр оставался работать навсегда,
    /// следующая диктовка не получала его вовсе — и человек видел перед собой
    /// текст **прошлой** сессии. Короткая диктовка, где `.listening` сменяется
    /// на `.transcribing` почти сразу, попадает в этот зазор регулярно.
    func testОстановкаПосредиЗапускаПредпросмотраОстанавливает() async throws {
        let directory = try modelDirectoryOrSkip()
        let adapter = FluidAudioAdapter()
        try await adapter.loadModels(from: directory)

        // Зазор между двумя await внутри запуска — доли миллисекунды, поэтому
        // остановка подводится к нему серией микрозадержек. Инвариант проверяется
        // на каждой попытке: остановка, вернувшая управление, обязана означать,
        // что предпросмотра нет — независимо от того, куда она попала.
        for attempt in 0..<200 {
            let starting = Task { try? await adapter.startPreview { _, _ in } }
            try await Task.sleep(for: .microseconds(20 + attempt % 400))
            await adapter.stopPreview()
            _ = await starting.value

            let leftRunning = await adapter.isPreviewRunning
            XCTAssertFalse(
                leftRunning,
                "Попытка \(attempt): предпросмотр остался запущенным после остановки — "
                    + "следующая диктовка покажет текст прошлой сессии"
            )
            if leftRunning { break }
        }

        // И следующий запуск обязан состояться, а не наткнуться на призрак.
        try await adapter.startPreview { _, _ in }
        let restarted = await adapter.isPreviewRunning
        XCTAssertTrue(restarted, "После остановки предпросмотр обязан запускаться заново")

        await adapter.stopPreview()
        await adapter.unload()
    }

    func testAdapterOwnsOfflineModeBeforeLoading() {
        ModelHub.offlineMode = false

        FluidAudioAdapter.enforceOfflineMode()

        XCTAssertTrue(ModelHub.offlineMode)
    }

    /// Папка без CTC-бандлов — это ошибка загрузки, а не молчаливое «подсказки
    /// не работают». Сети здесь нет: отказ происходит на проверке файлов.
    func testНеполнаяПапкаПодсказчикаДаётВидимуюОшибку() async throws {
        let adapter = FluidAudioAdapter()
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ctc-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        do {
            try await adapter.loadVocabularyModels(
                from: empty,
                boost: VocabularyBoost(terms: [.init(text: "deploy")])
            )
            XCTFail("Пустая папка обязана дать ошибку загрузки подсказчика")
        } catch let error as ASREngineError {
            guard case .modelsUnavailable = error else {
                return XCTFail("Ожидалась modelsUnavailable, пришло: \(error)")
            }
        }
    }

    /// Пустой список терминов — это осознанное «подсказки выключены», а не
    /// повод грузить CTC-модели в память.
    func testПустойСписокТерминовНеТрогаетМодели() async throws {
        let adapter = FluidAudioAdapter()
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

        // Папки не существует, но с пустым списком терминов адаптер не должен
        // даже пытаться её читать.
        try await adapter.loadVocabularyModels(from: missing, boost: VocabularyBoost(terms: []))
    }

    /// Неизвестный код языка — ошибка вызывающего, и она видима сразу,
    /// до загрузки моделей: молча превратиться в «auto» она не имеет права.
    func testНеизвестнаяПодсказкаЯзыкаДаётВидимуюОшибку() async {
        let adapter = FluidAudioAdapter()

        do {
            _ = try await adapter.transcribe(samples: [0.1, 0.2], languageHint: "xx")
            XCTFail("Неизвестный код обязан дать ошибку")
        } catch let error as ASREngineError {
            guard case let .inferenceFailed(detail) = error else {
                return XCTFail("Ожидалась inferenceFailed, пришло: \(error)")
            }
            XCTAssertTrue(detail.contains("xx"))
        } catch {
            XCTFail("Неожиданная ошибка: \(error)")
        }
    }

    /// Список подсказок — источник для выбора языка в интерфейсе.
    func testСписокЯзыковНепустИБезДубликатов() {
        let hints = FluidAudioAdapter.supportedLanguageHints

        XCTAssertTrue(hints.contains("ru"))
        XCTAssertTrue(hints.contains("en"))
        XCTAssertEqual(hints.count, Set(hints).count, "Дубликаты сломали бы Picker")
    }

    func testMixedRussianEnglishKeepsLatinIntact() {
        // Главный сценарий продукта: английские термины внутри русской речи
        // не должны склеиваться с соседними словами.
        let words = FluidAudioAdapter.words(from: [
            timing("▁закинул", 0.0, 0.4),
            timing("▁pull", 0.5, 0.7),
            timing("▁request", 0.75, 1.1),
        ])

        XCTAssertEqual(words.map(\.text), ["закинул", "pull", "request"])
    }
}

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

import XCTest
@testable import DictationCore

/// Мок движка для тестов чистой логики.
///
/// Существование этого мока — и есть смысл протокола: ни один тест
/// DictationCore не должен тянуть FluidAudio и загружать модель.
actor MockASREngine: ASREngineAdapting {
    private(set) var loadedDirectory: URL?
    private(set) var transcribeCallCount = 0
    private(set) var isLoaded = false

    var resultToReturn: ASRResult = ASRResult(
        text: "тест",
        audioDuration: 1,
        processingDuration: 0.01
    )
    var errorToThrow: ASREngineError?

    func loadModels(from directory: URL) async throws {
        if let errorToThrow { throw errorToThrow }
        loadedDirectory = directory
        isLoaded = true
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        transcribeCallCount += 1
        if let errorToThrow { throw errorToThrow }
        guard isLoaded else { throw ASREngineError.modelsNotLoaded }
        return resultToReturn
    }

    func unload() async {
        isLoaded = false
    }

    func setError(_ error: ASREngineError?) { errorToThrow = error }
    func setResult(_ result: ASRResult) { resultToReturn = result }
}

final class ASREngineAdaptingTests: XCTestCase {
    func testTranscribeBeforeLoadingFails() async {
        let engine = MockASREngine()

        do {
            _ = try await engine.transcribe(samples: [0, 0, 0])
            XCTFail("Распознавание без загруженной модели должно падать, а не возвращать пустоту")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .modelsNotLoaded)
        } catch {
            XCTFail("Ожидалась ASREngineError, получено: \(error)")
        }
    }

    func testUnloadMakesEngineUnusableAgain() async throws {
        let engine = MockASREngine()
        let directory = URL(fileURLWithPath: "/tmp/models")

        try await engine.loadModels(from: directory)
        let result = try await engine.transcribe(samples: [0.1, 0.2])
        XCTAssertEqual(result.text, "тест")

        await engine.unload()

        do {
            _ = try await engine.transcribe(samples: [0.1])
            XCTFail("После выгрузки модели распознавание должно падать")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .modelsNotLoaded)
        }
    }

    func testResultCarriesWordTimings() {
        let result = ASRResult(
            text: "привет мир",
            words: [
                .init(text: "привет", start: 0, end: 0.4),
                .init(text: "мир", start: 0.5, end: 0.8, confidence: 0.9),
            ],
            audioDuration: 1.0,
            processingDuration: 0.05
        )

        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[1].confidence, 0.9)
        // Тайминги монотонны: конец слова не раньше его начала, слова не наезжают.
        XCTAssertLessThanOrEqual(result.words[0].end, result.words[1].start)
    }
}

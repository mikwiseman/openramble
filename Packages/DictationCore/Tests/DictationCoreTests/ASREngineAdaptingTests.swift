import XCTest
@testable import DictationCore

/// Mock the engine for pure logic tests.
///
/// The existence of this mock is the meaning of the protocol: not a single test
/// DictationCore should not pull FluidAudio and load the model.
actor MockASREngine: ASREngineAdapting {
    private(set) var loadedDirectory: URL?
    private(set) var transcribeCallCount = 0
    private(set) var isLoaded = false

    var resultToReturn: ASRResult = ASRResult(
        text: "\u{0442}\u{0435}\u{0441}\u{0442}",
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
            XCTFail("\u{0420}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435} \u{0431}\u{0435}\u{0437} \u{0437}\u{0430}\u{0433}\u{0440}\u{0443}\u{0436}\u{0435}\u{043D}\u{043D}\u{043E}\u{0439} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043F}\u{0430}\u{0434}\u{0430}\u{0442}\u{044C}, \u{0430} \u{043D}\u{0435} \u{0432}\u{043E}\u{0437}\u{0432}\u{0440}\u{0430}\u{0449}\u{0430}\u{0442}\u{044C} \u{043F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0442}\u{0443}")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .modelsNotLoaded)
        } catch {
            XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} ASREngineError, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
        }
    }

    func testUnloadMakesEngineUnusableAgain() async throws {
        let engine = MockASREngine()
        let directory = URL(fileURLWithPath: "/tmp/models")

        try await engine.loadModels(from: directory)
        let result = try await engine.transcribe(samples: [0.1, 0.2])
        XCTAssertEqual(result.text, "\u{0442}\u{0435}\u{0441}\u{0442}")

        await engine.unload()

        do {
            _ = try await engine.transcribe(samples: [0.1])
            XCTFail("\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0432}\u{044B}\u{0433}\u{0440}\u{0443}\u{0437}\u{043A}\u{0438} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043F}\u{0430}\u{0434}\u{0430}\u{0442}\u{044C}")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .modelsNotLoaded)
        }
    }

    func testResultCarriesWordTimings() {
        let result = ASRResult(
            text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
            words: [
                .init(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", start: 0, end: 0.4),
                .init(text: "\u{043C}\u{0438}\u{0440}", start: 0.5, end: 0.8, confidence: 0.9),
            ],
            audioDuration: 1.0,
            processingDuration: 0.05
        )

        XCTAssertEqual(result.words.count, 2)
        XCTAssertEqual(result.words[1].confidence, 0.9)
        // Timings are monotonous: the end of a word is not earlier than its beginning, words do not overlap.
        XCTAssertLessThanOrEqual(result.words[0].end, result.words[1].start)
    }

    func testResultCarriesOptionalPhaseTimingsWithoutChangingExistingCallers() {
        let plain = ASRResult(text: "plain", audioDuration: 1, processingDuration: 0.1)
        XCTAssertNil(plain.phaseTimings)

        let timings = ASRPhaseTimings(
            primaryTDTInferenceDecodeNanoseconds: 11,
            lexicalCandidateGateNanoseconds: 22,
            ctcModelInferenceNanoseconds: 33,
            ctcRescoringFusionNanoseconds: 44,
            ctcInferenceInvocations: 2,
            vocabularyOutcome: .rescoredModified,
            phasesMayOverlap: true
        )
        let profiled = ASRResult(
            text: "profiled",
            audioDuration: 1,
            processingDuration: 0.1,
            phaseTimings: timings
        )

        XCTAssertEqual(profiled.phaseTimings, timings)
    }
}

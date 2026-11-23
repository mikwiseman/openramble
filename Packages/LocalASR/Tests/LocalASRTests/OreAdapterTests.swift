import DictationCore
import XCTest
@testable import LocalASR

/// The recognizer Intel Macs ship with. It runs on Apple silicon too, on the
/// engine's Arm kernels, so these tests run on either Mac.
///
/// The tests that need a model are skipped without one, like the live tests
/// of the other adapter:
///
/// ```
/// OPENRAMBLE_TEST_MODEL_DIR=/path/to/revision \
/// OPENRAMBLE_TEST_AUDIO=/path/to/take.wav \
///   swift test --package-path Packages/LocalASR --filter OreAdapterTests
/// ```
final class OreAdapterTests: XCTestCase {
    func testEachMacShipsTheRecognizerThatIsFasterOnIt() {
        let engine = LocalTranscriber.shippingEngine()
        #if arch(x86_64)
        XCTAssertTrue(engine is OreAdapter)
        #else
        XCTAssertTrue(engine is TranscribeCppAdapter)
        #endif
    }

    func testRecognizingBeforeAModelIsLoadedSaysSo() async {
        let adapter = OreAdapter()
        do {
            _ = try await adapter.transcribe(samples: [Float](repeating: 0, count: 16_000))
            XCTFail("an adapter with no model recognized something")
        } catch ASREngineError.modelsNotLoaded {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAFileThatIsNotAModelFailsToLoadWithAReason() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a model".utf8).write(to: directory.appendingPathComponent("model.gguf"))

        let adapter = OreAdapter()
        do {
            try await adapter.loadModels(from: directory)
            XCTFail("a file that is not a model loaded")
        } catch let ASREngineError.modelsUnavailable(reason) {
            XCTAssertFalse(reason.isEmpty)
        }
        let loaded = await adapter.isLoaded
        XCTAssertFalse(loaded)
    }

    /// The same clip through both engines on the processor. The engine
    /// follows transcribe.cpp's arithmetic, so a clear take gives the same
    /// text; the ledger holds the comparison over 1,422 clips.
    func testItGivesTheWordsTranscribeCppGivesOnTheProcessor() async throws {
        let directory = try modelDirectory()
        let samples = Array(try audioSamples().prefix(15 * 16_000))

        let reference = TranscribeCppAdapter(backend: .cpu, threadCount: 4)
        try await reference.loadModels(from: directory)
        let expected = try await reference.transcribe(samples: samples)
        await reference.unload()

        let adapter = OreAdapter()
        try await adapter.loadModels(from: directory)
        let kernels = await adapter.kernels
        let heard = try await adapter.transcribe(samples: samples)
        print("[ore] kernels=\(kernels ?? "?") engine=\(heard.processingDuration) transcribe.cpp=\(expected.processingDuration)")
        XCTAssertFalse(heard.text.isEmpty)
        XCTAssertEqual(heard.text, expected.text)
        XCTAssertTrue(heard.words.isEmpty, "ordinary dictation must not ask for timestamps")
        XCTAssertEqual(heard.audioDuration, expected.audioDuration)
        await adapter.unload()
    }

    func testABatchKeepsItsOrderItsWordTimesAndYieldsToPriority() async throws {
        let adapter = OreAdapter()
        try await adapter.loadModels(from: try modelDirectory())
        let audio = try audioSamples()
        let clips = [Array(audio.prefix(15 * 16_000)), Array(audio.prefix(9 * 16_000))]
        var reference: [ASRResult] = []
        for clip in clips { reference.append(try await adapter.transcribe(samples: clip, timestamps: true)) }

        let batch = try await adapter.transcribe(batch: clips, timestamps: true)
        XCTAssertEqual(batch.count, clips.count)
        for index in batch.indices {
            let result = try batch[index].get()
            XCTAssertEqual(result.text, reference[index].text)
            XCTAssertFalse(result.words.isEmpty)
            XCTAssertEqual(result.words.map(\.text).joined(separator: " "), result.text)
            var previous = 0.0
            for word in result.words {
                XCTAssertGreaterThanOrEqual(word.start, previous)
                XCTAssertGreaterThanOrEqual(word.end, word.start)
                XCTAssertLessThanOrEqual(word.end, result.audioDuration)
                previous = word.start
            }
        }

        // Priority is a yield, not a poisoned model or a successful empty result.
        let yielded = try await adapter.transcribe(batch: clips, shouldYield: { true })
        for result in yielded {
            guard case .failure(.cancelled) = result else { return XCTFail("priority did not yield") }
        }
        let next = try await adapter.transcribe(samples: clips[0])
        XCTAssertEqual(next.text, reference[0].text)
        await adapter.unload()
    }

    /// A taught word that is not in the take changes nothing, and taking the
    /// words away again gives the first text back.
    func testTaughtWordsAreSetAndCleared() async throws {
        let adapter = OreAdapter()
        try await adapter.loadModels(from: try modelDirectory())
        let samples = Array(try audioSamples().prefix(9 * 16_000))
        let plain = try await adapter.transcribe(samples: samples)

        await adapter.setVocabulary(["Zyxwvut Qponml", "  "])
        let taught = try await adapter.transcribe(samples: samples)
        XCTAssertEqual(taught.text, plain.text)

        await adapter.setVocabulary([])
        let cleared = try await adapter.transcribe(samples: samples)
        XCTAssertEqual(cleared.text, plain.text)
        await adapter.unload()
    }

    func testAVeryShortTakeIsAccepted() async throws {
        let adapter = OreAdapter()
        try await adapter.loadModels(from: try modelDirectory())
        let result = try await adapter.transcribe(samples: [Float](repeating: 0, count: 200))
        XCTAssertEqual(result.audioDuration, 200.0 / 16_000, accuracy: 1e-9)
        await adapter.unload()
    }

    private func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_TEST_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("set OPENRAMBLE_TEST_MODEL_DIR to run the live engine tests")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func audioSamples() throws -> [Float] {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_TEST_AUDIO"], !path.isEmpty else {
            throw XCTSkip("set OPENRAMBLE_TEST_AUDIO to run the live engine tests")
        }
        return try AudioFileReader().samples(from: URL(fileURLWithPath: path))
    }
}

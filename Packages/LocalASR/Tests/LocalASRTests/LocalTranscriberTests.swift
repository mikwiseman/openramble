import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

/// Dummy engine: allows you to check the behavior of the transcriber,
/// without downloading the 483 MB model.
actor StubEngine: ASREngineAdapting {
    private(set) var loadCount = 0
    private(set) var transcribeCount = 0
    private(set) var lastSampleCount = 0
    /// All the buffers that the engine received - you can see from them whether the recording was cut.
    private(set) var receivedBatches: [[Float]] = []
    private var loaded = false
    private var error: ASREngineError?
    private var result = ASRResult(text: "\u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{043D}\u{043E}", audioDuration: 1, processingDuration: 0.1)

    func setError(_ error: ASREngineError?) { self.error = error }
    func setResult(_ result: ASRResult) { self.result = result }

    func loadModels(from directory: URL) async throws {
        if let error { throw error }
        loadCount += 1
        loaded = true
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        transcribeCount += 1
        lastSampleCount = samples.count
        receivedBatches.append(samples)
        if let error { throw error }
        guard loaded else { throw ASREngineError.modelsNotLoaded }
        return result
    }

    func unload() async { loaded = false }
}

/// Holds the first inference open so the test can prove a real dictation waits
/// for warm-up instead of running a second Core ML prediction concurrently.
private actor WarmupGateEngine: ASREngineAdapting {
    private(set) var callCount = 0
    private(set) var maximumConcurrency = 0
    private var active = 0
    private let gatedCalls: Set<Int>
    private var callGates: [Int: CheckedContinuation<Void, Never>] = [:]

    init(gatedCalls: Set<Int> = [1]) {
        self.gatedCalls = gatedCalls
    }

    func loadModels(from directory: URL) async throws {}

    func transcribe(samples: [Float]) async throws -> ASRResult {
        callCount += 1
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
        let call = callCount
        if gatedCalls.contains(call) {
            await withCheckedContinuation { continuation in
                callGates[call] = continuation
            }
        }
        active -= 1
        return ASRResult(text: "ok", audioDuration: 1, processingDuration: 0.1)
    }

    func openFirstCall() {
        openCall(1)
    }

    func openCall(_ call: Int) {
        callGates.removeValue(forKey: call)?.resume()
    }

    func unload() async {}
}

private actor VocabularyWarmupEngine: ASREngineAdapting, VocabularyInferenceWarmupCapable {
    private(set) var mainWarmupCount = 0
    private(set) var vocabularyWarmupCount = 0

    func loadModels(from directory: URL) async throws {}

    func transcribe(samples: [Float]) async throws -> ASRResult {
        mainWarmupCount += 1
        return ASRResult(text: "", audioDuration: 1, processingDuration: 0.01)
    }

    func warmUpVocabularyInference() async throws {
        vocabularyWarmupCount += 1
    }

    func unload() async {}
}

final class LocalTranscriberTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "transcriber-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Record a short WAV: mono, 16 kHz - exactly what the dictation writes.
    ///
    /// The record is placed in a separate block intentionally: `AVAudioFile` appends the data
    /// to disk when freed, and if the file is read while the write object is alive,
    /// it will be empty.
    private func writeWAV(seconds: Double = 0.5, sampleRate: Double = 16_000) throws -> URL {
        let url = directory.appending(path: "take-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)

        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            // Sine wave so that the file is not silent.
            for index in 0..<Int(frames) {
                buffer.floatChannelData?[0][index] = sin(Float(index) * 0.05) * 0.3
            }
            try file.write(from: buffer)
        }

        let written = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(written.length, 0, "\u{0424}\u{0438}\u{043A}\u{0441}\u{0442}\u{0443}\u{0440}\u{0430} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0439}")
        return url
    }

    func testTranscribeBeforePrepareFails() async throws {
        let transcriber = LocalTranscriber(engine: StubEngine())
        let url = try writeWAV()

        do {
            _ = try await transcriber.transcribe(fileURL: url)
            XCTFail("\u{0420}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435} \u{0431}\u{0435}\u{0437} \u{043F}\u{043E}\u{0434}\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043B}\u{0435}\u{043D}\u{043D}\u{043E}\u{0439} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043F}\u{0430}\u{0434}\u{0430}\u{0442}\u{044C}")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .modelsNotLoaded)
        }
    }

    func testPrepareIsIdempotent() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)

        try await transcriber.prepare(modelDirectory: directory)
        try await transcriber.prepare(modelDirectory: directory)

        let loads = await engine.loadCount
        XCTAssertEqual(loads, 1, "\u{041F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440}\u{043D}\u{0430}\u{044F} \u{043F}\u{043E}\u{0434}\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{0442}\u{043E}\u{0439} \u{0436}\u{0435} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0433}\u{0440}\u{0443}\u{0437}\u{0438}\u{0442}\u{044C} \u{0435}\u{0451} \u{0437}\u{0430}\u{043D}\u{043E}\u{0432}\u{043E}")
    }

    func testInferenceWarmupRunsARepresentativeOneSecondBuffer() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        try await transcriber.warmUpInference()

        let batches = await engine.receivedBatches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 16_000)
        XCTAssertTrue(batches[0].allSatisfy { $0 == 0 })
    }

    func testInferenceWarmupAlsoMaterializesOptionalVocabularyPath() async throws {
        let engine = VocabularyWarmupEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        try await transcriber.warmUpInference()

        let mainWarmups = await engine.mainWarmupCount
        let vocabularyWarmups = await engine.vocabularyWarmupCount
        XCTAssertEqual(mainWarmups, 1)
        XCTAssertEqual(vocabularyWarmups, 1)
    }

    func testRealTranscriptionWaitsForInferenceWarmup() async throws {
        let engine = WarmupGateEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        let warmup = Task { try await transcriber.warmUpInference() }
        for _ in 0..<100 where await engine.callCount == 0 {
            await Task.yield()
        }
        let recognition = Task {
            try await transcriber.transcribe(samples: [0.25, -0.25])
        }
        for _ in 0..<100 { await Task.yield() }

        let callsWhileWarming = await engine.callCount
        XCTAssertEqual(callsWhileWarming, 1, "recognition must wait behind warm-up")
        await engine.openFirstCall()
        try await warmup.value
        _ = try await recognition.value
        let finalCalls = await engine.callCount
        let maximumConcurrency = await engine.maximumConcurrency
        XCTAssertEqual(finalCalls, 2)
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testCancelledTranscriptionDoesNotRunAfterInferenceWarmup() async throws {
        let engine = WarmupGateEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        let warmup = Task { try await transcriber.warmUpInference() }
        for _ in 0..<100 where await engine.callCount == 0 {
            await Task.yield()
        }
        let recognition = Task {
            try await transcriber.transcribe(samples: [0.25, -0.25])
        }
        for _ in 0..<100 { await Task.yield() }
        recognition.cancel()
        await engine.openFirstCall()

        try await warmup.value
        do {
            _ = try await recognition.value
            XCTFail("a cancelled dictation must not begin inference after warm-up")
        } catch is CancellationError {
            // Expected.
        }
        let finalCalls = await engine.callCount
        XCTAssertEqual(finalCalls, 1, "only the shared warm-up should reach the engine")
    }

    func testLateCancelledWarmupCannotClearNewGenerationWarmup() async throws {
        let engine = WarmupGateEngine(gatedCalls: [1, 2])
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        let oldWarmup = Task { try await transcriber.warmUpInference() }
        for _ in 0..<100 where await engine.callCount < 1 { await Task.yield() }

        await transcriber.unload()
        try await transcriber.prepare(modelDirectory: directory)
        let newWarmup = Task { try await transcriber.warmUpInference() }
        for _ in 0..<100 where await engine.callCount < 2 { await Task.yield() }

        await engine.openCall(1)
        do {
            try await oldWarmup.value
            XCTFail("an inference overtaken by unload must not report success")
        } catch is CancellationError {
            // Expected even when the engine itself ignored task cancellation.
        }

        let recognition = Task {
            try await transcriber.transcribe(samples: [0.25, -0.25])
        }
        for _ in 0..<100 { await Task.yield() }
        let callsWhileNewWarmupIsBlocked = await engine.callCount
        let isBusy = await transcriber.isBusy
        XCTAssertEqual(
            callsWhileNewWarmupIsBlocked,
            2,
            "the real dictation must still wait for the new generation's warm-up"
        )
        XCTAssertTrue(isBusy)

        await engine.openCall(2)
        try await newWarmup.value
        _ = try await recognition.value
        let finalCallCount = await engine.callCount
        XCTAssertEqual(finalCallCount, 3)
    }

    func testReadsWavAndPassesSamplesToEngine() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let url = try writeWAV(seconds: 0.5)

        let result = try await transcriber.transcribe(fileURL: url)

        XCTAssertEqual(result.text, "\u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{043D}\u{043E}")
        let sampleCount = await engine.lastSampleCount
        // Half a second at 16 kHz - about 8000 samples.
        XCTAssertEqual(Double(sampleCount), 8000, accuracy: 200)
    }

    func testResamplesFileRecordedAtOtherRate() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        // An external microphone may well give 48 kHz - we bring it to 16 kHz ourselves.
        let url = try writeWAV(seconds: 1.0, sampleRate: 48_000)

        _ = try await transcriber.transcribe(fileURL: url)

        let sampleCount = await engine.lastSampleCount
        XCTAssertEqual(Double(sampleCount), 16_000, accuracy: 800)
    }

    func testEmptyFileIsRejectedWithClearError() async throws {
        let transcriber = LocalTranscriber(engine: StubEngine())
        try await transcriber.prepare(modelDirectory: directory)
        let url = directory.appending(path: "broken.wav")
        try Data("\u{043D}\u{0435} \u{0437}\u{0432}\u{0443}\u{043A}".utf8).write(to: url)

        do {
            _ = try await transcriber.transcribe(fileURL: url)
            XCTFail("\u{0411}\u{0438}\u{0442}\u{044B}\u{0439} \u{0444}\u{0430}\u{0439}\u{043B} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0434}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C} \u{044F}\u{0432}\u{043D}\u{0443}\u{044E} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0443}, \u{0430} \u{043D}\u{0435} \u{043F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0439} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}")
        } catch let error as ASREngineError {
            guard case .unsupportedAudioFormat = error else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0444}\u{043E}\u{0440}\u{043C}\u{0430}\u{0442}\u{0430}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    // MARK: - A long recording goes into the engine entirely

    /// Previously, recordings longer than twelve seconds were cut here into pauses. Rezalo
    /// in the middle of a phrase, it slowed down parsing twice and lost more in mixed speech
    /// text than the engine with its own window gluing (measurements are in docs/benchmarks.md).
    /// The test guards so that the cutting does not return unnoticed.
    func testLongRecordingGoesToEngineInOnePiece() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        // Minute: five times longer than the previous slicing threshold.
        let samples = (0..<(60 * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }

        _ = try await transcriber.transcribe(samples: samples)

        let batches = await engine.receivedBatches
        XCTAssertEqual(batches.count, 1, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0443}\u{0445}\u{043E}\u{0434}\u{0438}\u{0442}\u{044C} \u{0432} \u{0434}\u{0432}\u{0438}\u{0436}\u{043E}\u{043A} \u{043E}\u{0434}\u{043D}\u{0438}\u{043C} \u{043A}\u{0443}\u{0441}\u{043A}\u{043E}\u{043C}")
        XCTAssertEqual(batches.first?.count, samples.count, "\u{0418}\u{0437} \u{0431}\u{0443}\u{0444}\u{0435}\u{0440}\u{0430} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{0438} \u{043E}\u{0442}\u{0441}\u{0447}\u{0451}\u{0442}\u{044B}")
    }

    /// The most dangerous case of the previous cutting: short tail after the cut
    /// was rejected silently - the person said “yes”, and this “yes” disappeared.
    func testShortTailAfterCutIsNotDropped() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        // 12.0 s of speech and 0.2 s at the very end. The previous cutting cut exactly along
        // threshold of twelve seconds, and did not give the remainder shorter than 0.35 s
        // to the engine at all - “yes” at the end of the phrase disappeared without a trace.
        var samples = (0..<Int(12.0 * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }
        let tailMarker: Float = 0.42
        samples += Array(repeating: tailMarker, count: Int(0.2 * 16_000))

        _ = try await transcriber.transcribe(samples: samples)

        let batches = await engine.receivedBatches
        let delivered = batches.flatMap { $0 }
        XCTAssertEqual(delivered.count, samples.count, "\u{0427}\u{0430}\u{0441}\u{0442}\u{044C} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438} \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{043B}\u{0430} \u{0434}\u{043E} \u{0434}\u{0432}\u{0438}\u{0436}\u{043A}\u{0430}")
        XCTAssertEqual(delivered.last, tailMarker, "\u{0425}\u{0432}\u{043E}\u{0441}\u{0442} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{043D}")
    }

    /// Word timings come from the engine and should not change along the way:
    /// the previous gluing of pieces added a segment offset to them.
    func testWordTimingsArePassedThroughUnchanged() async throws {
        let engine = StubEngine()
        await engine.setResult(
            ASRResult(
                text: "\u{0440}\u{0430}\u{0437} \u{0434}\u{0432}\u{0430}",
                words: [
                    .init(text: "\u{0440}\u{0430}\u{0437}", start: 0.2, end: 0.6, confidence: 0.9),
                    .init(text: "\u{0434}\u{0432}\u{0430}", start: 40.0, end: 40.5, confidence: 0.8),
                ],
                audioDuration: 60,
                processingDuration: 0.5
            )
        )
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let samples = (0..<(60 * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }

        let result = try await transcriber.transcribe(samples: samples)

        XCTAssertEqual(result.text, "\u{0440}\u{0430}\u{0437} \u{0434}\u{0432}\u{0430}")
        XCTAssertEqual(result.words.map(\.start), [0.2, 40.0])
        XCTAssertEqual(result.words.map(\.end), [0.6, 40.5])
    }

    func testEmptyBufferIsRejected() async throws {
        let transcriber = LocalTranscriber(engine: StubEngine())
        try await transcriber.prepare(modelDirectory: directory)

        do {
            _ = try await transcriber.transcribe(samples: [])
            XCTFail("\u{041F}\u{0443}\u{0441}\u{0442}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0434}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C} \u{044F}\u{0432}\u{043D}\u{0443}\u{044E} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0443}")
        } catch let error as ASREngineError {
            guard case .unsupportedAudioFormat = error else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0444}\u{043E}\u{0440}\u{043C}\u{0430}\u{0442}\u{0430}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func testUnloadRequiresPrepareAgain() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let prepared = await transcriber.isPrepared
        XCTAssertTrue(prepared)

        await transcriber.unload()

        let stillPrepared = await transcriber.isPrepared
        XCTAssertFalse(stillPrepared)
    }
}

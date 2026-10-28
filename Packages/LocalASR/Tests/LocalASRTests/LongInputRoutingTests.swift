import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

final class LongInputRoutingTests: XCTestCase {
    func testLongMemoryAndFileInputsReachTheEngineWholeInBoundedCalls() async throws {
        for seconds in [240, 480] {
            let samples = Self.speech(seconds: seconds)
            let engine = PieceEngine()
            let transcriber = LocalTranscriber(engine: engine)
            try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
            let memory = try await transcriber.transcribe(samples: samples)
            let fromMemory = await engine.received
            let url = try recording(samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try await transcriber.transcribe(fileURL: url)
            let fromFile = await engine.received.dropFirst(fromMemory.count)
            // Speech without a pause is cut into contiguous pieces: every
            // sample once, in order, nothing shared between pieces.
            XCTAssertTrue(fromMemory.joined().elementsEqual(samples), "memory, \(seconds) s")
            XCTAssertTrue(fromFile.joined().elementsEqual(samples), "file, \(seconds) s")
            XCTAssertEqual(memory.text, file.text)
            XCTAssertEqual(memory.words.map(\.start), fromMemory.indices.map { Double(fromMemory[..<$0].map(\.count).reduce(0, +)) / 16_000 })
            XCTAssertEqual(memory.audioDuration, Double(seconds))
            XCTAssertEqual(file.audioDuration, Double(seconds))
            let sizes = await engine.sizes
            // Over 30 s Parakeet Ultra segments a run itself, and on
            // transcribe.cpp 0.4.1 that can drop speech (issue #235).
            XCTAssertLessThanOrEqual(sizes.max() ?? 0, 20 * 16_000, "pieces are at most the server's 20 s")
            XCTAssertGreaterThan(sizes.count, 2)
            XCTAssertEqual(memory.processingDuration, Double(sizes.count / 2) * 0.1, accuracy: 0.0001)
        }
    }

    func testLongPublicInputsStillAcceptBaseOnlyEnginesWithoutWordTimestamps() async throws {
        let engine = StubEngine()
        await engine.setResult(ASRResult(text: "complete recording", audioDuration: 60, processingDuration: 0.1))
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        let samples = [Float](repeating: 0.1, count: 60 * 16_000)
        let memory = try await transcriber.transcribe(samples: samples)
        let url = try recording(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try await transcriber.transcribe(fileURL: url)
        XCTAssertEqual(memory.text, "complete recording")
        XCTAssertEqual(file.text, memory.text)
        XCTAssertTrue(memory.words.isEmpty)
        let received = await engine.receivedBatches
        XCTAssertEqual(received.map(\.count), [samples.count, samples.count],
            "the optional timed-batch protocol cannot become mandatory above thirty seconds")
    }

    func testShortInputKeepsDirectEnginePath() async throws {
        let engine = PieceEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        _ = try await transcriber.transcribe(samples: [Float](repeating: 1, count: 30 * 16_000))
        let batches = await engine.batchCalls
        XCTAssertEqual(batches, 0)
    }

    func testCancellationDoesNotStartTheRestOfALongInput() async throws {
        let engine = PieceEngine(gated: true)
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        let samples = Self.speech(seconds: 90)
        let work = Task { try await transcriber.transcribe(samples: samples) }
        while await engine.sizes.isEmpty { await Task.yield() }
        let unloaded = await transcriber.unloadIfIdle()
        XCTAssertFalse(unloaded, "one residency spans the complete recording")
        work.cancel()
        await engine.open()
        do { _ = try await work.value; XCTFail("cancelled input published") } catch is CancellationError {}
        let sizes = await engine.sizes
        XCTAssertEqual(sizes.count, 1)
        XCTAssertLessThanOrEqual(sizes[0], 30 * 16_000)
    }

    func testForcedReloadCannotMixModelGenerationsWithinARecording() async throws {
        let engine = PieceEngine(gated: true)
        let transcriber = LocalTranscriber(engine: engine)
        let directory = URL(fileURLWithPath: "/unused")
        try await transcriber.prepare(modelDirectory: directory)
        let samples = Self.speech(seconds: 90)
        let work = Task { try await transcriber.transcribe(samples: samples) }
        while await engine.sizes.isEmpty { await Task.yield() }
        await transcriber.unload()
        try await transcriber.prepare(modelDirectory: directory)
        await engine.open()
        do { _ = try await work.value; XCTFail("an old take used the replacement model") }
        catch is CancellationError {}
        let sizes = await engine.sizes
        XCTAssertEqual(sizes.count, 1)
    }

    func testFailedMiddleChunkNeverReturnsAPartialSuccess() async throws {
        let engine = PieceEngine(failAt: 2)
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        do {
            _ = try await transcriber.transcribe(samples: Self.speech(seconds: 90))
            XCTFail("a missing middle must fail the whole result")
        } catch ASREngineError.inferenceFailed(_, let code) { XCTAssertEqual(code, -7) }
        let sizes = await engine.sizes
        XCTAssertEqual(sizes.count, 2)
    }

    /// Noise whose loudness changes every 20 ms, as syllables do. A constant
    /// signal is no speech to the file planner's gate.
    private static func speech(seconds: Int) -> [Float] {
        (0..<seconds * 16_000).map { index in
            var state = UInt32(truncatingIfNeeded: index / 320) &* 2_654_435_761 &+ 1
            state = state &* 1_664_525 &+ 1_013_904_223
            var noise = UInt32(truncatingIfNeeded: index) &* 747_796_405 &+ 2_891_336_453
            noise ^= noise >> 13
            noise = noise &* 1_274_126_177
            return 0.1 * (0.4 + 1.2 * Float(state >> 8) / Float(1 << 24)) * (Float(noise >> 8) / Float(1 << 23) - 1)
        }
    }

    private func recording(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "long-pieces-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private actor PieceEngine: BatchASREngineAdapting {
        var sizes: [Int] = []
        var received: [[Float]] = []
        var batchCalls = 0
        let gated: Bool
        let failAt: Int?
        var gate: CheckedContinuation<Void, Never>?
        init(gated: Bool = false, failAt: Int? = nil) { self.gated = gated; self.failAt = failAt }
        func loadModels(from directory: URL) async throws {}
        func unload() async {}
        func open() { gate?.resume(); gate = nil }
        func transcribe(samples: [Float]) async throws -> ASRResult {
            sizes.append(samples.count)
            received.append(samples)
            if sizes.count == failAt { throw ASREngineError.inferenceFailed("test failure", code: -7) }
            if gated { await withCheckedContinuation { gate = $0 } }
            // One word per piece, at its start, naming its length.
            let words = [ASRResult.Word(text: String(samples.count), start: 0, end: 0.1)]
            return ASRResult(text: words[0].text, words: words,
                             audioDuration: Double(samples.count) / 16_000, processingDuration: 0.1)
        }
        func transcribe(batch: [[Float]], timestamps: Bool,
                        shouldYield: @escaping @Sendable () -> Bool) async throws -> [Result<ASRResult, ASREngineError>] {
            batchCalls += 1
            var results: [Result<ASRResult, ASREngineError>] = []
            for samples in batch { results.append(.success(try await transcribe(samples: samples))) }
            return results
        }
    }
}

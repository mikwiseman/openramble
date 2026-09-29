import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

final class LongInputRoutingTests: XCTestCase {
    func testLongMemoryAndFileInputsKeepEveryMarkerWithBoundedEngineCalls() async throws {
        for seconds in [240, 300, 480, 900] {
            let samples = (1...seconds).flatMap { [Float](repeating: Float($0), count: 16_000) }
            let engine = MarkerEngine()
            let transcriber = LocalTranscriber(engine: engine)
            try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
            let memory = try await transcriber.transcribe(samples: samples)
            let url = try recording(samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try await transcriber.transcribe(fileURL: url)
            let expected = (1...seconds).map(String.init).joined(separator: " ")
            XCTAssertEqual(memory.text, expected, "all markers once, including forced seams and the ending")
            XCTAssertEqual(file.text, expected)
            XCTAssertEqual(memory.audioDuration, Double(seconds))
            XCTAssertEqual(file.audioDuration, Double(seconds))
            let sizes = await engine.sizes
            XCTAssertLessThanOrEqual(sizes.max() ?? 0, 36 * 16_000,
                "long inputs must never reach the native engine whole")
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
        let engine = MarkerEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        _ = try await transcriber.transcribe(samples: [Float](repeating: 1, count: 30 * 16_000))
        let batches = await engine.batchCalls
        XCTAssertEqual(batches, 0)
    }

    func testCancellationDoesNotStartTheRestOfALongInput() async throws {
        let engine = MarkerEngine(gated: true)
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        let work = Task { try await transcriber.transcribe(samples: [Float](repeating: 1, count: 90 * 16_000)) }
        while await engine.sizes.isEmpty { await Task.yield() }
        let unloaded = await transcriber.unloadIfIdle()
        XCTAssertFalse(unloaded, "one residency spans the complete recording")
        work.cancel()
        await engine.open()
        do { _ = try await work.value; XCTFail("cancelled input published") } catch is CancellationError {}
        let sizes = await engine.sizes
        XCTAssertEqual(sizes.count, 1)
        XCTAssertLessThanOrEqual(sizes[0], 36 * 16_000)
    }

    func testForcedReloadCannotMixModelGenerationsWithinARecording() async throws {
        let engine = MarkerEngine(gated: true)
        let transcriber = LocalTranscriber(engine: engine)
        let directory = URL(fileURLWithPath: "/unused")
        try await transcriber.prepare(modelDirectory: directory)
        let work = Task { try await transcriber.transcribe(samples: [Float](repeating: 1, count: 90 * 16_000)) }
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
        let engine = MarkerEngine(failAt: 2)
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: URL(fileURLWithPath: "/unused"))
        do {
            _ = try await transcriber.transcribe(samples: [Float](repeating: 1, count: 90 * 16_000))
            XCTFail("a missing middle must fail the whole result")
        } catch ASREngineError.inferenceFailed(_, let code) { XCTAssertEqual(code, -7) }
        let sizes = await engine.sizes
        XCTAssertEqual(sizes.count, 2)
    }

    private func recording(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "long-markers-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private actor MarkerEngine: BatchASREngineAdapting {
        var sizes: [Int] = []
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
            if sizes.count == failAt { throw ASREngineError.inferenceFailed("test failure", code: -7) }
            if gated { await withCheckedContinuation { gate = $0 } }
            let words = stride(from: 8_000, to: samples.count, by: 16_000).map { index in
                ASRResult.Word(text: String(Int(samples[index])), start: Double(index) / 16_000,
                               end: Double(index) / 16_000 + 0.1)
            }
            return ASRResult(text: words.map(\.text).joined(separator: " "), words: words,
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

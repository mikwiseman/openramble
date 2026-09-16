import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

final class FileTranscriberTests: XCTestCase {
    func testYieldRetainsFinishedInputsAndCorruptFileDoesNotStopOthers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try recording(at: directory.appending(path: "first.wav"), value: 0.1)
        let second = try recording(at: directory.appending(path: "second.wav"), value: 0.2)
        let broken = directory.appending(path: "broken.wav")
        try Data("not audio".utf8).write(to: broken)
        let third = try recording(at: directory.appending(path: "third.wav"), value: 0.3)
        let engine = YieldingEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let results = Results()
        try await FileTranscriber(transcriber: transcriber).transcribe(
            files: [first, second, broken, third], completed: { await results.append($0, $1) })
        let values = await results.values
        XCTAssertEqual(Set(values.map(\.0)), Set(0..<4))
        XCTAssertEqual(values.count, 4, "one outcome per file")
        let valid = try values.filter { $0.0 != 2 }.sorted { $0.0 < $1.0 }.map { try $0.1.get() }
        XCTAssertEqual(valid.map(\.text), ["1", "2", "3"])
        XCTAssertTrue(valid.allSatisfy { $0.words.count == 1 && $0.duration == 1 })
        guard case .failure = values.first(where: { $0.0 == 2 })?.1 else { return XCTFail("corrupt audio succeeded") }
        let requests = await engine.requests
        XCTAssertEqual(requests, [[1], [2], [2], [3]], "a finished fragment must never be decoded twice after yield")
    }

    func testCancellationDoesNotPublishACompletedTranscriptOrStartAnotherFragment() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cancel-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try recording(at: url, value: 0.1)
        let engine = YieldingEngine(gated: true)
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: url.deletingLastPathComponent())
        let results = Results()
        let work = Task {
            try await FileTranscriber(transcriber: transcriber).transcribe(
                files: [url, url, url], completed: { await results.append($0, $1) })
        }
        while await engine.requests.isEmpty { await Task.yield() }
        work.cancel()
        await engine.open()
        do { try await work.value; XCTFail("cancelled pipeline succeeded") }
        catch is CancellationError {}
        let values = await results.values
        let requests = await engine.requests
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(requests.count, 1)
    }

    private func recording(at url: URL, value: Float) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = value }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private actor Results {
        var values: [(Int, Result<FileTranscript, Error>)] = []
        func append(_ index: Int, _ result: Result<FileTranscript, Error>) { values.append((index, result)) }
    }

    private actor YieldingEngine: BatchASREngineAdapting {
        var requests: [[Int]] = []
        let gated: Bool
        var gate: CheckedContinuation<Void, Never>?
        init(gated: Bool = false) { self.gated = gated }
        func loadModels(from directory: URL) async throws {}
        func unload() async {}
        func open() { gate?.resume(); gate = nil }
        func transcribe(samples: [Float]) async throws -> ASRResult { result(samples) }
        func transcribe(batch: [[Float]], timestamps: Bool,
                        shouldYield: @escaping @Sendable () -> Bool) async throws -> [Result<ASRResult, ASREngineError>] {
            requests.append(batch.map { Int(($0[0] * 10).rounded()) })
            if gated { await withCheckedContinuation { gate = $0 } }
            return batch.map { samples in
                if requests.count == 2 { return .failure(.cancelled) }
                return .success(result(samples))
            }
        }
        private func result(_ samples: [Float]) -> ASRResult {
            let text = String(Int((samples[0] * 10).rounded()))
            return ASRResult(text: text, words: [.init(text: text, start: 0.1, end: 0.8)],
                audioDuration: Double(samples.count) / 16_000, processingDuration: 0.1)
        }
    }
}

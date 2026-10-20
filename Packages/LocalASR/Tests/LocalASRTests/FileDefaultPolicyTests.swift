import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

final class FileDefaultPolicyTests: XCTestCase {
    func testLongImportUsesFifteenSecondOwnershipAndKeepsTheSmallTail() async throws {
        let samples = [Float](repeating: 0.1, count: 31 * 16_000 + 2_080)
        let url = try recording(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        for fromFile in [false, true] {
            let chunks = fromFile ? try await FileAudioChunks(url: url) : FileAudioChunks(samples: samples)
            var rows: [FileAudioChunk] = []
            while let next = try await chunks.next() { rows.append(next) }
            XCTAssertEqual(rows.count, 2, "15s and the remaining 16.13s, with the tiny final tail merged")
            XCTAssertEqual(rows.first?.boundaryFrame, 0)
            XCTAssertEqual(rows.first?.endFrame, 15 * 16_000)
            XCTAssertEqual(rows.last?.boundaryFrame, 15 * 16_000)
            XCTAssertEqual(rows.last?.endFrame, samples.count)
            for row in rows {
                XCTAssertEqual(row.samples, Array(samples[row.startFrame..<min(samples.count, row.endFrame + 2 * 16_000)]))
            }
        }
    }

    func testPublicFileTranscriberUsesTheSelectedDefault() async throws {
        let samples = [Float](repeating: 0.1, count: 31 * 16_000 + 2_080)
        let url = try recording(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = SizesEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: url.deletingLastPathComponent())
        let outputs = Outputs()
        try await FileTranscriber(transcriber: transcriber).transcribe(files: [url]) { _, result in
            await outputs.append(result)
        }
        let sizes = await engine.sizes
        let results = await outputs.values
        XCTAssertEqual(sizes, [17 * 16_000, samples.count - 13 * 16_000])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results.first?.get().duration, Double(samples.count) / 16_000)
    }

    private func recording(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "default-cuts-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    private actor Outputs {
        var values: [Result<FileTranscript, Error>] = []
        func append(_ value: Result<FileTranscript, Error>) { values.append(value) }
    }

    private actor SizesEngine: BatchASREngineAdapting {
        var sizes: [Int] = []
        func loadModels(from directory: URL) async throws {}
        func unload() async {}
        func transcribe(samples: [Float]) async throws -> ASRResult { result(samples) }
        func transcribe(batch: [[Float]], timestamps: Bool,
                        shouldYield: @escaping @Sendable () -> Bool) async throws -> [Result<ASRResult, ASREngineError>] {
            sizes.append(contentsOf: batch.map(\.count))
            return batch.map { .success(result($0)) }
        }
        private func result(_ samples: [Float]) -> ASRResult {
            ASRResult(text: "word", words: [.init(text: "word", start: 1, end: 1.2)],
                      audioDuration: Double(samples.count) / 16_000, processingDuration: 0)
        }
    }
}

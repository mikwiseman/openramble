// Research probe. Copy into LocalASRTests only for an explicit local trace,
// then remove it. This is not linked into the application or a normal test run.
import CryptoKit
import DictationCore
import Foundation
import XCTest
@testable import LocalASR

@MainActor
final class TraceLongAudioTests: XCTestCase {
    func testTraceNativeChunksAndJoin() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["ASR_TRACE_INPUT"], let output = env["ASR_TRACE_OUTPUT"],
              let model = env["WAI_ASR_MODEL_DIR"] else {
            throw XCTSkip("explicit input, local output and model required")
        }
        let destination = URL(fileURLWithPath: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "preserve previous evidence")
        guard !FileManager.default.fileExists(atPath: output) else { return }
        FileManager.default.createFile(atPath: output, contents: nil)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        func write(_ row: [String: Any]) throws {
            try file.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            try file.write(contentsOf: Data([10]))
            try file.synchronize()
        }
        func words(_ values: [ASRResult.Word]) -> [[String: Any]] {
            values.map { ["text": $0.text, "start": $0.start, "end": $0.end] }
        }
        let engine = TranscribeCppAdapter()
        try await engine.loadModels(from: URL(fileURLWithPath: model))
        do {
            let source = try await FileAudioChunks(url: URL(fileURLWithPath: input))
            var joiner = TimedTranscriptJoiner()
            var index = 0
            while let chunk = try await source.next() {
                // FileTranscriber uses the native batch API with one input.
                let results = try await engine.transcribe(batch: [chunk.samples], timestamps: true)
                let result = try XCTUnwrap(results.first).get()
                let before = joiner.words
                try joiner.append(result, chunk: chunk, duration: source.duration)
                let digest = chunk.samples.withUnsafeBytes {
                    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                }
                try write(["type": "chunk", "index": index,
                    "start_frame": chunk.startFrame, "boundary_frame": chunk.boundaryFrame,
                    "end_frame": chunk.endFrame, "input_frames": chunk.samples.count,
                    "pcm_sha256": digest, "raw_text": result.text, "raw_words": words(result.words),
                    "joined_before": words(before), "joined_after": words(joiner.words)])
                index += 1
            }
            try write(["type": "complete", "runtime": TranscribeCppAdapter.runtimeVersion,
                "chunks": index, "duration": source.duration,
                "text": joiner.words.map(\.text).joined(separator: " "), "words": words(joiner.words)])
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
    }
}

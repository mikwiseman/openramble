import DictationCore
import XCTest
@testable import LocalASR

final class NativeBatchTests: XCTestCase {
    func testNativeBatchPreservesTextAndOrderedTimings() async throws {
        guard let model = ProcessInfo.processInfo.environment["OPENRAMBLE_TEST_MODEL_DIR"],
              let audio = ProcessInfo.processInfo.environment["OPENRAMBLE_TEST_AUDIO"] else {
            throw XCTSkip("set model and audio paths for the native batch gate")
        }
        let adapter = TranscribeCppAdapter()
        try await adapter.loadModels(from: URL(fileURLWithPath: model))
        let audioSamples = try AudioFileReader().samples(from: URL(fileURLWithPath: audio))
        let samples = [Array(audioSamples.prefix(15 * 16_000)), Array(audioSamples.prefix(9 * 16_000))]
        var reference: [ASRResult] = []
        for sample in samples { reference.append(try await adapter.transcribe(samples: sample, timestamps: true)) }
        let batch = try await adapter.transcribe(batch: samples, timestamps: true)
        XCTAssertEqual(batch.count, samples.count)
        for index in batch.indices {
            let result = try batch[index].get()
            XCTAssertEqual(result.text.lowercased(), reference[index].text.lowercased())
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
        let yielded = try await adapter.transcribe(batch: samples, shouldYield: { true })
        for result in yielded {
            guard case .failure(.cancelled) = result else { return XCTFail("priority did not yield") }
        }
        let next = try await adapter.transcribe(samples: samples[0])
        XCTAssertEqual(next.text, reference[0].text)
        XCTAssertTrue(next.words.isEmpty, "ordinary dictation must not ask for timestamps")
        await adapter.unload()
    }
}

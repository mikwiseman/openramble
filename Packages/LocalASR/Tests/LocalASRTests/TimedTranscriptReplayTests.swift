import Foundation
import XCTest
import DictationCore
@testable import LocalASR

/// An opt-in, model-free check against the frozen public native-word export.
final class TimedTranscriptReplayTests: XCTestCase {
    private struct Word: Decodable, Equatable {
        let text: String
        let start: Double
        let end: Double
    }
    private struct Chunk: Decodable {
        let startFrame: Int
        let boundaryFrame: Int
        let endFrame: Int
        let words: [Word]
    }
    private struct Case: Decodable {
        let id: String
        let audioSeconds: Double
        let chunks: [Chunk]
        let expectedWords: [Word]
        let expectedText: String
    }

    func testFrozenPublicNativeWordsMatchTheSelectedReplay() throws {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_GAP_REPLAY"] else {
            throw XCTSkip("explicit frozen public-fixture replay required")
        }
        let cases = try JSONDecoder().decode([Case].self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            var joiner = TimedTranscriptJoiner()
            for chunk in item.chunks {
                let result = ASRResult(text: chunk.words.map(\.text).joined(separator: " "),
                    words: chunk.words.map { .init(text: $0.text, start: $0.start, end: $0.end) },
                    audioDuration: item.audioSeconds, processingDuration: 0)
                try joiner.append(result, chunk: .init(samples: [], startFrame: chunk.startFrame,
                    boundaryFrame: chunk.boundaryFrame, endFrame: chunk.endFrame), duration: item.audioSeconds)
            }
            XCTAssertEqual(joiner.words.map { Word(text: $0.text, start: $0.start, end: $0.end) },
                           item.expectedWords, item.id)
            XCTAssertEqual(joiner.words.map(\.text).joined(separator: " "), item.expectedText, item.id)
        }
    }
}

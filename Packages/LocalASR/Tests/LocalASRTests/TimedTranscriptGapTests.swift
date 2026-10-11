import XCTest
import DictationCore
@testable import LocalASR

/// Preserve recognized context only when unmatched predictions are separated
/// in time; overlapping predictions retain the existing ownership rule.
final class TimedTranscriptGapTests: XCTestCase {
    private func result(_ words: [(String, Double, Double)]) -> ASRResult {
        ASRResult(text: words.map(\.0).joined(separator: " "),
            words: words.map { .init(text: $0.0, start: $0.1, end: $0.2) },
            audioDuration: 40, processingDuration: 0)
    }

    func testNoMatchKeepsRecognizedContextAcrossATimeGap() throws {
        var joiner = TimedTranscriptJoiner()
        try joiner.append(result([("Я", 19, 19.1), ("сказал", 19.2, 19.5), ("привет", 20.1, 20.3)]),
            chunk: .init(samples: [], startFrame: 0, boundaryFrame: 0, endFrame: 20 * 16_000), duration: 40)
        // The new chunk starts two seconds before the cut. Its first word is
        // at 21.1 s on the original timeline, with no overlapping prediction.
        try joiner.append(result([("и", 3.1, 3.2), ("ушёл", 3.3, 3.7)]),
            chunk: .init(samples: [], startFrame: 18 * 16_000,
                         boundaryFrame: 20 * 16_000, endFrame: 40 * 16_000), duration: 40)
        XCTAssertEqual(joiner.words.map(\.text), ["Я", "сказал", "привет", "и", "ушёл"])
        XCTAssertEqual(joiner.words.map(\.start), [19, 19.2, 20.1, 21.1, 21.3])
    }

    func testOverlappingNoMatchStillUsesTheCutBoundary() throws {
        var joiner = TimedTranscriptJoiner()
        try joiner.append(result([("Я", 19, 19.1), ("ошибка", 20.1, 20.3)]),
            chunk: .init(samples: [], startFrame: 0, boundaryFrame: 0, endFrame: 20 * 16_000), duration: 40)
        try joiner.append(result([("ответил", 2.1, 2.3), ("ему", 2.4, 2.7)]),
            chunk: .init(samples: [], startFrame: 18 * 16_000,
                         boundaryFrame: 20 * 16_000, endFrame: 40 * 16_000), duration: 40)
        XCTAssertEqual(joiner.words.map(\.text), ["Я", "ответил", "ему"])
    }

    func testRepeatedWordsAtDifferentTimesAreNotDeduplicated() throws {
        var joiner = TimedTranscriptJoiner()
        try joiner.append(result([("да", 18.8, 19), ("да", 19.1, 19.3)]),
            chunk: .init(samples: [], startFrame: 0, boundaryFrame: 0, endFrame: 20 * 16_000), duration: 40)
        try joiner.append(result([("да", 3, 3.2), ("да", 3.3, 3.5)]),
            chunk: .init(samples: [], startFrame: 18 * 16_000,
                         boundaryFrame: 20 * 16_000, endFrame: 40 * 16_000), duration: 40)
        XCTAssertEqual(joiner.words.map(\.text), ["да", "да", "да", "да"])
        XCTAssertEqual(joiner.words.map(\.start), [18.8, 19.1, 21, 21.3])
    }

    func testEmptyIncomingResultKeepsExistingBoundaryBehavior() throws {
        var joiner = TimedTranscriptJoiner()
        try joiner.append(result([("слово", 19, 19.2), ("контекст", 20.1, 20.3)]),
            chunk: .init(samples: [], startFrame: 0, boundaryFrame: 0, endFrame: 20 * 16_000), duration: 40)
        try joiner.append(result([]),
            chunk: .init(samples: [], startFrame: 18 * 16_000,
                         boundaryFrame: 20 * 16_000, endFrame: 40 * 16_000), duration: 40)
        XCTAssertEqual(joiner.words.map(\.text), ["слово"])
    }
}

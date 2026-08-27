import XCTest
@testable import DictationCore

/// Free rather than a method: these closures are `@Sendable` and an XCTestCase
/// is not, so capturing `self` to build a result would not compile.
private func made(_ text: String) -> ASRResult {
    ASRResult(text: text, audioDuration: 1, processingDuration: 0.01)
}

/// Segments are recognized while the person is still speaking, so the two
/// things that matter are that they come back in the right order and that a
/// failure never yields half a transcript.
final class StreamedSegmentRecognizerTests: XCTestCase {

    func testSegmentsComeBackInTheOrderTheyWereCut() async {
        // Each segment takes longer than the one after it. Without ordering,
        // the fast ones would overtake and the sentence would come out
        // scrambled — which is the whole reason the chain exists.
        let recognizer = StreamedSegmentRecognizer { samples in
            let index = Int(samples.first ?? 0)
            try? await Task.sleep(for: .milliseconds(40 - index * 10))
            return ASRResult(
                text: "segment\(index)",
                audioDuration: 1,
                processingDuration: 0.01
            )
        }

        for index in 0..<4 { recognizer.submit([Float(index)]) }

        guard case let .recognized(texts) = await recognizer.finish() else {
            return XCTFail("expected the stream to have recognized everything")
        }
        XCTAssertEqual(texts, ["segment0", "segment1", "segment2", "segment3"])
    }

    func testOneDecodeRunsAtATime() async {
        // The runtime allows only one recognition in flight across every
        // session of a model, so overlapping here would corrupt decodes rather
        // than merely be untidy.
        let counter = ConcurrencyCounter()
        let recognizer = StreamedSegmentRecognizer { [counter] _ in
            counter.enter()
            defer { counter.leave() }
            try? await Task.sleep(for: .milliseconds(20))
            return ASRResult(text: "x", audioDuration: 1, processingDuration: 0)
        }
        for _ in 0..<5 { recognizer.submit([1]) }
        _ = await recognizer.finish()
        XCTAssertEqual(counter.peak, 1, "two decodes must never overlap")
    }

    func testAFailedSegmentPoisonsTheWholeStream() async {
        // Better a slower whole-take decode than a transcript quietly missing
        // its middle.
        let recognizer = StreamedSegmentRecognizer { samples in
            if samples.first == 2 { throw ASREngineError.modelsNotLoaded }
            return ASRResult(text: "ok", audioDuration: 1, processingDuration: 0)
        }
        for index in 0..<4 { recognizer.submit([Float(index)]) }

        guard case .failed = await recognizer.finish() else {
            return XCTFail("a failed segment must fail the stream, not be skipped")
        }
    }

    func testTranscriptsStayAlignedWithTheSegmentsEvenWhenOneIsSilent() async {
        // Alignment is load-bearing: the owner drops the last transcript and
        // re-recognizes it with the tail, and it finds that transcript by
        // index. A silent segment that vanished here would take the wrong one.
        let recognizer = StreamedSegmentRecognizer { samples in
            made(samples.first == 1 ? "" : "words")
        }
        recognizer.submit([0, 0])
        recognizer.submit([1])        // recognizes as nothing: all breath
        recognizer.submit([0, 0, 0])

        guard case let .recognized(texts) = await recognizer.finish() else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(texts, ["words", "", "words"])
        XCTAssertEqual(recognizer.submittedSampleCounts, [2, 1, 3])
    }

    func testSubmissionsAfterFinishAreIgnored() async {
        let recognizer = StreamedSegmentRecognizer { _ in made("a") }
        recognizer.submit([0])
        _ = await recognizer.finish()

        recognizer.submit([0])
        guard case let .recognized(texts) = await recognizer.finish() else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(texts, ["a"], "a late segment must not land after the tail")
    }

    func testNothingSubmittedIsAnEmptyStreamNotAFailure() async {
        let recognizer = StreamedSegmentRecognizer { _ in made("never") }
        guard case let .recognized(texts) = await recognizer.finish() else {
            return XCTFail("a take with no cuts is normal, not broken")
        }
        XCTAssertEqual(texts, [])
    }
}

/// Records the highest number of callers inside the block at once.
private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0

    func enter() {
        lock.withLock {
            current += 1
            peak = max(peak, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}

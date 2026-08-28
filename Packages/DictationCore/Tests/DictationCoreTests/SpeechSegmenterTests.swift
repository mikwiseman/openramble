import XCTest
@testable import DictationCore

/// The segmenter decides where a take may be cut so the engine can start early.
///
/// The tests that matter most here are the ones that prove a cut *does not*
/// happen: the previous attempt at chunking in this project cut phrases in half
/// and lost three times more words than the engine lost on its own.
final class SpeechSegmenterTests: XCTestCase {
    private let rate = 16_000
    /// One frame of the size the microphone tap actually delivers.
    private let frame = 2048

    private var speech: Float { 0.5 }
    private var quiet: Float { 0.0 }

    private func samples(_ seconds: Double) -> Int { Int(seconds * 16_000) }

    /// Parameters for the tests about the *rule*, with a short segment floor so
    /// a ten-second fixture can earn a cut.
    ///
    /// The shipped floor is deliberately far higher, and
    /// `testTheShippedDefaultsRefuseToCutAnOrdinaryTake` is what pins it. Tests
    /// of the mechanism should not have to move every time that number is
    /// tuned, and tuning it should not be able to pass silently either.
    private var mechanism: SpeechSegmenter.Parameters {
        .init(minimumPause: .milliseconds(700), minimumSegment: .seconds(4))
    }

    /// Feed `seconds` of one level, returning every cut offered along the way.
    @discardableResult
    private func feed(
        _ segmenter: inout SpeechSegmenter,
        _ level: Float,
        seconds: Double
    ) -> [Int] {
        var cuts: [Int] = []
        var remaining = samples(seconds)
        while remaining > 0 {
            let count = min(frame, remaining)
            if let cut = segmenter.observe(peak: level, count: count) { cuts.append(cut) }
            remaining -= count
        }
        return cuts
    }

    // MARK: - The rule that makes this safe

    func testUnbrokenSpeechIsNeverCut() {
        var segmenter = SpeechSegmenter()
        // Five minutes without a pause. Latency suffers; the words do not.
        let cuts = feed(&segmenter, speech, seconds: 300)
        XCTAssertEqual(cuts, [], "speech must never be cut, however long it runs")
    }

    func testAPauseShorterThanRequiredDoesNotCut() {
        var segmenter = SpeechSegmenter()
        feed(&segmenter, speech, seconds: 10)
        let cuts = feed(&segmenter, quiet, seconds: 0.4)
        XCTAssertEqual(cuts, [], "400 ms is under the 700 ms default and is not a boundary")
    }

    func testSilenceBeforeTheFirstWordIsNotAPause() {
        var segmenter = SpeechSegmenter()
        // Someone holds the key and thinks for ten seconds before speaking.
        let cuts = feed(&segmenter, quiet, seconds: 10)
        XCTAssertEqual(cuts, [], "a take must not be cut before it has any speech in it")
    }

    func testAPauseBeforeEnoughAudioHasAccumulatedDoesNotCut() {
        var segmenter = SpeechSegmenter()
        feed(&segmenter, speech, seconds: 1)
        let cuts = feed(&segmenter, quiet, seconds: 2)
        XCTAssertEqual(cuts, [], "one second of speech is not worth its own decode")
    }

    // MARK: - Cutting

    func testAQualifyingPauseCutsInTheMiddleOfTheSilence() {
        var segmenter = SpeechSegmenter(parameters: mechanism)
        feed(&segmenter, speech, seconds: 10)
        let cuts = feed(&segmenter, quiet, seconds: 1.0)

        XCTAssertEqual(cuts.count, 1)
        guard let cut = cuts.first else { return }

        // The cut is offered as soon as the pause qualifies, so the silence
        // seen at that moment is the required 700 ms, not the full second. The
        // seam sits half way through it: ~10 s of speech plus ~350 ms.
        let expected = samples(10) + samples(0.35)
        XCTAssertEqual(Double(cut), Double(expected), accuracy: Double(frame),
                       "the seam belongs in the middle of the silence that earned it")
    }

    func testBothSidesOfTheSeamAreSilent() {
        var segmenter = SpeechSegmenter(parameters: mechanism)
        feed(&segmenter, speech, seconds: 10)
        guard let cut = feed(&segmenter, quiet, seconds: 1.0).first else {
            return XCTFail("expected a cut")
        }
        // Everything after 10 s was silence, so a seam past 10 s closes a
        // segment that ends quiet, and half the pause remains on the other side.
        XCTAssertGreaterThan(cut, samples(10) - frame,
                             "the closing segment must end in silence, not mid-word")
    }

    func testOffsetsAreRelativeToTheSegmentSoTheCallerNeverTracksPosition() {
        var segmenter = SpeechSegmenter(parameters: mechanism)
        var cuts: [Int] = []
        // Three sentences, each ten seconds, each followed by a full pause.
        for _ in 0..<3 {
            feed(&segmenter, speech, seconds: 10)
            cuts += feed(&segmenter, quiet, seconds: 1.0)
        }
        XCTAssertEqual(cuts.count, 3, "each sentence should have earned its own cut")
        // Every offset is measured from the start of its own segment, so they
        // are all about the same rather than growing.
        for cut in cuts {
            XCTAssertEqual(Double(cut), Double(samples(10) + samples(0.35)),
                           accuracy: Double(samples(1.2)),
                           "offsets must not accumulate across segments")
        }
    }

    func testTheShippedDefaultsRefuseToCutAnOrdinaryTake() {
        // The whole point of the shipped floor. A sixteen-second take with a
        // clear pause in it is one decode, because cutting it would buy no time
        // anybody can feel and would spend a draw on a language decision this
        // engine sometimes gets wrong.
        var segmenter = SpeechSegmenter()
        feed(&segmenter, speech, seconds: 10)
        var cuts = feed(&segmenter, quiet, seconds: 1.5)
        cuts += feed(&segmenter, speech, seconds: 4.5)
        XCTAssertEqual(cuts, [], "an ordinary take must reach the engine whole")

        // And a long one still streams, or the feature would not exist.
        var long = SpeechSegmenter()
        feed(&long, speech, seconds: 20)
        XCTAssertEqual(feed(&long, quiet, seconds: 1.5).count, 1,
                       "past the floor a real pause should still earn a cut")
    }

    // MARK: - The floor the decoder actually has

    func testATailShorterThanTheSubmissionFloorIsNotCutOffOnItsOwn() {
        var segmenter = SpeechSegmenter(
            parameters: .init(minimumPause: .milliseconds(700),
                              minimumSegment: .milliseconds(500),
                              minimumSubmission: .seconds(2))
        )
        feed(&segmenter, speech, seconds: 0.6)
        let cuts = feed(&segmenter, quiet, seconds: 1.0)
        XCTAssertEqual(cuts, [],
                       "below the submission floor the decoder is non-monotonic; keep it whole")
    }

    func testPendingIsSubmittableTracksTheFloor() {
        var segmenter = SpeechSegmenter()
        feed(&segmenter, speech, seconds: 1)
        XCTAssertFalse(segmenter.pendingIsSubmittable)
        feed(&segmenter, speech, seconds: 2)
        XCTAssertTrue(segmenter.pendingIsSubmittable)
    }

    // MARK: - Relaxation

    func testTheThresholdRelaxesOnceTheSegmentIsLong() {
        var segmenter = SpeechSegmenter(
            parameters: .init(minimumPause: .milliseconds(700),
                              minimumSegment: .seconds(4),
                              minimumSubmission: .seconds(2),
                              relaxAfter: .seconds(20),
                              relaxedPause: .milliseconds(350))
        )
        // Under the relaxation point a 400 ms pause is not enough.
        feed(&segmenter, speech, seconds: 10)
        XCTAssertEqual(feed(&segmenter, quiet, seconds: 0.4), [])

        // Past it, the same pause is.
        feed(&segmenter, speech, seconds: 15)
        let cuts = feed(&segmenter, quiet, seconds: 0.4)
        XCTAssertEqual(cuts.count, 1,
                       "a long segment should take a shorter pause rather than keep growing")
    }

    func testRelaxationStillRefusesToCutThroughSpeech() {
        var segmenter = SpeechSegmenter(
            parameters: .init(relaxAfter: .seconds(5), relaxedPause: .milliseconds(350))
        )
        let cuts = feed(&segmenter, speech, seconds: 120)
        XCTAssertEqual(cuts, [], "relaxation lowers the pause bar, it does not remove it")
    }

    // MARK: - Lifecycle

    func testResetForgetsThePendingSegment() {
        var segmenter = SpeechSegmenter()
        feed(&segmenter, speech, seconds: 10)
        segmenter.reset()
        XCTAssertEqual(segmenter.pendingSampleCount, 0)
        // And the new take is again not cuttable before its first word.
        XCTAssertEqual(feed(&segmenter, quiet, seconds: 5), [])
    }

    func testABriefDipInsideAWordDoesNotAccumulateIntoAPause() {
        var segmenter = SpeechSegmenter()
        feed(&segmenter, speech, seconds: 10)
        // Ten stop closures, each well under the threshold, separated by speech.
        var cuts: [Int] = []
        for _ in 0..<10 {
            cuts += feed(&segmenter, quiet, seconds: 0.12)
            cuts += feed(&segmenter, speech, seconds: 0.3)
        }
        XCTAssertEqual(cuts, [], "consonant closures are not pauses and must not add up")
    }
}

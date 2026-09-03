import XCTest
@testable import DictationCore

/// `SpeechSegmenter` with a ceiling, producing absolute positions.
final class MeetingSegmentPolicyTests: XCTestCase {
    private let frame = 1_600 // 100 ms
    private var speech: Float { 0.5 }
    private var quiet: Float { 0.0 }

    private func frames(_ seconds: Double) -> Int { Int(seconds * 16_000) }

    /// Feed `seconds` of one level, collecting every segment produced.
    @discardableResult
    private func feed(_ policy: inout MeetingSegmentPolicy, _ level: Float, seconds: Double) -> [MeetingSegmentRef] {
        var out: [MeetingSegmentRef] = []
        var remaining = frames(seconds)
        while remaining > 0 {
            let count = min(frame, remaining)
            if let segment = policy.observe(peak: level, count: count) { out.append(segment) }
            remaining -= count
        }
        return out
    }

    func testAPauseAfterTheMinimumSegmentCutsAtAbsoluteFrames() {
        var policy = MeetingSegmentPolicy(channel: .system, startFrame: 32_000)
        XCTAssertEqual(feed(&policy, speech, seconds: 12), [])
        let cuts = feed(&policy, quiet, seconds: 1)
        XCTAssertEqual(cuts.count, 1)
        let cut = cuts[0]
        XCTAssertEqual(cut.channel, .system)
        XCTAssertEqual(cut.startFrame, 32_000, "positions are absolute in the file")
        // The cut lands inside the pause: after the speech, before its end.
        XCTAssertGreaterThan(cut.frameCount, frames(12))
        XCTAssertLessThan(cut.frameCount, frames(13))
    }

    func testNothingIsCutBeforeTheMinimumSegment() {
        var policy = MeetingSegmentPolicy(channel: .microphone)
        feed(&policy, speech, seconds: 5)
        XCTAssertEqual(feed(&policy, quiet, seconds: 2), [])
        XCTAssertEqual(policy.pendingFrames, frames(7))
    }

    func testContinuousSpeechIsCutAtTheQuietestRecentFrameOnceItPassesTheCap() {
        var policy = MeetingSegmentPolicy(channel: .microphone)
        // 19.5 s loud, one softer frame, then loud again past the cap.
        feed(&policy, speech, seconds: 19.5)
        XCTAssertNil(policy.observe(peak: 0.1, count: frame))
        let cuts = feed(&policy, speech, seconds: 1)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].startFrame, 0)
        XCTAssertEqual(cuts[0].frameCount, frames(19.5) + frame, "at the end of the quiet frame, not at the cap")
        // 19.5 s + the quiet frame + 1 s were fed; the cut took 19.6 s of it.
        XCTAssertEqual(policy.pendingFrames, frames(20.6) - cuts[0].frameCount, "the remainder is accounted for exactly")
    }

    func testUniformlyLoudSpeechIsCutAtTheCap() {
        var policy = MeetingSegmentPolicy(channel: .microphone)
        let cuts = feed(&policy, speech, seconds: 25)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].frameCount, frames(20))
    }

    func testAfterAForcedCutTheRemainderCanBeCutAgain() {
        var policy = MeetingSegmentPolicy(channel: .microphone)
        var all = feed(&policy, speech, seconds: 20)
        all += feed(&policy, speech, seconds: 12)
        all += feed(&policy, quiet, seconds: 1)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[1].startFrame, all[0].endFrame, "segments abut")
    }

    func testFlushReturnsTheTailOnlyIfSomeoneSpokeInIt() {
        var policy = MeetingSegmentPolicy(channel: .microphone)
        feed(&policy, quiet, seconds: 3)
        XCTAssertNil(policy.flush(), "three seconds of room tone is not a segment")
        feed(&policy, speech, seconds: 3)
        let tail = policy.flush()
        XCTAssertEqual(tail?.startFrame, frames(3))
        XCTAssertEqual(tail?.frameCount, frames(3))
        XCTAssertNil(policy.flush(), "flushed once")
        XCTAssertEqual(policy.pendingFrames, 0)
    }

    func testTheRemainderOfAPauseCutIsNotFlushedAsSpeech() {
        var policy = MeetingSegmentPolicy(channel: .microphone)
        feed(&policy, speech, seconds: 12)
        XCTAssertEqual(feed(&policy, quiet, seconds: 1).count, 1)
        XCTAssertNil(policy.flush(), "what is left after the cut is the second half of a pause")
    }

    func testASilentChannelProducesNoSegmentsAtAll() {
        // The property the cost model rests on: the other side's silence
        // costs no decode.
        var policy = MeetingSegmentPolicy(channel: .system)
        XCTAssertEqual(feed(&policy, quiet, seconds: 120), [])
        XCTAssertNil(policy.flush())
    }

    func testAnHourOfSilenceBeforeTheFirstWordIsNotDecodedWithIt() {
        var policy = MeetingSegmentPolicy(channel: .system)
        feed(&policy, quiet, seconds: 3_600)
        XCTAssertLessThanOrEqual(policy.pendingFrames, frames(1.1), "the start slides forward under silence")
        feed(&policy, speech, seconds: 12)
        let cuts = feed(&policy, quiet, seconds: 1)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertGreaterThanOrEqual(cuts[0].startFrame, frames(3_599), "the segment begins just before the word")
        XCTAssertLessThan(cuts[0].frameCount, frames(14))
    }
}

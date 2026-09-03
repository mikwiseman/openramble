import DictationAudio
import DictationCore
import XCTest

/// The tap fails by succeeding, so its health is an inference — and this is
/// the table the inference is made from.
final class CaptureHealthTests: XCTestCase {
    private let now = ContinuousClock.now

    private func health(
        buffers: Bool = true, audibleSecondsAgo: TimeInterval? = nil
    ) -> MeetingCapture.ChannelHealth {
        MeetingCapture.ChannelHealth(
            everDeliveredBuffers: buffers,
            everDeliveredAudio: audibleSecondsAgo != nil,
            lastBlockAt: buffers ? now : nil,
            lastAudibleAt: audibleSecondsAgo.map { now - .seconds($0) }
        )
    }

    private func make(
        supported: Bool = true, requested: Bool = true, failure: String? = nil,
        elapsed: TimeInterval, health: MeetingCapture.ChannelHealth
    ) -> CaptureHealth {
        CaptureHealth.make(
            isSupported: supported, requested: requested, startFailure: failure,
            elapsed: elapsed, health: health, now: now
        )
    }

    func testAnOldMacAndAVoiceNoteAreNotFailures() {
        XCTAssertEqual(make(supported: false, elapsed: 100, health: health(buffers: false)), .unsupported)
        XCTAssertEqual(make(requested: false, elapsed: 100, health: health(buffers: false)), .notRequested)
        XCTAssertNil(CaptureHealth.notRequested.title)
        XCTAssertFalse(CaptureHealth.notRequested.marksRecordingDegraded)
    }

    func testTheFirstThreeSecondsMeanNothingYet() {
        XCTAssertEqual(make(elapsed: 1, health: health(buffers: false)), .verifying)
        XCTAssertEqual(make(elapsed: 2.9, health: health(buffers: true)), .verifying)
        XCTAssertNil(CaptureHealth.verifying.title)
    }

    func testNotEvenTheProbeArrivingIsAnUnheardTapWhateverTheBuffersSay() {
        // Buffers of silence are what a denied tap delivers; they prove nothing.
        XCTAssertEqual(make(elapsed: 3.5, health: health(buffers: true)), .unheard(elapsed: 3.5))
        XCTAssertEqual(make(elapsed: 3.5, health: health(buffers: false)), .unheard(elapsed: 3.5))
        let state = CaptureHealth.unheard(elapsed: 3.5)
        XCTAssertEqual(state.title, "Only your microphone is being recorded")
        XCTAssertEqual(state.role, .attention)
        XCTAssertTrue(state.marksRecordingDegraded)
        XCTAssertEqual(state.announcement, "The other side is not being captured.")
        XCTAssertTrue(state.detail?.contains("relaunch") ?? false, "a grant to a running process needs a relaunch")
    }

    func testTheProbeOrAVoiceHeardMeansCapturingAndSilenceHasToAge() {
        XCTAssertEqual(make(elapsed: 2, health: health(audibleSecondsAgo: 0.1)), .capturing(secondsSinceSound: 0.1))
        let quiet = make(elapsed: 600, health: health(audibleSecondsAgo: 45))
        XCTAssertEqual(quiet, .capturing(secondsSinceSound: 45), "nobody talking for 45 s is a meeting, not a failure")
        XCTAssertNil(quiet.title)
        XCTAssertFalse(quiet.marksRecordingDegraded)
    }

    func testAMinuteOfSilenceAfterSoundIsWorthSaying() {
        let state = make(elapsed: 600, health: health(audibleSecondsAgo: 125))
        XCTAssertEqual(state, .wentSilent(secondsSinceSound: 125))
        XCTAssertEqual(state.title, "The other side went quiet 2 min ago")
        XCTAssertEqual(state.role, .attention)
        XCTAssertTrue(state.marksRecordingDegraded)
    }

    func testATapThatCouldNotStartSaysWhy() {
        let state = make(failure: "the audio tap could not be created (-1)", elapsed: 0, health: health(buffers: false))
        XCTAssertEqual(state, .unavailable(reason: "the audio tap could not be created (-1)"))
        XCTAssertEqual(state.detail, "the audio tap could not be created (-1)")
        XCTAssertTrue(state.marksRecordingDegraded)
    }

    func testNothingHereIsEverRed() {
        let states: [CaptureHealth] = [
            .unsupported, .notRequested, .verifying, .capturing(secondsSinceSound: 1),
            .unheard(elapsed: 10), .wentSilent(secondsSinceSound: 100), .unavailable(reason: "x"),
        ]
        for state in states { XCTAssertNotEqual(state.role, .recording, "\(state)") }
    }
}

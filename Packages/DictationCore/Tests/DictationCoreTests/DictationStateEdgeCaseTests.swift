import XCTest
@testable import DictationCore

/// Addition to the main policy checks: states to which the usual scenario
/// does not reach, but in which the application gets from quick presses.
final class DictationStateEdgeCaseTests: XCTestCase {

    // MARK: - Busy

    func testEverySessionStateCountsAsBusy() {
        // Busyness protects against a second session over the first:
        // it is enough to forget one state to get two records at once
        // and two texts inserted mixed.
        XCTAssertFalse(DictationState.idle.isBusy)
        for state in [DictationState.preparing, .listening, .transcribing, .inserting] {
            XCTAssertTrue(state.isBusy, "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)")
        }
    }

    // MARK: - Start

    func testStartIsRefusedFromEveryNonIdleState() {
        // The hotkey is pressed faster than recognition occurs. Each
        // such a click should be rejected, and not start a second recording.
        for state in [DictationState.preparing, .listening, .transcribing, .inserting] {
            XCTAssertFalse(
                DictationStopPolicy.canStart(state: state, isEnabled: true, isModelReady: true),
                "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)"
            )
        }
    }

    func testStartNeedsBothPermissionAndModel() {
        // Both reasons for failure are independent, and neither should override the other.
        XCTAssertFalse(DictationStopPolicy.canStart(state: .idle, isEnabled: false, isModelReady: false))
        XCTAssertTrue(DictationStopPolicy.canStart(state: .idle, isEnabled: true, isModelReady: true))
    }

    // MARK: - Speakerphone

    func testHandsFreeIgnoresReleaseEvenWithoutASession() {
        // The speakerphone sign is checked before the state, so releasing
        // keys in hands-free mode don't mean anything at all - including
        // the case when there is no session.
        for state in [DictationState.idle, .preparing, .listening, .transcribing, .inserting] {
            XCTAssertEqual(
                DictationStopPolicy.decideStop(state: state, isHandsFree: true),
                .ignore,
                "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)"
            )
        }
    }

    // MARK: - Record too short

    func testShortPressBoundaryIsExact() {
        // The border runs exactly along the declared minimum: a little shorter -
        // a person has changed his mind, just that much - it’s already speech.
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: 0))
        XCTAssertFalse(
            DictationDurationPolicy.isWorthTranscribing(duration: DictationDurationPolicy.minimum - 0.01)
        )
        XCTAssertTrue(
            DictationDurationPolicy.isWorthTranscribing(duration: DictationDurationPolicy.minimum)
        )
    }

    func testNegativeDurationIsNotWorthTranscribing() {
        // Negative duration should not come, but if it comes due to
        // change the clock, there is nothing to recognize from it.
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: -1))
    }

    func testEmptyRecordingAfterALongHoldIsAMicrophoneFault() {
        // The same empty record, two completely different stories. A person
        // touched a key - he changed his mind, and there is nothing to tell him.
        // A person held the key for twelve seconds and spoke - and the recording
        // is empty: the microphone is muted, dead or taken by another
        // application. Being silent here means losing an entire paragraph without
        // a single word of explanation.
        XCTAssertEqual(DictationDurationPolicy.outcomeForShortRecording(held: 12), .reportSilentInput)
        XCTAssertEqual(
            DictationDurationPolicy.outcomeForShortRecording(
                held: DictationDurationPolicy.minimumHoldForSilentInput
            ),
            .reportSilentInput
        )
        XCTAssertEqual(DictationDurationPolicy.outcomeForShortRecording(held: 0.2), .dropSilently)
        XCTAssertEqual(DictationDurationPolicy.outcomeForShortRecording(held: 0), .dropSilently)
    }

    // MARK: - Duration limit

    func testFreshRecordingKeepsGoing() {
        XCTAssertEqual(DictationDurationPolicy.action(elapsed: 0), .keepRecording)
        XCTAssertEqual(
            DictationDurationPolicy.action(elapsed: DictationDurationPolicy.maximum - 0.5),
            .keepRecording
        )
    }

    // MARK: - Continued finalization

    func testFinalizationStopsWhenBothCancellationSignalsFire() {
        XCTAssertFalse(
            DictationFinalizationPolicy.shouldContinue(
                state: .inserting,
                cancellationRequested: true,
                taskCancelled: true
            )
        )
    }

    func testFinalizationContinuesWhileInserting() {
        // Insertion is the last state from which completion is still
        // meaningful: the text is already ready and is waiting to be sent to someone else's application.
        XCTAssertTrue(
            DictationFinalizationPolicy.shouldContinue(
                state: .inserting,
                cancellationRequested: false,
                taskCancelled: false
            )
        )
    }
}

import XCTest
@testable import DictationCore

/// These rules look like a trifle, but it is on them that dictations in production break down:
/// a lost key release leaves the recording enabled, and an extra one
/// finalization inserts the text twice.
final class DictationStatePolicyTests: XCTestCase {

    // MARK: - Release the key

    func testReleaseDuringPreparingIsRemembered() {
        // The most common gesture: a short phrase, the key was released earlier,
        // what raised the sound engine. Letting go cannot be lost.
        let decision = DictationStopPolicy.decideStop(state: .preparing, isHandsFree: false)

        XCTAssertEqual(decision, .deferUntilListening)
    }

    func testReleaseWhileListeningStopsImmediately() {
        XCTAssertEqual(
            DictationStopPolicy.decideStop(state: .listening, isHandsFree: false),
            .stopNow
        )
    }

    func testHandsFreeIgnoresRelease() {
        // In hands-free mode, recording is stopped with a second press.
        // If you react to release, the dictation will end immediately after the start.
        for state in [DictationState.preparing, .listening] {
            XCTAssertEqual(
                DictationStopPolicy.decideStop(state: state, isHandsFree: true),
                .ignore,
                "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)"
            )
        }
    }

    func testReleaseDuringFinalizationIsIgnored() {
        // Otherwise, finalization will run a second time and the text will be inserted twice.
        for state in [DictationState.transcribing, .inserting] {
            XCTAssertEqual(
                DictationStopPolicy.decideStop(state: state, isHandsFree: false),
                .ignore,
                "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)"
            )
        }
    }

    func testReleaseWithoutSessionDoesNothing() {
        XCTAssertEqual(
            DictationStopPolicy.decideStop(state: .idle, isHandsFree: false),
            .noSession
        )
    }

    // MARK: - Start

    func testStartRequiresIdleEnabledAndModel() {
        XCTAssertTrue(DictationStopPolicy.canStart(state: .idle, isEnabled: true, isModelReady: true))

        // Busy session - we don’t start a new one on top.
        XCTAssertFalse(DictationStopPolicy.canStart(state: .listening, isEnabled: true, isModelReady: true))
        // Without a model there is nothing to recognize: it’s better not to start than to write down and fail.
        XCTAssertFalse(DictationStopPolicy.canStart(state: .idle, isEnabled: true, isModelReady: false))
        XCTAssertFalse(DictationStopPolicy.canStart(state: .idle, isEnabled: false, isModelReady: true))
    }

    // MARK: - Cancel

    func testCancelIsPossibleUntilInsertionStarts() {
        XCTAssertTrue(DictationStopPolicy.canCancel(state: .preparing))
        XCTAssertTrue(DictationStopPolicy.canCancel(state: .listening))
        XCTAssertTrue(DictationStopPolicy.canCancel(state: .transcribing))

        // The insertion has already gone to someone else's application - there is nothing to recall.
        XCTAssertFalse(DictationStopPolicy.canCancel(state: .inserting))
        XCTAssertFalse(DictationStopPolicy.canCancel(state: .idle))
    }

    // MARK: - Continued finalization

    func testFinalizationStopsOnCancellation() {
        XCTAssertFalse(
            DictationFinalizationPolicy.shouldContinue(
                state: .transcribing,
                cancellationRequested: true,
                taskCancelled: false
            ),
            "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0437}\u{0430}\u{043F}\u{0440}\u{043E}\u{0441}\u{0430} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} \u{0434}\u{043E}\u{0432}\u{043E}\u{0434}\u{0438}\u{0442}\u{044C} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{043D}\u{0435}\u{043B}\u{044C}\u{0437}\u{044F}"
        )
        XCTAssertFalse(
            DictationFinalizationPolicy.shouldContinue(
                state: .transcribing,
                cancellationRequested: false,
                taskCancelled: true
            )
        )
    }

    func testFinalizationContinuesInNormalFlow() {
        XCTAssertTrue(
            DictationFinalizationPolicy.shouldContinue(
                state: .transcribing,
                cancellationRequested: false,
                taskCancelled: false
            )
        )
    }

    func testFinalizationRefusesFromWrongState() {
        // If the state has already been reset to idle, then the session has been terminated -
        // it's too late to insert text.
        for state in [DictationState.idle, .preparing, .listening] {
            XCTAssertFalse(
                DictationFinalizationPolicy.shouldContinue(
                    state: state,
                    cancellationRequested: false,
                    taskCancelled: false
                ),
                "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)"
            )
        }
    }

    // MARK: - Microphone

    func testMicrophoneIsOnlyLiveWhileListening() {
        // The "recording light turns off when we're not listening" promise holds true
        // exactly this: in all other states the engine is turned off.
        XCTAssertTrue(DictationState.listening.isCapturing)
        for state in [DictationState.idle, .preparing, .transcribing, .inserting] {
            XCTAssertFalse(state.isCapturing, "\u{0421}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \(state)")
        }
    }

}

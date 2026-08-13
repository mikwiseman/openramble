import XCTest
@testable import DictationCore

// MARK: - False edges that can break in parts

actor ScriptedCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var abortCount = 0
    private var duration: TimeInterval = 2.0
    private var startError: Error?
    private let file = URL(fileURLWithPath: "/tmp/scripted-take.wav")

    func setDuration(_ value: TimeInterval) { duration = value }
    func setStartError(_ error: Error?) { startError = error }

    func startRecording() async throws -> URL {
        startCount += 1
        if let startError { throw startError }
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        (file, duration)
    }

    func abortRecording() async { abortCount += 1 }
}

/// Pasting and pressing Return break independently: they are different system calls,
/// and the second one refuses to live while the first one is alive.
actor ScriptedInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    private var insertError: TextInsertionError?
    private var returnError: TextInsertionError?
    private var insertDelay: Duration = .zero

    func setInsertError(_ error: TextInsertionError?) { insertError = error }
    func setReturnError(_ error: TextInsertionError?) { returnError = error }
    func setInsertDelay(_ delay: Duration) { insertDelay = delay }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if insertDelay > .zero { try? await Task.sleep(for: insertDelay) }
        if let insertError { throw insertError }
        insertedTexts.append(text)
    }

    func pressReturn() async throws {
        if let returnError { throw returnError }
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { nil }
}

actor CollectingOverlay: OverlayPresenting {
    private(set) var notices: [DictationNotice] = []
    func present(_ state: DictationState, elapsed: TimeInterval) async {}
    func dismiss() async {}
    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

actor SilentSounds: Sounding {
    func playAttention() async {}
}

@MainActor
final class StateLog {
    var states: [DictationState] = []
}

// MARK: - Tests

/// The paths the product takes when something goes wrong. They are the ones who decide
/// does a person trust dictation: he sees a normal script every day, but
/// failure behavior - once, and remembers it for a long time.
@MainActor
final class DictationControllerFailurePathTests: XCTestCase {
    private var capture: ScriptedCapture!
    private var inserter: ScriptedInserter!
    private var overlay: CollectingOverlay!
    private var transcribeCalls: TranscribeCounter!

    /// Recognition call count - the closure is sent as `@Sendable`.
    actor TranscribeCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    override func setUp() async throws {
        capture = ScriptedCapture()
        inserter = ScriptedInserter()
        overlay = CollectingOverlay()
        transcribeCalls = TranscribeCounter()
    }

    /// The clock that the test moves itself: you cannot wait an hour to check the limit.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        func advance(by seconds: TimeInterval) {
            lock.lock(); offset += seconds; lock.unlock()
        }
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return Date().addingTimeInterval(offset)
        }
    }

    private func makeController(
        recognized: String = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
        allowPressReturnCommand: Bool = false,
        clock: TestClock? = nil
    ) -> DictationController {
        let counter = transcribeCalls!
        return DictationController(
            capture: capture,
            transcribe: { _ in
                await counter.increment()
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: SilentSounds(),
            pipeline: { TextPipeline(allowPressReturnCommand: allowPressReturnCommand) },
            now: { clock?.now ?? Date() }
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func runFullDictation(_ controller: DictationController) async {
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
    }

    /// The audio daemon is dead at press time — coreaudiod restarts were
    /// observed overnight in the field. One session fails with a plain
    /// notice, and the very NEXT press works once audio is back. A crashed
    /// engine bricking every hotkey until app restart is Handy 0.9.5's
    /// failure mode; ours must stay a one-session event.
    func testCaptureStartFailureSurfacesAndTheNextPressWorks() async throws {
        let controller = makeController(recognized: "after recovery")
        await capture.setStartError(AudioCaptureError.notRecording)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .idle, "a failed start must free the session")
        let notice = await overlay.notices.last
        XCTAssertEqual(notice?.kind, .failure)
        XCTAssertEqual(notice?.message, "Couldn't record audio.")

        await capture.setStartError(nil)
        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        // The pipeline capitalizes the sentence start — that's the healthy path.
        XCTAssertEqual(inserted, ["After recovery"], "the next press must dictate normally")
    }

    /// However long the person speaks, the session is theirs to finish.
    /// A one-hour cap once lived here "for safety"; this pins its absence.
    func testAThreeHourRecordingIsStillTheUsersToFinish() async throws {
        let clock = TestClock()
        let controller = makeController(recognized: "\u{0434}\u{043B}\u{0438}\u{043D}\u{043D}\u{0430}\u{044F} \u{0440}\u{0435}\u{0447}\u{044C}", clock: clock)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        clock.advance(by: 3 * 3600)
        await settle()
        XCTAssertEqual(controller.state, .listening, "nothing may stop a long recording but the person")

        controller.stop()
        await settle()
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["\u{0414}\u{043B}\u{0438}\u{043D}\u{043D}\u{0430}\u{044F} \u{0440}\u{0435}\u{0447}\u{044C}"])
    }

    // MARK: - Press Return

    func testFailedReturnDoesNotPretendTheTextWasLost() async throws {
        // The text was inserted, but pressing Return failed - for example, the user
        // keeps the modifier this way. Say “text is not inserted, it is saved”
        // this is not true twice: the text is in place, and its second copy is on disk
        // no one needs it - the private tool does not add the dictated text
        // for no reason.
        await inserter.setReturnError(.modifiersStillHeld)
        let controller = makeController(recognized: "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", allowPressReturnCommand: true)

        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices

        XCTAssertEqual(inserted, ["\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}"], "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{0435}\u{043D}\u{043D}\u{044B}\u{043C}")
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertTrue(
            notices.contains { $0.message.contains("Return") },
            "\u{0421}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043E}\u{0431}\u{044A}\u{044F}\u{0441}\u{043D}\u{044F}\u{0442}\u{044C}, \u{0447}\u{0442}\u{043E} \u{043D}\u{0435} \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} \u{0438}\u{043C}\u{0435}\u{043D}\u{043D}\u{043E} \u{043D}\u{0430}\u{0436}\u{0430}\u{0442}\u{0438}\u{0435}: \(notices)"
        )
        XCTAssertNil(controller.pendingRecovery, "\u{0421}\u{043F}\u{0430}\u{0441}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E} — \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0430} \u{043C}\u{0435}\u{0441}\u{0442}\u{0435}")
        XCTAssertEqual(controller.state, .idle)
    }

    func testSuccessfulReturnLeavesNoNotice() async throws {
        let controller = makeController(recognized: "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", allowPressReturnCommand: true)

        await runFullDictation(controller)

        let presses = await inserter.returnPresses
        let notices = await overlay.notices
        XCTAssertEqual(presses, 1)
        XCTAssertTrue(notices.isEmpty, "\u{0423}\u{0434}\u{0430}\u{0447}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043D}\u{0438}\u{0447}\u{0435}\u{0433}\u{043E} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0430}\u{0442}\u{044C}")
    }

    // MARK: - Save text

    func testInsertionFailureKeepsTextOnlyInMemory() async throws {
        await inserter.setInsertError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "\u{0432}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")

        await runFullDictation(controller)

        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .warning)
        XCTAssertEqual(controller.pendingRecovery?.text, "\u{0412}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")
        XCTAssertEqual(controller.state, .idle, "\u{0421}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432} \u{043B}\u{044E}\u{0431}\u{043E}\u{043C} \u{0441}\u{043B}\u{0443}\u{0447}\u{0430}\u{0435}")
    }

    func testNextDictationKeepsPreviousRecoverableTextUntilExplicitRecovery() async throws {
        await inserter.setInsertError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "\u{0432}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")
        await runFullDictation(controller)
        XCTAssertNotNil(controller.pendingRecovery)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        XCTAssertEqual(controller.pendingRecovery?.text, "\u{0412}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")
    }

    // MARK: - Press too short

    func testAccidentalTapIsDroppedWithoutBotheringTheEngine() async throws {
        // Touch a key - no recording. Drive recognition and even more so frighten
        // there is no room for human error.
        await capture.setDuration(0.1)
        let controller = makeController()

        await runFullDictation(controller)

        let calls = await transcribeCalls.count
        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertEqual(calls, 0, "\u{0420}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E}")
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(notices.isEmpty, "\u{0421}\u{043B}\u{0443}\u{0447}\u{0430}\u{0439}\u{043D}\u{043E}\u{0435} \u{043A}\u{0430}\u{0441}\u{0430}\u{043D}\u{0438}\u{0435} — \u{043D}\u{0435} \u{043F}\u{043E}\u{0432}\u{043E}\u{0434} \u{0434}\u{043B}\u{044F} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{044F}")
        XCTAssertEqual(controller.state, .idle)
    }

    func testLongHoldWithAnEmptyRecordingBlamesTheMicrophone() async throws {
        // The key was held for twelve seconds of wall clock, and the capture
        // returned zero: the input is muted, the USB microphone is dead, or
        // another application is holding the device. The guard above is about “I
        // changed my mind”, but it only looked at the recorded audio - so a person
        // who dictated a whole paragraph got nothing at all: no text, no message,
        // no sound.
        await capture.setDuration(0)
        let clock = TestClock()
        let controller = makeController(clock: clock)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        clock.advance(by: 12)
        controller.stop()
        await settle()

        let calls = await transcribeCalls.count
        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertEqual(calls, 0, "\u{0420}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E}")
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(notices.count, 1, "\u{041C}\u{043E}\u{043B}\u{0447}\u{0430}\u{0442}\u{044C} \u{0437}\u{0434}\u{0435}\u{0441}\u{044C} \u{043D}\u{0435}\u{043B}\u{044C}\u{0437}\u{044F}: \(notices.map(\.message))")
        XCTAssertEqual(notices.first?.kind, .failure, "\u{042D}\u{0442}\u{043E} \u{043D}\u{0435} «\u{043F}\u{0435}\u{0440}\u{0435}\u{0434}\u{0443}\u{043C}\u{0430}\u{043B}», \u{0430} \u{043D}\u{0435}\u{0438}\u{0441}\u{043F}\u{0440}\u{0430}\u{0432}\u{043D}\u{044B}\u{0439} \u{0432}\u{0445}\u{043E}\u{0434}")
        XCTAssertNil(notices.first?.recoveryAudio, "\u{0421}\u{043F}\u{0430}\u{0441}\u{0430}\u{0442}\u{044C} \u{043F}\u{0443}\u{0441}\u{0442}\u{0443}\u{044E} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435}\u{0437}\u{0430}\u{0447}\u{0435}\u{043C}")
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Empty result

    func testEmptyRecognitionTellsThePersonInsteadOfVanishing() async throws {
        // The man held the key and spoke, but the engine did not hear anything:
        // the wrong microphone was chosen, the environment is noisy, the speech went into the table. Panel
        // just faded out - and this is indistinguishable from “the text was inserted somewhere else”
        // there”: a person goes to look for the missing phrase in someone else’s window.
        let controller = makeController(recognized: "   ")

        await runFullDictation(controller)

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertTrue(inserted.isEmpty, "\u{0412}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E}")
        XCTAssertEqual(notices.count, 1, "\u{041C}\u{043E}\u{043B}\u{0447}\u{0430}\u{0442}\u{044C} \u{0437}\u{0434}\u{0435}\u{0441}\u{044C} \u{043D}\u{0435}\u{043B}\u{044C}\u{0437}\u{044F}: \(notices.map(\.message))")
        XCTAssertEqual(notices.first?.kind, .info, "\u{042D}\u{0442}\u{043E} \u{043D}\u{0435} \u{0441}\u{0431}\u{043E}\u{0439} — \u{0434}\u{0432}\u{0438}\u{0436}\u{043E}\u{043A} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} \u{043D}\u{0435} \u{0440}\u{0430}\u{0441}\u{0441}\u{043B}\u{044B}\u{0448}\u{0430}\u{043B}")
        XCTAssertNil(notices.first?.recoveryAudio, "\u{0413}\u{043E}\u{043B}\u{043E}\u{0441} \u{043D}\u{0435} \u{043E}\u{0441}\u{0442}\u{0430}\u{0451}\u{0442}\u{0441}\u{044F} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}\u{0435}")
        XCTAssertEqual(controller.state, .idle)
    }

    func testEmptyRecognitionAfterCancelStaysSilent() async throws {
        // There is no explanation for the canceled dictation: the person closed it himself.
        let controller = makeController(recognized: "   ")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.cancel()
        await settle(30)

        let notices = await overlay.notices
        XCTAssertTrue(notices.isEmpty, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435} \u{043E} \u{0447}\u{0435}\u{043C}: \(notices.map(\.message))")
    }

    // MARK: - Cancel at insertion time

    func testCancelDuringInsertionCannotTakeTheTextBack() async throws {
        // Cancel, pressed at the moment of insertion, comes too late: event
        // has already gone to someone else's application. It is important that the session is closed
        // correctly, and does not remain hanging in “insert”.
        //
        // The moment “insertion is in progress” is caught by polling, not by fixed sleep:
        // on an overloaded CI-runner `Task.sleep(30ms)` sleeps for two seconds,
        // during which the insertion manages to finish entirely.
        await inserter.setInsertDelay(.milliseconds(800))
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .inserting {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .inserting)

        controller.cancel()
        await settle(40)
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"])
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - State flow

    func testStateChangesArriveOnceAndInOrder() async throws {
        // The interface is subscribed to the state, and permissions are queried once every
        // second. Repeating the same state would mean unnecessary
        // redrawing the settings window every second.
        let controller = makeController()
        let log = StateLog()
        controller.onStateChange = { log.states.append($0) }

        await runFullDictation(controller)

        XCTAssertEqual(log.states, [.preparing, .listening, .transcribing, .inserting, .idle])
    }
}

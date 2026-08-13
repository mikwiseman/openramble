import XCTest
@testable import DictationCore

// MARK: - False edges of the system

actor FakeCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    private var startError: AudioCaptureError?
    private let file = URL(fileURLWithPath: "/tmp/fake-take.wav")

    func setStartError(_ error: AudioCaptureError?) { startError = error }

    func startRecording() async throws -> URL {
        startCount += 1
        if let startError { throw startError }
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func abortRecording() async { abortCount += 1 }
}

/// A capture in which the first frame of sound does not come immediately, like the real one.
///
/// The real engine returns from `startRecording` at startup, and hear
/// starts after about 0.13 s. Everything that happens in this gap
/// the fake capture completely concealed without delay.
actor SlowFirstFrameCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// `nil` - the device is silent and there will be no frame at all (AirPods in a drawer).
    private let firstFrame: Gate?
    private let file = URL(fileURLWithPath: "/tmp/slow-first-frame.wav")

    init(firstFrame: Gate?) { self.firstFrame = firstFrame }

    func startRecording() async throws -> URL {
        startCount += 1
        return file
    }

    func waitForFirstFrame() async -> Bool {
        guard let firstFrame else {
            // Silent device: wait until recording finishes outside.
            while stopCount == 0, abortCount == 0 {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        await firstFrame.pass()
        return true
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func abortRecording() async { abortCount += 1 }
}

actor FakeInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    private(set) var targets: [TargetApplication?] = []
    private var error: TextInsertionError?
    nonisolated(unsafe) var frontmost: TargetApplication?

    func setError(_ error: TextInsertionError?) { self.error = error }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if let error { throw error }
        insertedTexts.append(text)
        targets.append(target)
    }

    func pressReturn() async throws {
        if let error { throw error }
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { frontmost }
}

actor FakeOverlay: OverlayPresenting {
    private(set) var presentedStates: [DictationState] = []
    private(set) var dismissCount = 0
    private(set) var notices: [DictationNotice] = []

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        presentedStates.append(state)
    }
    func dismiss() async { dismissCount += 1 }
    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

actor FakeSounds: Sounding {
    private(set) var attentionPlays = 0
    func playAttention() async { attentionPlays += 1 }
}

// MARK: - Tests

@MainActor
final class DictationControllerTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
    }

    private func makeController(
        recognized: String = "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}",
        transcribeDelay: Duration = .zero,
        transcribeError: Error? = nil,
        replacements: [DictionaryReplacement] = []
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                if transcribeDelay > .zero { try await Task.sleep(for: transcribeDelay) }
                if let transcribeError { throw transcribeError }
                return ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(replacements: replacements) }
        )
    }

    /// Let the controller's background tasks finish their work.
    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Normal path

    func testFullFlowInsertsProcessedText() async throws {
        let controller = makeController(recognized: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)
        let firstPresentedStates = await overlay.presentedStates.prefix(2)
        XCTAssertEqual(
            firstPresentedStates,
            [.preparing, .listening],
            "the hotkey must receive immediate visual acknowledgement before capture is ready"
        )

        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"], "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043F}\u{0440}\u{043E}\u{0439}\u{0442}\u{0438} \u{0447}\u{0435}\u{0440}\u{0435}\u{0437} \u{043E}\u{0431}\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{043A}\u{0443}")
        XCTAssertEqual(controller.state, .idle, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{0442}\u{0430}")
    }

    func testRecordingReachesListeningWithoutASound() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        await settle()

        XCTAssertEqual(controller.state, .listening)
        // The panel is the signal that recording started; a chime here would
        // be a second, louder copy of what the person can already see.
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0)
    }

    func testSlowFirstFrameNeitherHangsTheSessionNorSounds() async throws {
        // The microphone takes 0.13–0.14 s on M4 Pro to deliver its first
        // frame (docs/benchmarks.md). The panel must promise "speak" without
        // waiting for it, the session must survive the wait, and nothing may
        // be played on the way — a working dictation is silent.
        let frame = Gate()
        let slowCapture = SlowFirstFrameCapture(firstFrame: frame)
        let controller = DictationController(
            capture: slowCapture,
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .listening, "\u{041F}\u{0430}\u{043D}\u{0435}\u{043B}\u{044C} \u{043F}\u{043E}\u{043A}\u{0430}\u{0437}\u{044B}\u{0432}\u{0430}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0441}\u{0440}\u{0430}\u{0437}\u{0443}")
        let beforeFrame = await sounds.attentionPlays
        XCTAssertEqual(beforeFrame, 0)

        await frame.open()
        await settle()

        XCTAssertEqual(controller.state, .listening, "the arriving frame must not disturb the session")
        let afterFrame = await sounds.attentionPlays
        XCTAssertEqual(afterFrame, 0, "nothing about a healthy recording is worth a sound")
    }

    func testSilentDeviceDoesNotHangTheSession() async throws {
        // There are no frames at all - the wrong microphone was selected. Promise "speak" here
        // it’s not possible, but it’s also impossible to suspend the session by waiting: stopping is required
        // work, otherwise the microphone will remain on until the hour limit.
        let silentCapture = SlowFirstFrameCapture(firstFrame: nil)
        let controller = DictationController(
            capture: silentCapture,
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0, "\u{041C}\u{043E}\u{043B}\u{0447}\u{0430}\u{0449}\u{0435}\u{0435} \u{0443}\u{0441}\u{0442}\u{0440}\u{043E}\u{0439}\u{0441}\u{0442}\u{0432}\u{043E} \u{043D}\u{0435} \u{0434}\u{0430}\u{0451}\u{0442} \u{043F}\u{043E}\u{0432}\u{043E}\u{0434}\u{0430} \u{0437}\u{0432}\u{0430}\u{0442}\u{044C} \u{0433}\u{043E}\u{0432}\u{043E}\u{0440}\u{0438}\u{0442}\u{044C}")

        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "\u{041E}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{0439}\u{0442}\u{0438} \u{0438} \u{0431}\u{0435}\u{0437} \u{0435}\u{0434}\u{0438}\u{043D}\u{043E}\u{0433}\u{043E} \u{043A}\u{0430}\u{0434}\u{0440}\u{0430}")
        let stops = await silentCapture.stopCount
        XCTAssertEqual(stops, 1)
    }

    func testQuickTapStopsWithoutWaitingForTheFirstFrame() async throws {
        // Pressed and released before the engine heard: wait for a frame for the sake of sound
        // there is no need to “speak” in an already completed recording, but in a silent
        // on the device, this wait would leave the microphone on.
        let silentCapture = SlowFirstFrameCapture(firstFrame: nil)
        let controller = DictationController(
            capture: silentCapture,
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "\u{041E}\u{0442}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{043D}\u{043E}\u{0435} \u{043E}\u{0442}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}\u{043D}\u{0438}\u{0435} \u{043D}\u{0435} \u{0436}\u{0434}\u{0451}\u{0442} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0433}\u{043E} \u{043A}\u{0430}\u{0434}\u{0440}\u{0430}")
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0)
    }

    // MARK: Release before ready

    func testReleaseBeforeCaptureStartsIsNotLost() async throws {
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        // The key was released while the engine was still rising - the most common gesture
        // for a short phrase.
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "\u{041E}\u{0442}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}\u{043D}\u{0438}\u{0435} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{0442}\u{044C}\u{0441}\u{044F}")
        XCTAssertEqual(controller.state, .idle, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{043E}\u{0439}")
    }

    // MARK: Uniqueness of finalization

    func testRepeatedStopInsertsOnlyOnce() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.stop()
        controller.stop()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{0440}\u{043E}\u{0432}\u{043D}\u{043E} \u{043E}\u{0434}\u{0438}\u{043D} \u{0440}\u{0430}\u{0437}")
    }

    func testSecondBeginWhileBusyIsIgnored() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        let starts = await capture.startCount
        XCTAssertEqual(starts, 1, "\u{0412}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{043F}\u{043E}\u{0432}\u{0435}\u{0440}\u{0445} \u{0437}\u{0430}\u{043D}\u{044F}\u{0442}\u{043E}\u{0439} \u{043D}\u{0435} \u{043D}\u{0430}\u{0447}\u{0438}\u{043D}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
    }

    // MARK: Cancel

    func testCancelDuringRecordingNeverInserts() async throws {
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        controller.cancel()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F}")
        let aborts = await capture.abortCount
        XCTAssertEqual(aborts, 1, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{0440}\u{0435}\u{0440}\u{0432}\u{0430}\u{043D}\u{0430}, \u{0430} \u{0444}\u{0430}\u{0439}\u{043B} \u{0432}\u{044B}\u{0431}\u{0440}\u{043E}\u{0448}\u{0435}\u{043D}")
        XCTAssertEqual(controller.state, .idle)
    }

    func testCancelDuringTranscriptionNeverInserts() async throws {
        // Recognition takes a noticeable amount of time - we manage to cancel in the middle.
        // The moment “recognition is underway” is caught by the survey: fixed dream on
        // overloaded CI-runner sleeps longer than the entire recognition.
        let controller = makeController(transcribeDelay: .milliseconds(800))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.state, .idle)

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{0432}\u{043E} \u{0432}\u{0440}\u{0435}\u{043C}\u{044F} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{044F} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043F}\u{0440}\u{0435}\u{0434}\u{043E}\u{0442}\u{0432}\u{0440}\u{0430}\u{0442}\u{0438}\u{0442}\u{044C} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0443}")
    }

    // MARK: Errors

    func testCaptureFailureSurfacesAndResets() async throws {
        await capture.setStartError(.microphonePermissionDenied)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .idle)
        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .failure, "\u{041E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{043E}\u{043A}\u{0430}\u{0437}\u{0430}\u{043D}\u{0430}, \u{0430} \u{043D}\u{0435} \u{043F}\u{0440}\u{043E}\u{0433}\u{043B}\u{043E}\u{0447}\u{0435}\u{043D}\u{0430}")
    }

    func testRecognitionFailureIsReported() async throws {
        let controller = makeController(transcribeError: ASREngineError.inferenceFailed("\u{0441}\u{0431}\u{043E}\u{0439}"))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertEqual(notices.first?.kind, .failure)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTextStaysInMemoryWhenInsertionFails() async throws {
        // Insertion failed - recognized data cannot be lost or written to disk.
        await inserter.setError(.accessibilityPermissionDenied)
        let controller = makeController(recognized: "\u{0432}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(controller.pendingRecovery?.text, "\u{0412}\u{0430}\u{0436}\u{043D}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}")
    }

    func testSecureInputFailureExplainsItself() async throws {
        // An active password field is not a product failure, and the message should reflect that.
        await inserter.setError(.secureInputActive)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertTrue(
            notices.contains { $0.message.contains("secure input") },
            "\u{041F}\u{043E}\u{043B}\u{044C}\u{0437}\u{043E}\u{0432}\u{0430}\u{0442}\u{0435}\u{043B}\u{044E} \u{043D}\u{0443}\u{0436}\u{043D}\u{043E} \u{043E}\u{0431}\u{044A}\u{044F}\u{0441}\u{043D}\u{0438}\u{0442}\u{044C}, \u{043F}\u{043E}\u{0447}\u{0435}\u{043C}\u{0443} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{0438}\u{043B}\u{0441}\u{044F}"
        )
    }

    func testClipboardRestoreFailureDoesNotClaimInsertedTextWasLost() async throws {
        await inserter.setError(.insertedButClipboardRestoreFailed)
        let controller = makeController(recognized: "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0443}\u{0436}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{0435}\u{043D}")

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let notices = await overlay.notices
        XCTAssertNil(controller.pendingRecovery)
        XCTAssertTrue(notices.contains { $0.message.contains("The text was inserted") })
    }

    // MARK: Insertion target

    func testTargetIsCapturedAtKeyDownNotAtInsertion() async throws {
        let original = TargetApplication(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1, localizedName: "TextEdit")
        inserter.frontmost = original

        let controller = makeController(transcribeDelay: .milliseconds(60))
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        // While recognition is in progress, the user has switched to another application.
        inserter.frontmost = TargetApplication(bundleIdentifier: "com.apple.Safari", processIdentifier: 2, localizedName: "Safari")
        controller.stop()
        await settle(30)

        let targets = await inserter.targets
        XCTAssertEqual(
            targets.first??.bundleIdentifier,
            "com.apple.TextEdit",
            "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043F}\u{043E}\u{043F}\u{0430}\u{0441}\u{0442}\u{044C} \u{0442}\u{0443}\u{0434}\u{0430}, \u{0433}\u{0434}\u{0435} \u{0435}\u{0433}\u{043E} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{0430}\u{043B}\u{0438}"
        )
    }

    // MARK: Command at the end of the phrase

    func testSafeBetaNeverPressesReturnFromSpeech() async throws {
        let controller = makeController(recognized: "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let presses = await inserter.returnPresses
        XCTAssertEqual(inserted, ["\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}"])
        XCTAssertEqual(presses, 0, "False trigger \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435}")
    }

    func testNewLineCommandArrivesAsTextNotAsKeypress() async throws {
        // The “new line” must reach the input field by wrapping. Press Return
        // not allowed here: it will send a message in the messenger.
        let controller = makeController(recognized: "\u{043F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let presses = await inserter.returnPresses
        XCTAssertEqual(inserted, ["\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}\n"])
        XCTAssertEqual(presses, 0, "Return \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043B} \u{0431}\u{044B} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{0432}\u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441}\u{0430} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}")
    }

    // MARK: Empty result

    func testEmptyRecognitionInsertsNothingAndDoesNotError() async throws {
        // Previously, "no messages" were checked here. The requirement was
        // formulated as “remaining silent is not a mistake”, and this is true: a mistake
        // empty result is not. But silence turned out to be the wrong answer:
        // a darkened panel without text is indistinguishable from “inserted into someone else’s window”,
        // and the person went to look for a phrase where it did not exist. Let's check what
        // required: no error, nothing inserted, vote not saved.
        let controller = makeController(recognized: "   ")
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(
            notices.allSatisfy { $0.kind != .failure },
            "\u{041F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0439} \u{0440}\u{0435}\u{0437}\u{0443}\u{043B}\u{044C}\u{0442}\u{0430}\u{0442} — \u{043D}\u{0435} \u{0441}\u{0431}\u{043E}\u{0439}: \(notices.map(\.message))"
        )
        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Microphone and cleaning

    func testOverlayIsDismissedOnEveryPath() async throws {
        // Successful path.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()
        let afterSuccess = await overlay.dismissCount
        XCTAssertGreaterThan(afterSuccess, 0)

        // Path with cancellation.
        let cancelled = makeController()
        cancelled.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        cancelled.cancel()
        await settle()
        let afterCancel = await overlay.dismissCount
        XCTAssertGreaterThan(afterCancel, afterSuccess, "\u{0418}\u{043D}\u{0434}\u{0438}\u{043A}\u{0430}\u{0442}\u{043E}\u{0440} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0443}\u{0431}\u{0438}\u{0440}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0438} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B}")
    }

    func testDisabledOrMissingModelPreventsStart() async throws {
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: false, isModelReady: true)
        await settle(3)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: false)
        await settle(3)

        let starts = await capture.startCount
        XCTAssertEqual(starts, 0, "\u{0411}\u{0435}\u{0437} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{0438}\u{043B}\u{0438} \u{043F}\u{0440}\u{0438} \u{0432}\u{044B}\u{043A}\u{043B}\u{044E}\u{0447}\u{0435}\u{043D}\u{043D}\u{043E}\u{0439} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0435} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435} \u{043D}\u{0430}\u{0447}\u{0438}\u{043D}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
    }

    // MARK: Hands-free mode

    func testHandsFreeIgnoresKeyRelease() async throws {
        let controller = makeController()
        controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
        await settle()

        // In hands-free mode, releasing the key does nothing.
        controller.stop()
        await settle(4)
        XCTAssertEqual(controller.state, .listening, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{0434}\u{043E}\u{043B}\u{0436}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}")

        controller.stopHandsFree()
        await settle()
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1)
    }
}

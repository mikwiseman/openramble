import XCTest
@testable import DictationCore

/// A wedged engine — a recognition call that never returns — must resolve
/// into a bounded failure that keeps the recording, frees the session, and
/// tells the owner to recycle the engine. Observed in the wild: a CoreML
/// prediction stuck on a restarted system service held "Transcribing…"
/// indefinitely, and Escape was the only exit — at the price of the words.
@MainActor
final class DictationControllerStallTests: XCTestCase {
    private var root: URL!
    private var takes: URL!
    private var recovered: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "stall-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        takes = root.appending(path: "Takes", directoryHint: .isDirectory)
        recovered = root.appending(path: "Recovered", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovered, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private final class FileCapture: AudioCapturing, @unchecked Sendable {
        let directory: URL
        private var lastFile: URL?
        private let freezeDelay: Duration

        init(directory: URL, freezeDelay: Duration = .zero) {
            self.directory = directory
            self.freezeDelay = freezeDelay
        }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("sound".utf8).write(to: url)
            lastFile = url
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile else { throw AudioCaptureError.notRecording }
            if freezeDelay > .zero { try await Task.sleep(for: freezeDelay) }
            return (lastFile, 3.0)
        }

        func abortRecording() async {}
    }

    private final class NullInserter: TextInserting, @unchecked Sendable {
        func frontmostApplication() -> TargetApplication? { nil }
        func insert(_ text: String, into application: TargetApplication?) async throws {}
        func pressReturn() async throws {}
    }

    private actor WedgeInserter: TextInserting {
        enum Wedge: Sendable, Equatable { case insert, pressReturn }

        private let wedge: Wedge
        private(set) var insertedTexts: [String] = []

        init(_ wedge: Wedge) { self.wedge = wedge }

        func insert(_ text: String, into application: TargetApplication?) async throws {
            if wedge == .insert {
                let _: Void = try await suspendForever()
            }
            insertedTexts.append(text)
        }

        func pressReturn() async throws {
            if wedge == .pressReturn {
                let _: Void = try await suspendForever()
            }
        }

        nonisolated func frontmostApplication() -> TargetApplication? { nil }
    }

    private final class NullOverlay: OverlayPresenting, @unchecked Sendable {
        func present(_ state: DictationState, elapsed: TimeInterval) async {}
        func presentNotice(_ notice: DictationNotice) async {}
        func dismiss() async {}
    }

    private final class NullSounds: Sounding, @unchecked Sendable {
        func playAttention() async {}
    }

    private func settle(_ iterations: Int = 40) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testWedgedTranscriptionResolvesKeepsRecordingAndSignalsStall() async throws {
        let capture = FileCapture(directory: takes)
        let controller = DictationController(
            capture: capture,
            // The premise: an engine call stuck on a dead service, deaf to
            // cancellation, never returning.
            transcribe: { _ in try await suspendForever() },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            transcriptionDeadline: { _ in .milliseconds(80) }
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        var stalls = 0
        controller.onTranscriptionStall = { stalls += 1 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle, "a wedged engine must not hold the session")
        XCTAssertEqual(stalls, 1, "the owner is told exactly once to recycle the engine")

        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice.kind, .failure)
        XCTAssertTrue(notice.message.contains("took too long"), notice.message)
        XCTAssertNotNil(notice.recoveryAudio, "the words must survive the stall")
        let kept = try FileManager.default.contentsOfDirectory(atPath: recovered.path)
            .filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(kept.count, 1, "the take moves into safekeeping")
    }

    func testWedgedInsertionReturnsIdleAndKeepsRecognizedTextInMemory() async throws {
        let inserter = WedgeInserter(.insert)
        let controller = DictationController(
            capture: FileCapture(directory: takes),
            transcribe: { _ in
                ASRResult(text: "text that must survive", audioDuration: 2, processingDuration: 0.01)
            },
            inserter: inserter,
            overlay: NullOverlay(),
            sounds: NullSounds(),
            insertionDeadline: .milliseconds(50)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<250 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle, "a cancellation-deaf AX call cannot own the next dictation")
        let recovered = try XCTUnwrap(controller.pendingRecovery)
        XCTAssertEqual(recovered.text, "Text that must survive")
        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice.recoverableText, recovered.text)
        XCTAssertTrue(notice.message.contains("couldn't be confirmed"), notice.message)
    }

    func testWedgedReturnDoesNotHoldSessionAfterTextAlreadyLanded() async throws {
        let inserter = WedgeInserter(.pressReturn)
        let controller = DictationController(
            capture: FileCapture(directory: takes),
            transcribe: { _ in
                ASRResult(text: "message \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", audioDuration: 2, processingDuration: 0.01)
            },
            inserter: inserter,
            overlay: NullOverlay(),
            sounds: NullSounds(),
            pipeline: { TextPipeline(allowPressReturnCommand: true) },
            returnDeadline: .milliseconds(50)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<250 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle)
        let insertedTexts = await inserter.insertedTexts
        XCTAssertEqual(insertedTexts, ["Message"])
        XCTAssertNil(controller.pendingRecovery, "the text itself already landed")
        XCTAssertTrue(notices.contains { $0.message.contains("pressing Return failed") })
    }

    /// A reload that outlives the foreground budget is not mistaken for a
    /// wedged inference. The worker's own preparation watchdog owns recovery;
    /// the controller returns promptly and keeps the take without killing an
    /// otherwise healthy load.
    func testWedgedPrepareReturnsPromptlyWithoutRecyclingHealthyLoad() async throws {
        let capture = FileCapture(directory: takes)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: "never reached", audioDuration: 1, processingDuration: 0.1)
            },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            prepareForTranscription: { try await suspendForever() },
            prepareDeadline: .milliseconds(80)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        var stalls = 0
        controller.onTranscriptionStall = { stalls += 1 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(stalls, 0)
        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice.kind, .failure)
        XCTAssertTrue(notice.message.contains("still getting ready"))
        XCTAssertNotNil(notice.recoveryAudio, "the words survive a wedged reload too")
    }

    /// A healthy prepare adds nothing observable: recognition proceeds.
    func testHealthyPrepareIsInvisible() async throws {
        let capture = FileCapture(directory: takes)
        let preparedBox = UncheckedBox(0)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: "words", audioDuration: 1, processingDuration: 0.1)
            },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            prepareForTranscription: { preparedBox.value += 1 },
            prepareDeadline: .seconds(5)
        )
        var inserted = false
        controller.onTextInserted = { _ in inserted = true }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(preparedBox.value, 1)
        XCTAssertTrue(inserted, "prepare must not disturb a healthy dictation")
    }

    /// Escape during a wedged transcription stays a quiet cancellation:
    /// no stall signal, no failure notice, nothing kept.
    func testCancellationDuringWedgeStaysQuietCancellation() async throws {
        let capture = FileCapture(directory: takes)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in try await suspendForever() },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            transcriptionDeadline: { _ in .seconds(30) }
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        var stalls = 0
        controller.onTranscriptionStall = { stalls += 1 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle(10)
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(stalls, 0)
        XCTAssertFalse(
            notices.contains { $0.kind == .failure },
            "cancellation is the person's choice, not a failure: \(notices.map(\.message))"
        )
    }

    /// The stop→text promise excludes a healthy reload: the foreground budget
    /// is re-anchored by the prepare's actual duration, so the inference
    /// deadline afterwards starts from zero instead of inheriting a clamp.
    func testPrepareExtendsTheStopBudgetByItsActualDuration() async throws {
        let capture = FileCapture(directory: takes, freezeDelay: .milliseconds(40))
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in try await suspendForever() },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            transcriptionDeadline: { _ in .milliseconds(80) },
            prepareForTranscription: { try await Task.sleep(for: .milliseconds(70)) },
            prepareDeadline: .milliseconds(200),
            captureFreezeDeadline: .milliseconds(50),
            recoveryForegroundGrace: .milliseconds(20)
        )
        var stalls = 0
        controller.onTranscriptionStall = { stalls += 1 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        let released = ContinuousClock.now
        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        let elapsed = released.duration(to: .now)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(stalls, 1, "the full inference budget still owns stall recovery")
        XCTAssertGreaterThan(
            elapsed,
            .milliseconds(150),
            "the inference deadline starts only after the reload finished"
        )
        XCTAssertLessThan(
            elapsed,
            .milliseconds(400),
            "stage ceilings still bound the Transcribing wait"
        )
    }

    /// The product case behind wait-and-insert: a reload that outlives the
    /// old stop budget still delivers the words once it completes.
    func testColdPrepareLongerThanStopBudgetStillInsertsText() async throws {
        let capture = FileCapture(directory: takes)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: "words", audioDuration: 1, processingDuration: 0.1)
            },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            transcriptionDeadline: { _ in .milliseconds(80) },
            prepareForTranscription: { try await Task.sleep(for: .milliseconds(300)) },
            prepareDeadline: .seconds(1),
            captureFreezeDeadline: .milliseconds(50)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        var inserted: String?
        controller.onTextInserted = { inserted = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle)
        // The pipeline sentence-cases the raw engine text on the way in.
        XCTAssertEqual(inserted, "Words")
        XCTAssertFalse(
            notices.contains { $0.kind == .failure },
            "a healthy reload is not a failure: \(notices.map(\.message))"
        )
    }

    /// After a cold prepare the wedge containment still works: exactly one
    /// stall, one transcription deadline after the reload finished.
    func testInferenceKeepsFullDeadlineAfterColdPrepare() async throws {
        let capture = FileCapture(directory: takes)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in try await suspendForever() },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            transcriptionDeadline: { _ in .milliseconds(80) },
            prepareForTranscription: { try await Task.sleep(for: .milliseconds(200)) },
            prepareDeadline: .seconds(1),
            recoveryForegroundGrace: .milliseconds(20)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        var stalls = 0
        controller.onTranscriptionStall = { stalls += 1 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(stalls, 1, "the wedge is still contained after the reload wait")
        let notice = try XCTUnwrap(notices.last)
        XCTAssertTrue(notice.message.contains("took too long"))
        XCTAssertNotNil(notice.recoveryAudio, "the words survive the contained wedge")
    }

    /// Escape while waiting out a cold reload stays a quiet cancellation.
    func testCancelDuringColdPrepareWaitStaysQuiet() async throws {
        let capture = FileCapture(directory: takes)
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: "never reached", audioDuration: 1, processingDuration: 0.1)
            },
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered),
            prepareForTranscription: { try await suspendForever() },
            prepareDeadline: .seconds(5)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        var stalls = 0
        controller.onTranscriptionStall = { stalls += 1 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle(10)
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<200 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(stalls, 0)
        XCTAssertFalse(
            notices.contains { $0.kind == .failure },
            "cancelling the wait is the person's choice, not a failure: \(notices.map(\.message))"
        )
    }
}

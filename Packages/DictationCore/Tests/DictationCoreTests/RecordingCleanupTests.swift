import XCTest
@testable import DictationCore

/// The voice recording should not remain on the disk after the text is recognized.
///
/// The defect that these tests guarded was real: files were not deleted
/// never. Half an hour of dictation a day is about twenty gigabytes per year and,
/// more importantly, an archive of everything said out loud from a product that promises
/// privacy.
@MainActor
final class RecordingCleanupTests: XCTestCase {
    private var directory: URL!

    /// A capture that creates a real file - otherwise there is nothing to check.
    ///
    /// Only an unclosed record can interrupt, like a real one: after
    /// `stopRecording` the file is already closed and sent outside, and delete it now
    /// no one other than the session owner.
    private final class FileCapture: AudioCapturing, @unchecked Sendable {
        let directory: URL
        let duration: TimeInterval
        private(set) var lastFile: URL?
        private var isRecording = false
        /// The delay is exactly where it is for a real capture: the file is already
        /// is closed and on disk, but the call has not yet returned. From now on
        /// interrupting the recording does not delete anything - only the owner can delete it.
        private let stopGate: Gate?

        init(directory: URL, duration: TimeInterval = 3.0, stopGate: Gate? = nil) {
            self.directory = directory
            self.duration = duration
            self.stopGate = stopGate
        }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("\u{0437}\u{0432}\u{0443}\u{043A}".utf8).write(to: url)
            lastFile = url
            isRecording = true
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile, isRecording else { throw AudioCaptureError.notRecording }
            isRecording = false
            if let stopGate { await stopGate.pass() }
            return (lastFile, duration)
        }

        func abortRecording() async {
            guard isRecording, let lastFile else { return }
            isRecording = false
            try? FileManager.default.removeItem(at: lastFile)
        }
    }

    // Asynchronous options, not `setUpWithError`: that one is called outside the main
    // actor, and the class is attached to it - access to `directory` would cross
    // isolation boundary. Now this is a warning, but the directory is already
    // is not read from where it is written.
    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "takes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func settle(_ iterations: Int = 15) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeController(
        capture: FileCapture,
        transcribeError: Error? = nil,
        transcribeDelay: Duration = .zero,
        transcribeGate: Gate? = nil,
        transcribeEntered: Gate? = nil,
        insertError: TextInsertionError? = nil,
        overlay: any OverlayPresenting = FakeOverlay(),
        recordingRecovery: any RecordingRecoveryStoring = DiscardingRecordingRecovery()
    ) -> DictationController {
        let inserter = FakeInserter()
        if let insertError {
            Task { await inserter.setError(insertError) }
        }
        return DictationController(
            capture: capture,
            transcribe: { _ in
                if transcribeDelay > .zero { try await Task.sleep(for: transcribeDelay) }
                if let transcribeEntered { await transcribeEntered.open() }
                if let transcribeGate { await transcribeGate.pass() }
                if let transcribeError { throw transcribeError }
                return ASRResult(text: "\u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{043D}\u{043E}", audioDuration: 3, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: FakeSounds(),
            recordingRecovery: recordingRecovery
        )
    }

    func testRecordingIsDeletedAfterSuccessfulInsertion() async throws {
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0433}\u{043E}\u{043B}\u{043E}\u{0441}\u{0430} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{0443}\u{0434}\u{0430}\u{043B}\u{0435}\u{043D}\u{0430}: \(leftovers)")
    }

    func testRecordingIsPreservedWhenRecognitionFails() async throws {
        // If ASR fails, WAV is the only way to repeat the dictation without loss.
        let capture = FileCapture(directory: directory)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let controller = makeController(
            capture: capture,
            transcribeError: ASREngineError.inferenceFailed("\u{0441}\u{0431}\u{043E}\u{0439}"),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let recordings = try FileManager.default.contentsOfDirectory(
            at: recovered,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recordings.filter { $0.pathExtension == "wav" }.count, 1)
    }

    func testRecordingIsDeletedWhenInsertionFails() async throws {
        // The text is saved as a separate file, but there is no need to store the voice itself.
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture, insertError: .accessibilityPermissionDenied)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043D}\u{0435}\u{0443}\u{0434}\u{0430}\u{0447}\u{043D}\u{043E}\u{0439} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0443}\u{0434}\u{0430}\u{043B}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F}: \(leftovers)")
    }

    func testRecordingIsDeletedOnCancel() async throws {
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.cancel()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}: \(leftovers)")
    }

    func testAccidentalTapLeavesNoRecording() async throws {
        // Accidental key touch: nothing to recognize - and that's why
        // the entry is easy to forget. The file is real, with a voice, and it’s there
        // until the next launch of the application, which lives in the menu for weeks.
        let capture = FileCapture(directory: directory, duration: 0.1)
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "\u{0421}\u{043B}\u{0438}\u{0448}\u{043A}\u{043E}\u{043C} \u{043A}\u{043E}\u{0440}\u{043E}\u{0442}\u{043A}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0442}\u{043E}\u{0436}\u{0435} \u{0443}\u{0434}\u{0430}\u{043B}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F}: \(leftovers)")
    }

    func testCancelBeforeRecognitionFailureLeavesNeitherFileNorNotice() async throws {
        // The man pressed Escape, and at that time the engine still managed to fall.
        // Cancellation has already happened: WAV of the canceled dictation has no right to settle
        // in the retry folder, and the failure will be reported as a message. Otherwise Escape
        // leaves exactly the trace that it should get rid of.
        let gate = Gate()
        let entered = Gate()
        let capture = FileCapture(directory: directory)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let overlay = CollectingOverlay()
        let controller = makeController(
            capture: capture,
            transcribeError: ASREngineError.inferenceFailed("\u{0441}\u{0431}\u{043E}\u{0439}"),
            transcribeGate: gate,
            transcribeEntered: entered,
            overlay: overlay,
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        // We are not waiting for the state, but for the fact that the engine has actually started working:
        // state switches synchronously, task does not, and cancel sent
        // earlier than the first line of the task, it would check a completely different branch.
        await entered.pass()
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        await settle()
        await gate.open()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()

        let saved = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertTrue(saved.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F} \u{0434}\u{043B}\u{044F} Retry: \(saved)")

        let takes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        XCTAssertTrue(takes.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0432} Takes: \(takes)")

        let presented = await overlay.notices
        XCTAssertTrue(
            presented.allSatisfy { $0.kind != .failure },
            "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435} \u{043E} \u{0447}\u{0435}\u{043C}: \(presented.map(\.message))"
        )
        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
    }

    func testCancelDuringRescueLeavesNeitherFileNorNotice() async throws {
        // The device disappeared in the middle of a speech: the controller closes the WAV and prepares
        // it to Retry. While the file is being closed, the person presses Escape - and with
        // at this point the dictation has one outcome. A canceled entry has no
        // the rights neither settle on the disk “for replay” nor appear with a message about
        // crash on top of the session that the person started next.
        let gate = Gate()
        let capture = FileCapture(directory: directory, stopGate: gate)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let overlay = CollectingOverlay()
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "\u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{043D}\u{043E}", audioDuration: 3, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: overlay,
            sounds: FakeSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.preserveActiveRecording(reason: "\u{0423}\u{0441}\u{0442}\u{0440}\u{043E}\u{0439}\u{0441}\u{0442}\u{0432}\u{043E} \u{043E}\u{0442}\u{043A}\u{043B}\u{044E}\u{0447}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C}.")
        await settle()
        XCTAssertEqual(controller.state, .transcribing, "\u{0421}\u{043F}\u{0430}\u{0441}\u{0435}\u{043D}\u{0438}\u{0435} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{043E} \u{043D}\u{0430}\u{0447}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}")

        controller.cancel()
        await settle()
        await gate.open()
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()

        let takes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        XCTAssertTrue(takes.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0432} Takes: \(takes)")

        let saved = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertTrue(saved.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F} \u{0434}\u{043B}\u{044F} Retry: \(saved)")

        let presented = await overlay.notices
        XCTAssertTrue(
            presented.allSatisfy { $0.kind != .failure },
            "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{043E} \u{0441}\u{0431}\u{043E}\u{0435} \u{0441}\u{043F}\u{0430}\u{0441}\u{0435}\u{043D}\u{0438}\u{044F} \u{043F}\u{043E}\u{043A}\u{0430}\u{0437}\u{044B}\u{0432}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435} \u{0437}\u{0430} \u{0447}\u{0442}\u{043E}: \(presented.map(\.message))"
        )
        XCTAssertTrue(
            notices.allSatisfy { $0.recoveryAudio == nil },
            "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435} \u{043F}\u{0440}\u{0435}\u{0434}\u{043B}\u{0430}\u{0433}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{0434}\u{043B}\u{044F} Retry"
        )
        XCTAssertEqual(controller.state, .idle)
    }

    /// The device vanished a moment after the start — nothing to rescue.
    ///
    /// A fragment shorter than the recognition minimum is silently deleted by
    /// the main path: the person lost nothing. Rescue must behave the same,
    /// otherwise a one-second device hiccup leaves a "recording for retry"
    /// whose retry forever produces an empty result.
    func testRescueOfTooShortRecordingDiscardsInsteadOfSaving() async throws {
        let capture = FileCapture(directory: directory, duration: 0.1)
        let recovered = directory.appending(path: "RecoveredAudio", directoryHint: .isDirectory)
        let overlay = CollectingOverlay()
        var notices: [DictationNotice] = []
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "recognized", audioDuration: 3, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: overlay,
            sounds: FakeSounds(),
            recordingRecovery: RecordingRecoveryStore(directory: recovered)
        )
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.preserveActiveRecording(reason: "The device disconnected.")
        for _ in 0..<100 where controller.state != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let saved = (try? FileManager.default.contentsOfDirectory(at: recovered, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertTrue(saved.isEmpty, "A fragment below the minimum is not saved: \(saved)")
        let takes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        XCTAssertTrue(takes.isEmpty, "And it does not stay in Takes either: \(takes)")

        XCTAssertTrue(notices.allSatisfy { $0.recoveryAudio == nil })
        XCTAssertTrue(
            notices.contains { $0.message.contains("The device disconnected.") },
            "The reason of the interruption must still be named: \(notices.map(\.message))"
        )
        XCTAssertFalse(
            notices.contains { $0.message.contains("saved locally") || $0.message.contains("Couldn't save") },
            "Nothing to say about rescuing a recording that does not exist: \(notices.map(\.message))"
        )
    }

    func testRecordingIsDeletedWhenCancelledDuringTranscription() async throws {
        // Cancellation occurs when the record is already closed and is on disk: abort
        // there is nothing here, but it is necessary to delete it.
        let capture = FileCapture(directory: directory)
        let controller = makeController(capture: capture, transcribeDelay: .milliseconds(800))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        // The moment “recognition is underway” is caught by the survey: fixed dream on
        // overloaded CI-runner sleeps longer than the entire recognition.
        for _ in 0..<400 where controller.state != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.state, .transcribing)

        controller.cancel()
        for _ in 0..<400 {
            let entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            if entries.isEmpty, controller.state == .idle { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let leftovers = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{0432}\u{043E} \u{0432}\u{0440}\u{0435}\u{043C}\u{044F} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{044F} \u{043D}\u{0435} \u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442} \u{0433}\u{043E}\u{043B}\u{043E}\u{0441} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}\u{0435}: \(leftovers)")
    }
}

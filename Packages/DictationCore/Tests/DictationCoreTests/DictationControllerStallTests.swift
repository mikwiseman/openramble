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

        init(directory: URL) {
            self.directory = directory
        }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("sound".utf8).write(to: url)
            lastFile = url
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile else { throw AudioCaptureError.notRecording }
            return (lastFile, 3.0)
        }

        func abortRecording() async {}
    }

    private final class NullInserter: TextInserting, @unchecked Sendable {
        func frontmostApplication() -> TargetApplication? { nil }
        func insert(_ text: String, into application: TargetApplication?) async throws {}
        func pressReturn() async throws {}
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

    /// A reload that wedges (prepare never returns) flows into the same
    /// recovery as a wedged recognition: bounded failure, recording kept,
    /// stall signalled — the person is never held hostage by a cold engine.
    func testWedgedPrepareResolvesLikeAWedgedTranscription() async throws {
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
        XCTAssertEqual(stalls, 1)
        let notice = try XCTUnwrap(notices.last)
        XCTAssertEqual(notice.kind, .failure)
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
}

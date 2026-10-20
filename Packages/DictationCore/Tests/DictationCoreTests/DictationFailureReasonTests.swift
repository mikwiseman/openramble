import XCTest
@testable import DictationCore

/// Every failed take names its cause. The local journal keeps the case name
/// and never the message, so this name is the only thing that can tell a
/// silent microphone from a microphone that never started.
@MainActor
final class DictationFailureReasonTests: XCTestCase {
    private var takes: URL!

    override func setUp() async throws {
        takes = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "failure-reason-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: takes)
    }

    private final class FileCapture: AudioCapturing, @unchecked Sendable {
        let directory: URL
        let duration: TimeInterval
        private var lastFile: URL?

        init(directory: URL, duration: TimeInterval = 3) {
            self.directory = directory
            self.duration = duration
        }

        func startRecording() async throws -> URL {
            let url = directory.appending(path: "take-\(UUID().uuidString).wav")
            try Data("sound".utf8).write(to: url)
            lastFile = url
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let lastFile else { throw AudioCaptureError.notRecording }
            return (lastFile, duration)
        }

        func abortRecording() async {}
    }

    /// A microphone that never finishes starting.
    private final class StuckCapture: AudioCapturing, @unchecked Sendable {
        func startRecording() async throws -> URL { try await suspendForever() }
        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            throw AudioCaptureError.notRecording
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

    private struct EngineFailure: Error {}

    private func controller(
        capture: any AudioCapturing,
        transcribe: @escaping @Sendable (URL) async throws -> ASRResult = { _ in
            ASRResult(text: "ok", audioDuration: 3, processingDuration: 0)
        }
    ) -> (DictationController, () -> [DictationNotice]) {
        let controller = DictationController(
            capture: capture,
            transcribe: transcribe,
            inserter: NullInserter(),
            overlay: NullOverlay(),
            sounds: NullSounds(),
            preparingStopDeadline: .milliseconds(30)
        )
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        return (controller, { notices })
    }

    private func waitForIdle(_ controller: DictationController) async {
        for _ in 0..<400 where controller.state != .idle {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForListening(_ controller: DictationController) async {
        for _ in 0..<100 where controller.state != .listening {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testAMicrophoneThatNeverStartsIsNamed() async throws {
        let (controller, notices) = controller(capture: StuckCapture())

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        controller.stop()
        await waitForIdle(controller)

        XCTAssertEqual(notices().last?.kind, .failure)
        XCTAssertEqual(notices().last?.reason, .microphoneStartTimedOut)
    }

    func testASilentMicrophoneIsNamed() async throws {
        let (controller, notices) = controller(capture: FileCapture(directory: takes, duration: 0))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitForListening(controller)
        // Long enough that an empty take means a fault, not a short tap.
        try await Task.sleep(for: .seconds(DictationDurationPolicy.minimumHoldForSilentInput + 0.1))
        controller.stop()
        await waitForIdle(controller)

        XCTAssertEqual(notices().last?.kind, .failure)
        XCTAssertEqual(notices().last?.reason, .silentInput)
    }

    func testARecognitionErrorIsNamed() async throws {
        let (controller, notices) = controller(
            capture: FileCapture(directory: takes),
            transcribe: { _ in throw EngineFailure() }
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitForListening(controller)
        controller.stop()
        await waitForIdle(controller)

        XCTAssertEqual(notices().last?.kind, .failure)
        XCTAssertEqual(notices().last?.reason, .recognitionFailed)
    }

    func testAnInterruptedCaptureIsNamed() async throws {
        let (controller, notices) = controller(capture: FileCapture(directory: takes))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitForListening(controller)
        controller.interrupt(reason: "stream failed")
        await waitForIdle(controller)

        XCTAssertEqual(notices().last?.kind, .failure)
        XCTAssertEqual(notices().last?.reason, .captureInterrupted)
    }

    func testARecordingStoppedByTheSystemIsNamed() async throws {
        let (controller, notices) = controller(capture: FileCapture(directory: takes))

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitForListening(controller)
        controller.preserveActiveRecording(reason: "device gone")
        await waitForIdle(controller)

        XCTAssertEqual(notices().last?.kind, .failure)
        XCTAssertEqual(notices().last?.reason, .recordingInterrupted)
    }
}

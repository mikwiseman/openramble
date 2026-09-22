import DictationCore
import XCTest

@MainActor
final class AppStateScreenRecordingTests: XCTestCase {
    private var harness: AppHarness!

    private func makeState() throws -> AppState {
        harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        harness.defaults.set(true, forKey: AppState.systemAudioDeclinedKey)
        return harness.makeState()
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testReturningFromSettingsRefreshesLiveStateWithoutStartingCapture() async throws {
        let state = try makeState()
        defer { harness.tearDown() }

        state.prepareScreenRecording()
        try await waitForDisplayLoad(state)
        XCTAssertEqual(state.screenDisplays.count, 1)
        XCTAssertEqual(state.meetingState, .idle)

        harness.screenCameraPermission = .denied
        state.retryScreenRecordingSetup()
        try await waitUntil { state.screenCameraPermission == .denied }

        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(state.screenSetupIssue, nil)
        XCTAssertEqual(harness.screenCapture.startCount, 0)
    }

    func testNotDeterminedMicrophoneIsRequestedInContextAndDoesNotStart() async throws {
        let state = try makeState()
        defer { harness.tearDown() }
        harness.screenMicrophonePermission = .notDetermined

        state.prepareScreenRecording()
        try await waitForDisplayLoad(state)
        state.startScreenRecording()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(state.screenSetupIssue, .microphonePermission)
        XCTAssertEqual(harness.microphonePermissionFlow.requestCount, 1)
        XCTAssertEqual(harness.screenCapture.startCount, 0)
    }

    func testDeniedOptionalCameraMustBeResolvedBeforeStart() async throws {
        let state = try makeState()
        defer { harness.tearDown() }
        harness.screenCameraPermission = .denied

        state.prepareScreenRecording()
        try await waitForDisplayLoad(state)
        state.screenRecordingOptions.cameraEnabled = true
        state.refreshScreenRecordingPermissions()
        state.startScreenRecording()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(state.screenSetupIssue, .cameraPermission)
        XCTAssertEqual(harness.screenCapture.startCount, 0)
    }

    func testScreenRecordingPauseResumeAndStopKeepsVideoAlongsideAudio() async throws {
        let state = try makeState()
        defer { harness.tearDown() }

        state.prepareScreenRecording()
        try await waitForDisplayLoad(state)
        state.screenRecordingOptions.cameraEnabled = false
        state.startScreenRecording()
        try await waitUntil { state.meetingState == .recording }

        XCTAssertEqual(harness.screenCapture.preparedCount, 1)
        XCTAssertEqual(harness.screenCapture.startCount, 1)
        state.pauseRecording()
        try await waitUntil { state.meetingState == .paused }
        state.resumeRecording()
        try await waitUntil { state.meetingState == .recording }
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && !state.recordings.isEmpty }

        let recording = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(recording.captureKind, .screen)
        XCTAssertEqual(harness.screenCapture.pauseCount, 1)
        XCTAssertEqual(harness.screenCapture.resumeCount, 1)
        XCTAssertEqual(harness.screenCapture.stopCount, 1)
        XCTAssertNotNil(state.recordingVideoURL(recording.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.recordingVideoURL(recording.id)?.path ?? ""))
    }

    private func waitForDisplayLoad(_ state: AppState) async throws {
        try await waitUntil {
            !state.isLoadingScreenDisplays
                && (!state.screenDisplays.isEmpty || state.screenSetupIssue != nil)
        }
    }
}

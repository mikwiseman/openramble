import DictationAudio
import DictationCore
import XCTest

/// The other side of the call: asked for once, remembered when declined,
/// and never allowed to be missing in silence.
@MainActor
final class AppStateSystemAudioTests: XCTestCase {
    private var harness: AppHarness!

    private func makeHarness() throws -> AppHarness {
        let harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        self.harness = harness
        return harness
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(5),
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

    func testTheFirstPressExplainsItselfAndTheAnswerStartsTheRecording() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()
        guard state.systemAudioMode == .enabled else { throw XCTSkip("this Mac cannot record what it plays") }

        state.startRecording()
        XCTAssertTrue(state.isSystemAudioIntroPresented, "explained once, before any system prompt")
        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(harness.meetingCapture.startCount, 0)

        state.confirmSystemAudioIntro(includeSystemAudio: true)
        XCTAssertFalse(state.isSystemAudioIntroPresented)
        try await waitUntil { state.meetingState == .recording }
        XCTAssertEqual(harness.meetingCapture.includeSystemAudio, true)
        XCTAssertEqual(state.liveRecording?.isMeeting, true)
        XCTAssertEqual(state.liveCaptureHealth, .verifying)

        state.stopRecording()
        try await waitUntil { state.meetingState == .idle }
        // The next press does not explain again.
        state.startRecording()
        XCTAssertFalse(state.isSystemAudioIntroPresented)
        try await waitUntil { state.meetingState == .recording }
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle }
    }

    func testDecliningIsRememberedAndTheChevronCanTakeItBack() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()
        guard state.systemAudioMode == .enabled else { throw XCTSkip("this Mac cannot record what it plays") }

        state.startRecording()
        state.confirmSystemAudioIntro(includeSystemAudio: false)
        try await waitUntil { state.meetingState == .recording }
        XCTAssertEqual(harness.meetingCapture.includeSystemAudio, false)
        XCTAssertEqual(state.liveRecording?.isMeeting, false)
        XCTAssertEqual(state.liveCaptureHealth, .notRequested)
        XCTAssertEqual(state.systemAudioMode, .declined)
        XCTAssertEqual(state.systemAudioPermission, .declined)
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle }

        state.startRecording()
        XCTAssertFalse(state.isSystemAudioIntroPresented, "declined means declined, not asked again")
        try await waitUntil { state.meetingState == .recording }
        XCTAssertEqual(harness.meetingCapture.includeSystemAudio, false)
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle }

        state.setSystemAudioDeclined(false)
        XCTAssertEqual(state.systemAudioMode, .enabled)
        XCTAssertEqual(state.systemAudioPermission, .notChecked)
    }

    func testAnUnheardOtherSideIsSaidOutLoudMarkedOnTheRecordingAndRememberedForSettings() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.defaults.set(true, forKey: AppState.systemAudioIntroShownKey)
        let state = harness.makeState()
        guard state.systemAudioMode == .enabled else { throw XCTSkip("this Mac cannot record what it plays") }

        // The fake never hears anything on the system channel.
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        XCTAssertEqual(state.liveCaptureHealth, .verifying)
        try await waitUntil({ state.liveCaptureHealth.marksRecordingDegraded }, timeout: .seconds(6))
        if case .unheard = state.liveCaptureHealth {} else { XCTFail("expected unheard, got \(state.liveCaptureHealth)") }
        XCTAssertEqual(harness.announcer.messages, ["The other side is not being captured."])
        XCTAssertTrue(harness.announcer.announcements.first?.urgent ?? false)

        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && !state.recordings.isEmpty }
        let filed = try XCTUnwrap(state.recordings.first)
        XCTAssertNotNil(RecordingsPlaceholder.degradedNote(for: filed), "the recording carries the mark")
        XCTAssertEqual(state.systemAudioPermission, .unheard)
        XCTAssertEqual(state.liveCaptureHealth, .notRequested)
        state.performSystemAudioAction()
        XCTAssertEqual(harness.systemAudioSettingsOpened, 1)
    }

    func testAHeardOtherSideIsCapturingAndTheSettingsRowSaysWorking() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.defaults.set(true, forKey: AppState.systemAudioIntroShownKey)
        harness.meetingCapture.systemHealth = MeetingCapture.ChannelHealth(
            everDeliveredBuffers: true, everDeliveredAudio: true, lastBlockAt: .now, lastAudibleAt: .now
        )
        let state = harness.makeState()
        guard state.systemAudioMode == .enabled else { throw XCTSkip("this Mac cannot record what it plays") }

        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        try await waitUntil({
            if case .capturing = state.liveCaptureHealth { return true }
            return false
        }, timeout: .seconds(3))
        XCTAssertEqual(harness.announcer.messages, ["The other side is being captured."])
        XCTAssertFalse(state.liveCaptureHealth.marksRecordingDegraded)

        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && !state.recordings.isEmpty }
        XCTAssertEqual(state.systemAudioPermission, .working)
        let filed = try XCTUnwrap(state.recordings.first)
        XCTAssertNil(RecordingsPlaceholder.degradedNote(for: filed))
        XCTAssertEqual(filed.systemAudio.outputTransport, "fake")
    }
}

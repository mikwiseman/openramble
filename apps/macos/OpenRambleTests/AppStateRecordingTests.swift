import DictationAudio
import DictationCore
import XCTest

/// Start, the live state, stop, filing — the whole loop with no microphone.
@MainActor
final class AppStateRecordingTests: XCTestCase {
    private var harness: AppHarness!

    /// Built inside each test rather than in `setUp`: XCTest's lifecycle
    /// methods are nonisolated and the harness is main-actor bound.
    private func makeHarness() throws -> AppHarness {
        let harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        // These tests are about the microphone path; the other side has its
        // own suite. Declined, the button records without asking first.
        harness.defaults.set(true, forKey: AppState.systemAudioDeclinedKey)
        self.harness = harness
        return harness
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(3),
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

    private func recordOne(_ state: AppState) async throws -> MeetingRecordingMetadata {
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && !state.recordings.isEmpty }
        return try XCTUnwrap(state.recordings.first)
    }

    func testARecordingStartsIsFiledWhenStoppedAndListed() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()
        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(state.recordings, [])

        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        XCTAssertEqual(harness.meetingCapture.startCount, 1)
        let live = try XCTUnwrap(state.liveRecording)
        let directory = try XCTUnwrap(harness.meetingCapture.directory)
        XCTAssertEqual(directory.lastPathComponent, live.id.uuidString)
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, ".incomplete")

        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && !state.recordings.isEmpty }
        XCTAssertEqual(harness.meetingCapture.stopCount, 1)
        XCTAssertNil(state.liveRecording)
        let filed = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(filed.id, live.id)
        XCTAssertEqual(filed.duration, 2)
        XCTAssertEqual(filed.endReason, .stoppedByUser)
        XCTAssertEqual(filed.microphoneDeviceName, "Fake Microphone")
        XCTAssertEqual(state.lastFinishedRecordingID, live.id)
        let published = try AppPaths(root: harness.root).recordings().appending(path: live.id.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(atPath: published.path), "moved out of .incomplete")
    }

    func testWithoutMicrophonePermissionNothingStartsAndThePersonIsAsked() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.permissions.microphoneGranted = false
        let state = harness.makeState()
        state.startRecording()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(harness.meetingCapture.startCount, 0)
        XCTAssertEqual(state.lastNotice?.kind, .warning)
    }

    func testAStartFailureLeavesNothingBehindAndSaysWhy() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.meetingCapture.startError = .diskFull
        let state = harness.makeState()
        state.startRecording()
        try await waitUntil { state.lastNotice != nil }
        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertNil(state.liveRecording)
        XCTAssertEqual(state.lastNotice?.kind, .failure)
        XCTAssertTrue(state.lastNotice?.message.contains("space") ?? false)
        let incomplete = try AppPaths(root: harness.root).recordings().appending(path: ".incomplete")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: incomplete.path)) ?? []
        XCTAssertEqual(leftovers, [], "the directory prepared for it is gone")
    }

    func testPauseAndResumeReachTheRecorder() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        state.pauseRecording()
        try await waitUntil { state.meetingState == .paused }
        XCTAssertEqual(harness.meetingCapture.pauseCount, 1)
        state.resumeRecording()
        try await waitUntil { state.meetingState == .recording }
        XCTAssertEqual(harness.meetingCapture.resumeCount, 1)
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle }
    }

    func testAFullDiskEndsTheRecordingWithTheReasonKept() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.meetingCapture.endReason = .diskFull
        let state = harness.makeState()
        let filed = try await recordOne(state)
        XCTAssertEqual(filed.endReason, .diskFull)
        XCTAssertEqual(state.lastNotice?.kind, .warning)
        XCTAssertTrue(state.lastNotice?.message.contains("kept") ?? false)
    }

    func testRenameAndTrash() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let state = harness.makeState()
        let filed = try await recordOne(state)
        state.renameRecording(filed.id, title: "Budget review")
        XCTAssertEqual(state.recordings.first?.title, "Budget review")
        state.trashRecording(filed.id)
        XCTAssertEqual(state.recordings, [])
        XCTAssertEqual(state.recordingsBytes, 0)
    }

    func testARecordingLeftByACrashIsRecoveredAndDisclosedAtLaunch() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let store = MeetingStore(root: try AppPaths(root: harness.root).recordings())
        let id = UUID()
        let directory = store.incompleteDirectory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(
            microphone: [Float](repeating: 0.2, count: 16_000),
            system: [Float](repeating: 0, count: 16_000)
        )
        writer.abandon()

        let state = harness.makeState()
        XCTAssertEqual(state.recordings.map(\.id), [id])
        XCTAssertEqual(state.recordings.first?.endReason, .crashRecovered)
        XCTAssertEqual(state.recordings.first?.duration, 1)
        XCTAssertEqual(state.lastNotice?.message, "A recording was recovered after an interruption.")
        XCTAssertNotNil(state.recordingAudioURL(id))
    }
}

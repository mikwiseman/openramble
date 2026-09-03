import DictationAudio
import DictationCore
import XCTest

/// The live transcript: segments the recorder hands over become paragraphs
/// while the recording runs, dictation always wins the engine, and the
/// engine is never given back underneath a recording.
@MainActor
final class AppStateTranscriptTests: XCTestCase {
    private var harness: AppHarness!

    private func makeHarness() throws -> AppHarness {
        let harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        try harness.installModelMarker()
        harness.defaults.set(true, forKey: AppState.onboardingCompletedKey)
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

    /// Two seconds of "speech" under the recording, as the recorder would have
    /// written it — left open, because the recorder is still writing.
    private func writeSpeech(into harness: AppHarness, frames: Int = 32_000) throws -> MeetingWriter {
        let directory = try XCTUnwrap(harness.meetingCapture.directory)
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(
            microphone: [Float](repeating: 0.5, count: frames),
            system: [Float](repeating: 0, count: frames)
        )
        return writer
    }

    func testSegmentsBecomeParagraphsWhileRecordingAndTheTranscriptIsFiledAtStop() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let recognizer = ReadinessControlledRecognizer()
        await recognizer.setSamplesText("Can everyone hear me?")
        harness.recognizer = recognizer
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }

        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        let writer = try writeSpeech(into: harness)
        harness.meetingCapture.emitSegment(MeetingSegmentRef(channel: .microphone, startFrame: 0, frameCount: 32_000))
        try await waitUntil { !state.liveTranscript.isEmpty }
        let paragraph = try XCTUnwrap(state.liveTranscript.first)
        XCTAssertEqual(paragraph.text, "Can everyone hear me?")
        XCTAssertEqual(paragraph.channel, .microphone)
        XCTAssertEqual(paragraph.start, 0)
        XCTAssertEqual(paragraph.end, 2)
        XCTAssertEqual(state.transcriptBacklogSeconds, 0, accuracy: 0.001)
        let live = try XCTUnwrap(state.liveRecording)
        XCTAssertEqual(state.transcript(for: live.id).map(\.text), ["Can everyone hear me?"], "live text is what the pane shows")

        try writer.finish()
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && state.transcribingRecordingID == nil }
        let filed = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(filed.transcriptionState, .complete)
        let store = MeetingStore(root: try AppPaths(root: harness.root).recordings())
        XCTAssertEqual(store.transcript(for: filed.id)?.utterances.map(\.text), ["Can everyone hear me?"])
        XCTAssertEqual(state.transcript(for: filed.id).map(\.text), ["Can everyone hear me?"])
    }

    func testTheOtherSideIsItsOwnParagraph() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let recognizer = ReadinessControlledRecognizer()
        await recognizer.setSamplesText("Loud and clear.")
        harness.recognizer = recognizer
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        let writer = try writeSpeech(into: harness, frames: 64_000)
        harness.meetingCapture.emitSegment(MeetingSegmentRef(channel: .microphone, startFrame: 0, frameCount: 32_000))
        harness.meetingCapture.emitSegment(MeetingSegmentRef(channel: .system, startFrame: 32_000, frameCount: 32_000))
        try await waitUntil { state.liveTranscript.count == 2 }
        XCTAssertEqual(state.liveTranscript.map(\.channel), [.microphone, .system])
        try writer.finish()
        state.stopRecording()
        try await waitUntil { state.transcribingRecordingID == nil }
    }

    func testTheEngineIsNotUnloadedWhileARecordingRunsAndIsAfterwards() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        harness.recognizer = ReadinessControlledRecognizer()
        harness.idleUnloadDelayOverride = .milliseconds(40)
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }

        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(state.isEngineReady, "the countdown does not run under a recording")

        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && state.transcribingRecordingID == nil }
        try await waitUntil { !state.isEngineReady }
    }

    func testRepeatedFailuresPauseTranscriptionAndRetryTakesItUpAgain() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let recognizer = ReadinessControlledRecognizer()
        await recognizer.setSamplesError(CocoaError(.fileReadCorruptFile))
        harness.recognizer = recognizer
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        let writer = try writeSpeech(into: harness, frames: 160_000)
        for index in 0..<4 {
            harness.meetingCapture.emitSegment(
                MeetingSegmentRef(channel: .microphone, startFrame: index * 32_000, frameCount: 32_000)
            )
        }
        try await waitUntil { state.isTranscriptionPaused }
        XCTAssertEqual(state.liveTranscript.filter(\.isFailed).count, 3, "three failed paragraphs, then the queue held")
        XCTAssertGreaterThan(state.transcriptBacklogSeconds, 0, "the fourth is still waiting")

        await recognizer.setSamplesError(nil)
        await recognizer.setSamplesText("Back again.")
        state.resumeTranscription()
        try await waitUntil { state.liveTranscript.contains { $0.text == "Back again." } }
        XCTAssertFalse(state.isTranscriptionPaused)
        try writer.finish()
        state.stopRecording()
        try await waitUntil { state.transcribingRecordingID == nil }
        XCTAssertEqual(state.recordings.first?.transcriptionState, .complete)
    }

    func testCopyTranscriptPutsThePlainTextOnTheHostOnlyClipboard() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let recognizer = ReadinessControlledRecognizer()
        await recognizer.setSamplesText("Copied.")
        harness.recognizer = recognizer
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        let writer = try writeSpeech(into: harness)
        harness.meetingCapture.emitSegment(MeetingSegmentRef(channel: .microphone, startFrame: 0, frameCount: 32_000))
        try await waitUntil { !state.liveTranscript.isEmpty }
        try writer.finish()
        state.stopRecording()
        try await waitUntil { state.transcribingRecordingID == nil }
        let filed = try XCTUnwrap(state.recordings.first)
        state.copyTranscript(filed.id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "You · 00:00:00\nCopied.")
    }
}

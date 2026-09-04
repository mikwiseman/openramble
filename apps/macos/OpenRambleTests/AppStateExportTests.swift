import AVFoundation
import DictationAudio
import DictationCore
import XCTest

/// Getting a meeting out of the app: the transcript as Markdown, the audio
/// as something small enough to send.
@MainActor
final class AppStateExportTests: XCTestCase {
    private var harness: AppHarness!
    private var scratch: URL!

    /// A folder of its own per test. Built here rather than in `setUp`,
    /// which is not on the main actor while this suite is.
    private func makeScratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch = url
        return url
    }

    private func makeHarness() throws -> AppHarness {
        let harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        harness.defaults.set(true, forKey: AppState.systemAudioDeclinedKey)
        try harness.installModelMarker()
        harness.defaults.set(true, forKey: AppState.onboardingCompletedKey)
        self.harness = harness
        return harness
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(10),
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

    /// A finished recording with one paragraph on each side, as the app
    /// files it.
    private func record(into state: AppState, seconds: Int = 2) async throws -> MeetingRecordingMetadata {
        state.startRecording()
        try await waitUntil { state.meetingState == .recording }
        let directory = try XCTUnwrap(harness.meetingCapture.directory)
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        let frames = seconds * 16_000
        let tone = (0..<frames).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        try writer.append(microphone: tone, system: tone)
        harness.meetingCapture.emitSegment(
            MeetingSegmentRef(channel: .microphone, startFrame: 0, frameCount: frames / 2)
        )
        harness.meetingCapture.emitSegment(
            MeetingSegmentRef(channel: .system, startFrame: frames / 2, frameCount: frames / 2)
        )
        try await waitUntil { state.liveTranscript.count == 2 }
        try writer.finish()
        state.stopRecording()
        try await waitUntil { state.meetingState == .idle && state.transcribingRecordingID == nil }
        return try XCTUnwrap(state.recordings.first)
    }

    private func makeReadyState() async throws -> AppState {
        let recognizer = ReadinessControlledRecognizer()
        await recognizer.setSamplesText("Right, let's start with the deploy.")
        harness.recognizer = recognizer
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }
        return state
    }

    func testTheTranscriptIsSavedAsMarkdownWithBothSpeakers() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let state = try await makeReadyState()
        let recording = try await record(into: state)

        let url = scratch.appending(path: "transcript.md")
        state.exportTranscript(recording.id, to: url)

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("**You** · 00:00:00"), markdown)
        XCTAssertTrue(markdown.contains("**Others** · 00:00:01"), markdown)
        XCTAssertTrue(markdown.contains("Right, let's start with the deploy."))
        XCTAssertTrue(markdown.contains("produced on this Mac"), "the promise travels with the file")
    }

    /// The one fact a shared transcript must not lose.
    func testADegradedRecordingSaysSoInTheFile() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        harness.defaults.set(false, forKey: AppState.systemAudioDeclinedKey)
        harness.defaults.set(true, forKey: AppState.systemAudioIntroShownKey)
        harness.meetingCapture.systemHealth = MeetingCapture.ChannelHealth(
            everDeliveredBuffers: true,
            everDeliveredAudio: false
        )
        let state = try await makeReadyState()
        let recording = try await record(into: state)
        XCTAssertTrue(recording.isMeeting)
        XCTAssertFalse(recording.systemAudio.everDeliveredAudio)

        let url = scratch.appending(path: "degraded.md")
        state.exportTranscript(recording.id, to: url)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("The other side of this call was not captured."), markdown)
    }

    func testTheAudioIsSavedAsAnM4AWorthSending() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let state = try await makeReadyState()
        let recording = try await record(into: state, seconds: 4)

        let url = scratch.appending(path: "audio.m4a")
        state.exportAudio(recording.id, to: url)
        try await waitUntil { state.audioExportProgress == nil }

        let exported = try AVAudioFile(forReading: url)
        XCTAssertEqual(exported.processingFormat.channelCount, 2, "You in one ear, the other side in the other")
        XCTAssertEqual(Double(exported.length) / exported.processingFormat.sampleRate, 4, accuracy: 0.2)
        let source = try XCTUnwrap(state.recordingAudioURL(recording.id))
        let sourceBytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let exportedBytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        XCTAssertLessThan(exportedBytes * 4, sourceBytes)
    }

    /// The name is the person's title, and it never becomes a path.
    func testTheExportNameComesFromTheTitle() async throws {
        let harness = try makeHarness()
        defer { harness.tearDown() }
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let state = try await makeReadyState()
        let recording = try await record(into: state)

        state.renameRecording(recording.id, title: "Q3/Q4 planning")
        try await waitUntil { state.recordings.first?.title == "Q3/Q4 planning" }
        XCTAssertEqual(state.exportName(recording.id), "Q3 Q4 planning")
    }
}

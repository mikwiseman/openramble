import DictationCore
import XCTest

/// A take the model found no words in is kept in History, not lost; a take
/// that heard only silence says which microphone it came from.
@MainActor
final class AppStateEmptyTakeTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
        try harness.installModelMarker()
        harness.transcription.text = ""
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func dictate(_ state: AppState) async throws {
        await state.refreshModelState()
        harness.monitor.onPress?()
        try await waitUntil { state.dictationState == .listening }
        harness.monitor.onRelease?()
        try await waitUntil { state.dictationState == .idle && state.lastNotice != nil }
    }

    /// Room noise, well under the speech floor.
    private let quiet = [Float](repeating: 0.001, count: 16_000)

    func testAnEmptyTakeWithSoundIsKeptInHistoryWithNoText() async throws {
        await harness.capture.setBufferedSamples(quiet + [0.1] + quiet)
        let state = harness.makeState()

        try await dictate(state)

        let entry = try XCTUnwrap(state.history.first, "the take is in History")
        XCTAssertEqual(entry.text, "")
        XCTAssertNotNil(state.historyAudioURL(for: entry), "with its audio, to play and recognize again")
        XCTAssertEqual(state.lastNotice?.kind, .info)
        XCTAssertEqual(state.lastNotice?.message, "Nothing was recognized — nothing was inserted.")
        let journal = String(decoding: state.diagnostics.snapshot().data, as: UTF8.self)
        XCTAssertTrue(journal.contains("dictationUnrecognized"), "the kept take is counted, numbers only")
    }

    /// The journal counts a wordless take only once History holds it, so the
    /// count can be checked against the rows rather than proving itself.
    func testAWordlessTakeHistoryCouldNotStoreIsNotCounted() async throws {
        await harness.capture.setBufferedSamples(quiet + [0.1] + quiet)
        let history = try AppPaths(root: harness.root).support()
            .appending(path: "History", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: history.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: history.path) }
        let state = harness.makeState()

        try await dictate(state)

        XCTAssertTrue(state.history.isEmpty)
        XCTAssertEqual(state.lastNotice?.message, "Nothing was recognized — nothing was inserted.")
        let journal = String(decoding: state.diagnostics.snapshot().data, as: UTF8.self)
        XCTAssertFalse(journal.contains("dictationUnrecognized"), "counted a row that does not exist")
    }

    /// The name is the microphone the capture was built with: the one chosen
    /// when the app started, or the system default.
    func testSilenceNamesTheMicrophoneTheCaptureRecordsFrom() async throws {
        await harness.capture.setBufferedSamples(quiet)
        let devices = AudioInputDevices.available()
        let chosen = devices.dropFirst().first ?? devices.first
        if let chosen { harness.defaults.set(chosen.uid, forKey: "inputDeviceUID") }
        let state = harness.makeState()

        try await dictate(state)

        XCTAssertTrue(state.history.isEmpty, "silence is not kept")
        let name = chosen?.name ?? AudioInputDevices.recordingName(of: nil)
        XCTAssertEqual(
            state.lastNotice?.message,
            name.map { "Heard only silence from \($0)." } ?? "Nothing was recognized — nothing was inserted."
        )
        XCTAssertEqual(state.lastNotice?.kind, .warning)
        let journal = String(decoding: state.diagnostics.snapshot().data, as: UTF8.self)
        XCTAssertTrue(journal.contains("dictationWarning"), "silence is counted as the warning it is")
        XCTAssertFalse(journal.contains("dictationUnrecognized"))
    }

    private func seedWordlessTake() throws -> AppState {
        let audio = harness.root.appending(path: "seed.wav")
        try Data("RIFF-test-audio".utf8).write(to: audio)
        let history = try AppPaths(root: harness.root).support()
            .appending(path: "History", directoryHint: .isDirectory)
        _ = try DictationHistoryStore(directory: history).record(text: "", audio: audio, limit: 5)
        return harness.makeState()
    }

    func testRecognizingAWordlessTakeAgainToNothingSaysSoAndKeepsIt() async throws {
        harness.recognizer = ReadinessControlledRecognizer()
        let state = try seedWordlessTake()
        try await waitUntil { state.isEngineReady }
        let entry = try XCTUnwrap(state.history.first)

        state.retranscribeHistoryEntry(entry)
        try await waitUntil { state.lastNotice != nil && !state.isRetranscribing }

        XCTAssertEqual(state.lastNotice?.message, "Still nothing recognized.")
        XCTAssertEqual(state.history, [entry])
    }

    func testRecognizingAWordlessTakeAgainToWordsFillsTheRow() async throws {
        let recognizer = ReadinessControlledRecognizer()
        await recognizer.setFileText("hello there")
        harness.recognizer = recognizer
        let state = try seedWordlessTake()
        try await waitUntil { state.isEngineReady }
        let entry = try XCTUnwrap(state.history.first)

        state.retranscribeHistoryEntry(entry)
        try await waitUntil { state.history.first?.text.isEmpty == false && !state.isRetranscribing }

        let filled = try XCTUnwrap(state.history.first)
        XCTAssertEqual(filled.id, entry.id)
        XCTAssertEqual(filled.text, "Hello there")
        XCTAssertNotNil(state.historyAudioURL(for: filled), "the audio stays for another try")
    }
}

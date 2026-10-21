import DictationCore
import XCTest

/// Where a take went shapes its text: paragraphs in prose apps, "Send it." as
/// Return in terminals and nowhere else. The two paths that reuse a finished
/// take — "Recognize again" in History and "Insert Last Dictation" — keep to
/// that: the first reproduces what the take produced and presses nothing, the
/// second never hands a terminal a paragraph break.
@MainActor
final class AppStateTakeDestinationTests: XCTestCase {
    private var harness: AppHarness!
    private var recognizer: ReadinessControlledRecognizer!

    private static let mail = TargetApplication(
        bundleIdentifier: "com.apple.mail", processIdentifier: 42, localizedName: "Mail"
    )
    private static let notes = TargetApplication(
        bundleIdentifier: "com.apple.Notes", processIdentifier: 43, localizedName: "Notes"
    )
    private static let terminal = TargetApplication(
        bundleIdentifier: "com.apple.Terminal", processIdentifier: 44, localizedName: "Terminal"
    )
    private static let console = TargetApplication(
        bundleIdentifier: "com.apple.Console", processIdentifier: 45, localizedName: "Console"
    )

    override func setUp() async throws {
        harness = try AppHarness()
        harness.permissions.microphoneGranted = true
        harness.defaults.set(true, forKey: AppState.onboardingCompletedKey)
        try harness.installModelMarker()
        recognizer = ReadinessControlledRecognizer()
        harness.recognizer = recognizer
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func readyState() async throws -> AppState {
        let state = harness.makeState()
        try await waitUntil { state.isEngineReady }
        return state
    }

    private func heard(_ text: String, words: [ASRResult.Word] = []) -> ASRResult {
        ASRResult(text: text, words: words, audioDuration: 4, processingDuration: 0.05)
    }

    /// One take into `target`. The engine hears `heard` live, and hears it
    /// again when the kept audio is recognized a second time.
    private func dictate(
        _ heard: ASRResult,
        into target: TargetApplication,
        _ state: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        harness.inserter.frontmost = target
        harness.transcription.text = heard.text
        harness.transcription.words = heard.words
        await recognizer.setFileResult(heard)
        let taken = state.history.count
        harness.monitor.onPress?()
        try await waitUntil({ state.dictationState == .listening }, file: file, line: line)
        harness.monitor.onRelease?()
        try await waitUntil(
            { state.history.count > taken && state.dictationState == .idle },
            file: file, line: line
        )
    }

    private func recognizeAgain(
        _ state: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let entry = try XCTUnwrap(state.history.first, file: file, line: line)
        let decodes = await recognizer.fileDecodes
        state.retranscribeHistoryEntry(entry)
        try await waitUntil({ !state.isRetranscribing }, file: file, line: line)
        let decodedAgain = await recognizer.fileDecodes
        XCTAssertEqual(decodedAgain, decodes + 1, "the recording was recognized again", file: file, line: line)
    }

    // MARK: - Recognize again

    func testRecognizeAgainKeepsASpokenParagraphInAProseTake() async throws {
        let state = try await readyState()
        try await dictate(heard("Dear John. New paragraph. Thanks for the notes."), into: Self.mail, state)
        XCTAssertEqual(state.history.first?.text, "Dear John.\n\nThanks for the notes.")

        try await recognizeAgain(state)

        XCTAssertEqual(state.history.first?.text, "Dear John.\n\nThanks for the notes.")
    }

    func testRecognizeAgainKeepsAParagraphMadeByAPause() async throws {
        let state = try await readyState()
        let pause = heard("The tests are green. Next, we ship.", words: [
            .init(text: "The", start: 0.0, end: 0.2), .init(text: "tests", start: 0.2, end: 0.5),
            .init(text: "are", start: 0.5, end: 0.8), .init(text: "green.", start: 0.8, end: 2.96),
            .init(text: "Next,", start: 2.96, end: 3.4), .init(text: "we", start: 3.4, end: 3.6),
            .init(text: "ship.", start: 3.6, end: 4.0),
        ])
        try await dictate(pause, into: Self.mail, state)
        XCTAssertEqual(state.history.first?.text, "The tests are green.\n\nNext, we ship.")

        try await recognizeAgain(state)

        XCTAssertEqual(state.history.first?.text, "The tests are green.\n\nNext, we ship.")
    }

    func testRecognizeAgainLeavesATerminalTakesSendItOffAndPressesNothing() async throws {
        let state = try await readyState()
        try await dictate(heard("Git status. Send it."), into: Self.terminal, state)
        let pressedLive = await harness.inserter.returnPresses
        XCTAssertEqual(pressedLive, 1)
        XCTAssertEqual(state.history.first?.text, "Git status.")

        try await recognizeAgain(state)

        XCTAssertEqual(state.history.first?.text, "Git status.")
        let pressed = await harness.inserter.returnPresses
        XCTAssertEqual(pressed, 1, "recognizing a take again never presses anything")
    }

    // MARK: - Return

    /// Apple's Console is named like a terminal and is a log viewer.
    func testAnAppNamedLikeATerminalGetsNoReturn() async throws {
        let state = try await readyState()
        try await dictate(heard("Kernel errors only. Send it."), into: Self.console, state)

        let inserted = await harness.inserter.insertedTexts
        let pressed = await harness.inserter.returnPresses
        XCTAssertEqual(inserted, ["Kernel errors only. Send it."])
        XCTAssertEqual(pressed, 0)
    }
}

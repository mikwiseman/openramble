import DictationCore
import XCTest

/// The behavior of the panel: when it is on the screen, when it disappears and what it says out loud.
///
/// The window itself is not involved here - it requires a graphical session, which
/// may not be checked. Everything else is checked completely.
@MainActor
final class OverlayModelTests: XCTestCase {
    private var announcer: FakeAnnouncer!
    private var model: OverlayModel!
    private var visibility: [Bool] = []

    override func setUp() async throws {
        announcer = FakeAnnouncer()
        model = OverlayModel(announcer: announcer, noticeDuration: .milliseconds(120))
        visibility = []
        model.onVisibilityChange = { [weak self] visible in self?.visibility.append(visible) }
    }

    // MARK: - Showing and cleaning

    func testScenario001() {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isVisible)

        model.hide()

        XCTAssertFalse(model.isVisible)
        XCTAssertEqual(visibility, [true, false])
    }

    func testScenario002() {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 1)

        XCTAssertEqual(visibility, [true], "the window is raised once per session")
    }

    // MARK: - Counter

    func testScenario003() async throws {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isTicking)

        // The core communicates once at the beginning of the recording and once at the end.
        // If the panel does not count itself, the entire dictation on it is “0 s”.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertGreaterThan(model.elapsed, 0.4)

        model.show(.transcribing, elapsed: model.elapsed)
        XCTAssertFalse(model.isTicking)
    }

    func testScenario004() {
        model.show(.listening, elapsed: 0)
        XCTAssertTrue(model.isTicking)

        model.hide()

        XCTAssertFalse(model.isTicking)
    }

    // MARK: - Messages

    func testScenario005() async throws {
        model.showNotice(DictationNotice(kind: .warning, message: "Text saved."))
        XCTAssertTrue(model.isVisible)

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isVisible)
    }

    /// Cleaning up after the session comes immediately after the message.
    ///
    /// If she takes the panel with her, the person does not have time to read that the text
    /// was not inserted and where is it now.
    func testScenario006() {
        model.showNotice(DictationNotice(kind: .failure, message: "Failed to insert text."))

        model.hide()

        XCTAssertTrue(model.isVisible)
        XCTAssertNotNil(model.notice)
    }

    /// Two identical messages in a row.
    ///
    /// Delayed hiding of the first one recognized “its” message from the text and carried it away
    /// from the screen the second one was shown three times shorter than expected.
    func testScenario007() async throws {
        // Your own panel with a long display period. For the general one it is 120 ms, and check
        // limited by thirty milliseconds of reserve: sleep on a loaded machine
        // flies, the message expires honestly, and the test crashes, not the product.
        // What’s important here is not “how much”, but “the second show starts counting down”
        // again” - this means the margin should be such that the difference is visible
        // during any flight.
        let announcer = FakeAnnouncer()
        let model = OverlayModel(announcer: announcer, noticeDuration: .seconds(5))
        let notice = DictationNotice(kind: .warning, message: "Dictation is currently in progress. Please wait for it to finish.")

        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(50))

        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(model.notice, "the second message disappeared prematurely")
        XCTAssertTrue(model.isVisible)
    }

    func testScenario008() {
        model.showNotice(DictationNotice(kind: .warning, message: "Text saved."))

        model.show(.listening, elapsed: 0)

        XCTAssertNil(model.notice)
        XCTAssertEqual(model.content.title, "Listening")
    }

    /// Delayed hiding belongs to its display.
    ///
    /// Otherwise, it would extinguish the panel of the next dictation that has already begun.
    func testScenario009() async throws {
        model.showNotice(DictationNotice(kind: .info, message: "Hour limit reached."))
        model.show(.listening, elapsed: 0)

        try await Task.sleep(for: .milliseconds(220))

        XCTAssertTrue(model.isVisible, "the ongoing dictation panel has extinguished the tail of the previous message")
    }

    // MARK: - Voice

    func testScenario010() {
        model.show(.listening, elapsed: 0)

        XCTAssertEqual(
            announcer.messages,
            ["Recording."]
        )
        XCTAssertEqual(announcer.announcements.first?.urgent, true)
    }

    /// The counter ticks twice per second.
    ///
    /// Without memory of what was said, VoiceOver would repeat “recording” until the end
    /// dictation and would drown out everything else.
    func testScenario011() {
        model.show(.listening, elapsed: 0)
        model.show(.listening, elapsed: 1)
        model.show(.listening, elapsed: 2)

        XCTAssertEqual(
            announcer.messages,
            ["Recording."]
        )
    }

    func testScenario012() {
        model.show(.listening, elapsed: 0)
        model.hide()

        model.show(.listening, elapsed: 0)

        XCTAssertEqual(
            announcer.messages,
            [
                "Recording.",
                "Recording.",
            ]
        )
    }

    func testScenario013() {
        let notice = DictationNotice(kind: .failure, message: "Failed to record audio.")

        model.showNotice(notice)

        XCTAssertEqual(announcer.messages, ["Failed to record audio."])
        XCTAssertEqual(announcer.announcements.first?.urgent, true)
    }

    func testScenario014() {
        model.show(.preparing, elapsed: 0)
        model.show(.listening, elapsed: 0)
        model.show(.transcribing, elapsed: 3)
        model.show(.inserting, elapsed: 3)

        XCTAssertEqual(
            announcer.messages,
            [
                "Turning on the microphone",
                "Recording.",
                "Recording stopped, transcribing speech",
            ]
        )
    }

    // MARK: - Hint about silence

    /// The most common problem is AirPods in a drawer. A blind person does not see anything
    /// pulse point, no empty preview: without announcement, he learns about
    /// dead microphone only due to an empty result at the very end.
    func testScenario015() {
        model.show(.listening, elapsed: 0)
        announcer.reset()

        model.showSilenceHint()

        XCTAssertTrue(model.showsSilenceHint)
        XCTAssertEqual(announcer.messages, ["No sound detected — check your microphone."])
        XCTAssertEqual(announcer.announcements.first?.urgent, true, "it's too late to wait for the end of someone else's phrase")
    }

    func testScenario016() {
        model.show(.listening, elapsed: 0)
        announcer.reset()

        model.showSilenceHint()
        model.showSilenceHint()
        model.showSilenceHint()

        XCTAssertEqual(announcer.messages.count, 1)
    }

    /// A real microphone signal removes the silence hint immediately.
    func testScenario017() {
        model.show(.listening, elapsed: 0)
        model.showSilenceHint()
        announcer.reset()

        model.updateInputLevel(0.2)

        XCTAssertFalse(model.showsSilenceHint)
        XCTAssertEqual(announcer.messages, [])
    }

    func testScenario018() {
        model.show(.listening, elapsed: 0)
        XCTAssertFalse(model.accessibilityLabel.contains("No sound detected"))

        model.showSilenceHint()

        XCTAssertTrue(
            model.accessibilityLabel.contains("No sound detected — check your microphone."),
            "anyone who searches for a panel with the VoiceOver cursor must learn about a dead microphone"
        )
        XCTAssertTrue(model.accessibilityLabel.contains("Recording"), "state does not disappear from the label")
    }

    /// A new entry starts from scratch: the previous session's hint is not
    /// has the right to hang on the screen and there is nothing to show up again.
    func testScenario019() {
        model.show(.listening, elapsed: 0)
        model.showSilenceHint()
        model.hide()

        model.show(.listening, elapsed: 0)

        XCTAssertFalse(model.showsSilenceHint)
    }

    func testSilenceHintCannotMaskProcessingOrFailure() {
        model.show(.listening, elapsed: 0)
        model.showSilenceHint()

        model.show(.transcribing, elapsed: 0)
        XCTAssertFalse(model.showsSilenceHint)
        XCTAssertEqual(model.content.title, "Transcribing…")

        model.show(.listening, elapsed: 0)
        model.showSilenceHint()
        model.showNotice(DictationNotice(kind: .failure, message: "Microphone disconnected."))
        XCTAssertFalse(model.showsSilenceHint)
        XCTAssertEqual(model.content.title, "Microphone disconnected.")
    }

    func testSilenceHintCannotMaskNoticeAlreadyOnScreen() {
        model.show(.listening, elapsed: 0)
        model.showNotice(DictationNotice(kind: .failure, message: "Microphone disconnected."))
        announcer.reset()

        model.showSilenceHint()

        XCTAssertFalse(model.showsSilenceHint)
        XCTAssertEqual(model.content.title, "Microphone disconnected.")
        XCTAssertEqual(announcer.messages, [], "the silence poll must not interrupt an active notice")
    }

    // MARK: - Waveform

    func testScenario024() {
        model.show(.listening, elapsed: 0)

        XCTAssertEqual(model.waveformSamples.count, OverlayModel.waveformSampleCount)
        XCTAssertTrue(model.waveformSamples.allSatisfy { $0 == 0 })

        model.updateInputLevel(-1)
        model.updateInputLevel(0.25)
        model.updateInputLevel(2)

        XCTAssertEqual(model.waveformSamples.count, OverlayModel.waveformSampleCount)
        XCTAssertEqual(Array(model.waveformSamples.suffix(3)), [0, 0.25, 1])
    }

    func testScenario025() {
        model.show(.listening, elapsed: 0)
        model.updateInputLevel(0.5)
        XCTAssertEqual(model.waveformSamples.last, 0.5)

        model.hide()
        model.show(.listening, elapsed: 0)

        XCTAssertTrue(
            model.waveformSamples.allSatisfy { $0 == 0 },
            "a new dictation must not begin with the previous voice shape"
        )
    }

    func testScenario026() {
        model.show(.transcribing, elapsed: 2)
        XCTAssertTrue(model.isVisible)

        model.show(.inserting, elapsed: 2)

        XCTAssertFalse(model.isVisible, "insertion happens in the destination app, not in the HUD")
        XCTAssertFalse(model.isTicking)
    }

    func testScenario027() async throws {
        let notice = DictationNotice(kind: .warning, message: "Check the microphone.")
        model.showNotice(notice)
        try await Task.sleep(for: .milliseconds(220))

        model.showNotice(notice)

        XCTAssertEqual(
            announcer.messages,
            ["Check the microphone.", "Check the microphone."],
            "an identical warning in a later impression must be announced again"
        )
    }

    func testNoticeDuringRecordingReturnsToLiveHUDAfterExpiry() async throws {
        model.show(.listening, elapsed: 3)
        model.showNotice(DictationNotice(kind: .info, message: "Copied."))

        try await Task.sleep(for: .milliseconds(650))

        XCTAssertEqual(model.state, .listening)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(model.isTicking)
        XCTAssertEqual(model.content.title, "Listening")
        XCTAssertGreaterThan(model.elapsed, 3.4, "notice time must remain part of recording time")
    }
}

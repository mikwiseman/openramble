import DictationCore
import XCTest

/// The dictation panel is the only feedback channel during dictation.
///
/// The application does not have its own window: if the panel is silent, the person does not recognize
/// nothing. What is written on it and what is said about it out loud is checked.
final class OverlayContentTests: XCTestCase {
    private func content(
        _ state: DictationState,
        notice: DictationNotice? = nil,
        elapsed: TimeInterval = 0
    ) -> OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: elapsed)
    }

    // MARK: - States

    func testScenario001() {
        XCTAssertEqual(content(.idle).title, "Done")
        XCTAssertEqual(content(.preparing).title, "Turning on the microphone…")
        XCTAssertEqual(content(.listening).title, "Listening")
        XCTAssertEqual(content(.transcribing).title, "Transcribing…")
        XCTAssertEqual(content(.inserting).title, "Done")
    }

    func testScenario002() {
        XCTAssertEqual(content(.listening).tone, .recording)
        XCTAssertEqual(content(.preparing).tone, .working)
        XCTAssertEqual(content(.transcribing).tone, .working)
        XCTAssertEqual(content(.inserting).tone, .idle)
        XCTAssertEqual(content(.idle).tone, .idle)
    }

    // MARK: - Seconds

    /// Duration is drawn beside the live waveform by the view. The content model does
    /// not present the finished recording length as if it were transcription progress.
    func testScenario003() {
        XCTAssertNil(content(.listening, elapsed: 7).subtitle)
        XCTAssertNil(content(.transcribing, elapsed: 12.4).subtitle)
        XCTAssertNil(content(.preparing, elapsed: 3).subtitle)
        XCTAssertNil(content(.inserting, elapsed: 3).subtitle)
        XCTAssertNil(content(.idle, elapsed: 3).subtitle)
    }

    func testScenario004() {
        XCTAssertNil(content(.listening, elapsed: -2).subtitle)
    }

    /// "5 s" VoiceOver reads as "5 es".
    func testScenario005() {
        XCTAssertEqual(OverlayContent.spokenSeconds(1), "1 second")
        XCTAssertEqual(OverlayContent.spokenSeconds(2), "2 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(4), "4 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(5), "5 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(11), "11 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(12), "12 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(21), "21 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(22), "22 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(25), "25 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(111), "111 seconds")
        XCTAssertEqual(OverlayContent.spokenSeconds(0), "0 seconds")
    }

    func testScenario006() {
        XCTAssertEqual(
            content(.listening, elapsed: 3).accessibilityLabel,
            "Recording, 3 seconds."
        )
        XCTAssertEqual(
            content(.listening, elapsed: 1).accessibilityLabel,
            "Recording, 1 second."
        )
    }

    // MARK: - Announcements

    /// The main announcement throughout the application.
    ///
    /// The panel does not take focus on purpose, there is no icon in the dock, there is no window: without this
    /// phrases: a blind person does not know that the microphone is on.
    func testScenario007() {
        let content = content(.listening)

        XCTAssertEqual(content.announcement, "Recording.")
        XCTAssertTrue(content.isAnnouncementUrgent)
    }

    func testScenario008() {
        XCTAssertEqual(content(.transcribing).announcement, "Recording stopped, transcribing speech")
        XCTAssertNil(content(.inserting).announcement)
        XCTAssertEqual(content(.preparing).announcement, "Turning on the microphone")
    }

    /// The panel is removed from the screen at rest - there is nothing to declare there.
    func testScenario009() {
        XCTAssertNil(content(.idle).announcement)
    }

    // MARK: - Messages

    func testScenario010() {
        let notice = DictationNotice(kind: .warning, message: "Text not inserted: secure input is active.")
        let content = content(.listening, notice: notice, elapsed: 9)

        XCTAssertEqual(content.title, notice.message)
        // The counter next to the message is reset: recording is no longer taking place.
        XCTAssertNil(content.subtitle)
        XCTAssertEqual(content.tone, .warning)
        XCTAssertEqual(content.announcement, notice.message)
    }

    func testScenario011() {
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .info, message: "and")).tone, .info)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .warning, message: "p")).tone, .warning)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .failure, message: "about")).tone, .failure)
    }

    /// A crash interrupts what VoiceOver is currently reading, but a simple notification does not.
    func testScenario012() {
        XCTAssertFalse(content(.idle, notice: DictationNotice(kind: .info, message: "and")).isAnnouncementUrgent)
        XCTAssertTrue(content(.idle, notice: DictationNotice(kind: .warning, message: "p")).isAnnouncementUrgent)
        XCTAssertTrue(content(.idle, notice: DictationNotice(kind: .failure, message: "about")).isAnnouncementUrgent)
    }

    // MARK: - Labels

    func testScenario013() {
        let states: [DictationState] = [.idle, .preparing, .listening, .transcribing, .inserting]
        for state in states {
            XCTAssertFalse(
                content(state).accessibilityLabel.isEmpty,
                "state \(state) is not passed on to VoiceOver at all"
            )
        }
    }
}

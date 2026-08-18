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
        elapsed: TimeInterval = 0,
        isWaitingForEngine: Bool = false
    ) -> OverlayContent {
        OverlayContent.make(
            state: state,
            notice: notice,
            elapsed: elapsed,
            isWaitingForEngine: isWaitingForEngine
        )
    }

    // MARK: - Waiting is not working

    /// A take that has to wait for the model spends that wait in the
    /// transcribing state. Calling it transcription is a lie that grows with
    /// the wait, and the wait can reach the preparation deadline.
    func testWaitingForTheModelIsNotCalledTranscribing() {
        let waiting = content(.transcribing, isWaitingForEngine: true)
        XCTAssertEqual(waiting.title, "Waking the model…")
        XCTAssertNotEqual(waiting.title, content(.transcribing).title)
        // Still work, still not a failure: the words are safe either way.
        XCTAssertEqual(waiting.tone, .working)
        XCTAssertNotNil(waiting.subtitle, "the panel says the words are not lost")
        XCTAssertNotEqual(
            waiting.accessibilityLabel,
            content(.transcribing).accessibilityLabel,
            "VoiceOver hears the difference too"
        )
    }

    /// The flag belongs to the transcribing panel alone. A stray `true` must
    /// not rewrite a state that has nothing to do with a model load.
    func testTheModelWaitDoesNotLeakIntoOtherStates() {
        for state in [DictationState.idle, .preparing, .listening, .inserting] {
            XCTAssertEqual(
                content(state, isWaitingForEngine: true).title,
                content(state).title,
                "\(state) is unchanged by the model wait"
            )
        }
    }

    /// A failure has one explanation, not two. A notice still wins.
    func testANoticeStillOutranksTheModelWait() {
        let notice = DictationNotice(kind: .failure, message: "Something went wrong.")
        XCTAssertEqual(
            content(.transcribing, notice: notice, isWaitingForEngine: true).title,
            "Something went wrong."
        )
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

    // MARK: - Tone rendering policy

    /// One meaning per color, pinned: red only for the live microphone, blue
    /// for working/info, orange for anything that needs the person. Failure
    /// wears orange, not red — every failure here keeps the work recoverable.
    func testScenario014() {
        XCTAssertNil(OverlayContent.Tone.idle.colorRole)
        XCTAssertEqual(OverlayContent.Tone.recording.colorRole, .recording)
        XCTAssertEqual(OverlayContent.Tone.working.colorRole, .processing)
        XCTAssertEqual(OverlayContent.Tone.info.colorRole, .processing)
        XCTAssertEqual(OverlayContent.Tone.warning.colorRole, .attention)
        XCTAssertEqual(OverlayContent.Tone.failure.colorRole, .attention)
    }

    /// Failure and warning share the triangle: both mean "look here, your
    /// work is preserved". The old xmark read as a destructive dead end.
    func testScenario015() {
        XCTAssertEqual(OverlayContent.Tone.failure.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(OverlayContent.Tone.warning.iconName, "exclamationmark.triangle.fill")
        XCTAssertEqual(OverlayContent.Tone.info.iconName, "info.circle.fill")
        XCTAssertEqual(OverlayContent.Tone.recording.iconName, "mic.fill")
        XCTAssertEqual(OverlayContent.Tone.working.iconName, "waveform")
        XCTAssertEqual(OverlayContent.Tone.idle.iconName, "checkmark.circle.fill")
    }
}

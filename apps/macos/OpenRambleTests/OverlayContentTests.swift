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
        isWaitingForEngine: Bool = false,
        hasLingered: Bool = false
    ) -> OverlayContent {
        OverlayContent.make(
            state: state,
            notice: notice,
            elapsed: elapsed,
            isWaitingForEngine: isWaitingForEngine,
            hasLingered: hasLingered
        )
    }

    // MARK: - Waiting is not working

    /// A take that has to wait for the model spends that wait in the
    /// transcribing state. Calling it transcription is a lie that grows with
    /// the wait, and the wait can reach the preparation deadline.
    func testWaitingForTheModelIsNotCalledTranscribing() {
        let waiting = content(.transcribing, isWaitingForEngine: true)
        XCTAssertEqual(waiting.title, "Waking the model…", "said at once, not after the delay")
        XCTAssertNotEqual(waiting.title, content(.transcribing, hasLingered: true).title)
        // Still work, still not a failure: the words are safe either way.
        XCTAssertEqual(waiting.mark, .working)
        XCTAssertNil(waiting.tone)
        XCTAssertTrue(
            waiting.accessibilityLabel.contains("Your words are waiting, not lost."),
            "VoiceOver hears that the words are safe"
        )
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
                content(state, isWaitingForEngine: true),
                content(state),
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

    /// The take's first half second has no words at all; past it, the two
    /// waits that can run long say what they are.
    func testScenario001() {
        XCTAssertNil(content(.preparing).title)
        XCTAssertNil(content(.listening).title)
        XCTAssertNil(content(.transcribing).title)
        XCTAssertEqual(content(.preparing, hasLingered: true).title, "Turning on the microphone…")
        XCTAssertNil(content(.listening, hasLingered: true).title, "the waveform is the title")
        XCTAssertEqual(content(.transcribing, hasLingered: true).title, "Transcribing…")
        XCTAssertNil(content(.idle).title)
        XCTAssertNil(content(.inserting).title)
    }

    /// Gray, then red, then blue — the mark is the only thing that moves.
    func testScenario002() {
        XCTAssertEqual(content(.preparing).mark, .starting)
        XCTAssertEqual(content(.listening).mark, .recording)
        XCTAssertEqual(content(.transcribing).mark, .working)
        XCTAssertNil(OverlayContent.Mark.starting.colorRole)
        XCTAssertEqual(OverlayContent.Mark.recording.colorRole, .recording)
        XCTAssertEqual(OverlayContent.Mark.working.colorRole, .processing)
        for state in [DictationState.preparing, .listening, .transcribing] {
            XCTAssertEqual(content(state).panelWidth, 244, "\(state) shares the recording layout")
            XCTAssertNil(content(state).tone)
        }
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
    /// The microphone opening is a tone: words said now would be dictated.
    func testScenario007() {
        XCTAssertEqual(content(.listening).voice, .cue)
    }

    func testScenario008() {
        XCTAssertNil(content(.transcribing).voice, "a quick take says nothing after its tone")
        XCTAssertEqual(
            content(.transcribing, hasLingered: true).voice,
            .speech("Transcribing…", urgent: false)
        )
        XCTAssertNil(content(.inserting).voice)
        XCTAssertNil(content(.preparing).voice, "said while the microphone opens, so never said")
    }

    /// The panel is removed from the screen at rest - there is nothing to declare there.
    func testScenario009() {
        XCTAssertNil(content(.idle).voice)
    }

    // MARK: - Messages

    func testScenario010() {
        let notice = DictationNotice(kind: .warning, message: "Text not inserted: secure input is active.")
        let content = content(.listening, notice: notice, elapsed: 9)

        XCTAssertEqual(content.title, notice.message)
        XCTAssertNil(content.mark)
        XCTAssertEqual(content.panelWidth, 320)
        XCTAssertEqual(content.tone, .warning)
        XCTAssertEqual(content.voice, .speech(notice.message, urgent: true))
    }

    func testScenario011() {
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .info, message: "and")).tone, .info)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .warning, message: "p")).tone, .warning)
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .failure, message: "about")).tone, .failure)
    }

    /// A crash interrupts what VoiceOver is currently reading, but a simple notification does not.
    func testScenario012() {
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .info, message: "and")).voice, .speech("and", urgent: false))
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .warning, message: "p")).voice, .speech("p", urgent: true))
        XCTAssertEqual(content(.idle, notice: DictationNotice(kind: .failure, message: "about")).voice, .speech("about", urgent: true))
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

    /// One meaning per color, pinned: blue for info, orange for anything that
    /// needs the person. Failure wears orange, not red — every failure here
    /// keeps the work recoverable, and red is the live microphone alone.
    func testScenario014() {
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
    }
}

import XCTest
@testable import DictationCore

final class MeetingTranscriptFormatterTests: XCTestCase {
    private let utterances = [
        MeetingUtterance(channel: .system, start: 4.9, end: 6, text: "Yep, loud and clear."),
        MeetingUtterance(channel: .microphone, start: 0.5, end: 4.2, text: "Right, can everyone hear me?"),
        MeetingUtterance(channel: .microphone, start: 3_725, end: 3_730, text: "", isFailed: true),
    ]

    func testPlainTextIsChronologicalWithSpeakerAndTimestamp() {
        XCTAssertEqual(
            MeetingTranscriptFormatter.plainText(utterances),
            """
            You · 00:00:00
            Right, can everyone hear me?

            Others · 00:00:04
            Yep, loud and clear.

            You · 01:02:05
            [couldn't transcribe this part]
            """
        )
    }

    func testMarkdownCarriesTheTitleTheProvenanceAndAnyNote() {
        let markdown = MeetingTranscriptFormatter.markdown(
            Array(utterances.prefix(2)),
            title: "Weekly sync",
            subtitle: "3 September 2026 · 47 min · Meeting (You and Others)",
            note: "Only the microphone was recorded."
        )
        XCTAssertEqual(
            markdown,
            """
            # Weekly sync

            3 September 2026 · 47 min · Meeting (You and Others)

            > Recorded with OpenRamble. This transcript was produced on this Mac.

            > Only the microphone was recorded.

            **You** · 00:00:00
            Right, can everyone hear me?

            **Others** · 00:00:04
            Yep, loud and clear.

            """
        )
    }

    /// An imported file's sound is on the microphone's channel, and it is
    /// not "You": nobody knows who speaks in a file. It leaves the app with
    /// its times and no names.
    func testAFileWhoseSpeakerIsUnknownIsWrittenWithoutNames() {
        let lecture = [
            MeetingUtterance(channel: .microphone, start: 0.5, end: 4.2, text: "Good morning."),
            MeetingUtterance(channel: .microphone, start: 65, end: 70, text: "Let's begin."),
        ]
        XCTAssertEqual(
            MeetingTranscriptFormatter.plainText(lecture, speakers: false),
            """
            00:00:00
            Good morning.

            00:01:05
            Let's begin.
            """
        )
        let markdown = MeetingTranscriptFormatter.markdown(lecture, title: "Lecture", subtitle: "Imported file", speakers: false)
        XCTAssertTrue(markdown.contains("**00:01:05**\nLet's begin."), markdown)
        XCTAssertFalse(markdown.contains("You"), markdown)
    }

    func testNamesCanBeRelabelledWithoutTouchingTheTranscript() {
        let text = MeetingTranscriptFormatter.plainText(
            [utterances[0]],
            names: [.system: "Zoom call"]
        )
        XCTAssertTrue(text.hasPrefix("Zoom call · "))
    }

    func testTimestampsAlwaysHaveThreeFields() {
        XCTAssertEqual(MeetingTranscriptFormatter.timestamp(0), "00:00:00")
        XCTAssertEqual(MeetingTranscriptFormatter.timestamp(59.9), "00:00:59")
        XCTAssertEqual(MeetingTranscriptFormatter.timestamp(3_725), "01:02:05")
    }
}

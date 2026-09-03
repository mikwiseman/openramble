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

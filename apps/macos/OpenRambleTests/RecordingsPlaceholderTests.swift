import DictationCore
import XCTest

final class RecordingsPlaceholderTests: XCTestCase {
    func testAnOrdinaryEndingNeedsNoNote() {
        XCTAssertNil(RecordingsPlaceholder.endNote(for: nil))
        XCTAssertNil(RecordingsPlaceholder.endNote(for: .stoppedByUser))
    }

    func testEveryOtherEndingSaysWhatWasKept() throws {
        for reason in [MeetingEndReason.diskFull, .writeFailed, .crashRecovered] {
            let note = try XCTUnwrap(RecordingsPlaceholder.endNote(for: reason))
            XCTAssertTrue(note.contains("kept"), "\(reason): \(note)")
        }
        XCTAssertNotNil(RecordingsPlaceholder.endNote(for: .applicationQuit))
    }

    func testPlaceholdersNeverUseRedLanguageOrBlame() {
        for placeholder in [
            RecordingsPlaceholder.emptyLibrary, .nothingSelected, .notTranscribed, .audioMissing, .recovered,
        ] {
            XCTAssertFalse(placeholder.title.isEmpty)
            XCTAssertFalse(placeholder.detail.isEmpty)
            XCTAssertFalse(placeholder.detail.lowercased().contains("error"))
        }
    }

    func testTheDefaultTitleIsTheDate() {
        let date = Date(timeIntervalSince1970: 1_756_900_000)
        XCTAssertEqual(RecordingsPlaceholder.defaultTitle(for: date), date.formatted(date: .abbreviated, time: .shortened))
    }
}

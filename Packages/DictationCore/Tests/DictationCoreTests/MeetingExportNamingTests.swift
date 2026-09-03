import XCTest
@testable import DictationCore

/// A title becomes a file name without becoming a path.
final class MeetingExportNamingTests: XCTestCase {
    func testAnOrdinaryTitleIsKept() {
        XCTAssertEqual(MeetingExportNaming.fileName("Standup with Anna", fallback: "3 September"), "Standup with Anna")
    }

    func testSeparatorsCannotSurvive() {
        XCTAssertEqual(
            MeetingExportNaming.fileName("Q3/Q4 plan: rollout", fallback: "3 September"),
            "Q3 Q4 plan  rollout"
        )
    }

    func testNewlinesBecomeSpaces() {
        XCTAssertEqual(MeetingExportNaming.fileName("Call\nwith Sam", fallback: "3 September"), "Call with Sam")
    }

    /// A name starting with a dot is hidden in the Finder — never that.
    func testALeadingDotIsRemoved() {
        XCTAssertEqual(MeetingExportNaming.fileName("..notes", fallback: "3 September"), "notes")
    }

    func testATitleWithNothingLeftFallsBackToTheDate() {
        for title in ["", "   ", "///", ".", "\n"] {
            XCTAssertEqual(MeetingExportNaming.fileName(title, fallback: "3 September"), "3 September", "\(title)")
        }
    }

    func testALongTitleIsCutOnACharacterBoundary() {
        let name = MeetingExportNaming.fileName(String(repeating: "🙂", count: 200), fallback: "x")
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertEqual(name.count, 50, "cut between characters, never inside one")
    }
}

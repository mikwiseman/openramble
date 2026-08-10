import XCTest
@testable import DictationCore

/// Selecting the edit of the inserted fragment from the contents of another field.
///
/// We know three things: what the field was like immediately after insertion, where our
/// fragment and what the field became later. Common prefix and suffix are cut off;
/// if the changed middle lies inside our fragment - this is an edit
/// dictation, and it can be taught.
final class InsertedEditExtractorTests: XCTestCase {
    func testScenario001() {
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}! \u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}. \u{041F}\u{043E}\u{043A}\u{0430}.",
            current: "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}! \u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}. \u{041F}\u{043E}\u{043A}\u{0430}.",
            inserted: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}."
        )

        XCTAssertEqual(edit?.original, "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}.")
        XCTAssertEqual(edit?.edited, "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}.")
    }

    func testScenario002() {
        // The person edited HIS text before our insertion - none of our business.
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{041F}\u{0440}\u{0435}\u{0432}\u{0435}\u{0442}! \u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}. \u{041F}\u{043E}\u{043A}\u{0430}.",
            current: "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}! \u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}. \u{041F}\u{043E}\u{043A}\u{0430}.",
            inserted: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}."
        )

        XCTAssertNil(edit)
    }

    func testScenario003() {
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}.",
            current: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}.",
            inserted: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}."
        )

        XCTAssertNil(edit)
    }

    func testScenario004() {
        // The field has been cleared or rewritten entirely - there is nothing to learn from.
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{0421}\u{043E}\u{0432}\u{0441}\u{0435}\u{043C} \u{0434}\u{0440}\u{0443}\u{0433}\u{043E}\u{0439} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}.",
            current: "\u{0415}\u{0449}\u{0451} \u{0431}\u{043E}\u{043B}\u{0435}\u{0435} \u{0434}\u{0440}\u{0443}\u{0433}\u{043E}\u{0439}.",
            inserted: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}."
        )

        XCTAssertNil(edit)
    }

    func testScenario005() {
        // The person continued typing after inserting - the fragment did not change.
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}.",
            current: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}. \u{0418} \u{0435}\u{0449}\u{0451} \u{043A}\u{043E}\u{0435}-\u{0447}\u{0442}\u{043E}.",
            inserted: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}."
        )

        XCTAssertNil(edit)
    }

    func testScenario006() {
        // Corrected the first word of the fragment: the common prefix ends in a foreign one
        // text, but the changed middle is still inside the insert.
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{0417}\u{0430}\u{043C}\u{0435}\u{0442}\u{043A}\u{0430}: \u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431} \u{043B}\u{0435}\u{0436}\u{0438}\u{0442}.",
            current: "\u{0417}\u{0430}\u{043C}\u{0435}\u{0442}\u{043A}\u{0430}: GitHub \u{043B}\u{0435}\u{0436}\u{0438}\u{0442}.",
            inserted: "\u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431} \u{043B}\u{0435}\u{0436}\u{0438}\u{0442}."
        )

        XCTAssertEqual(edit?.original, "\u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431} \u{043B}\u{0435}\u{0436}\u{0438}\u{0442}.")
        XCTAssertEqual(edit?.edited, "GitHub \u{043B}\u{0435}\u{0436}\u{0438}\u{0442}.")
    }

    func testScenario007() {
        let edit = InsertedEditExtractor.extract(
            baseline: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}.",
            current: "",
            inserted: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}."
        )

        XCTAssertNil(edit)
    }
}

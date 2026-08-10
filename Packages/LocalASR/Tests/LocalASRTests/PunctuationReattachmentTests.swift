import XCTest
@testable import LocalASR

/// Return punctuation after the dictionary resorer - without model and without sound.
final class PunctuationReattachmentTests: XCTestCase {
    private func restore(_ original: String, _ rescored: String) -> String {
        PunctuationReattachment.restore(original: original, rescored: rescored)
    }

    private func markCount(_ text: String) -> Int {
        text.filter { ".,!?:;…«»\"'()—–".contains($0) }.count
    }

    private func cores(_ text: String) -> [String] {
        PunctuationReattachment.fields(text).map(\.core)
    }

    // MARK: - Main

    func testEqualStringsAreReturnedUnchanged() {
        XCTAssertEqual(restore("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}.", "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}."), "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043C}\u{0438}\u{0440}.")
    }

    /// The same defect: replacing a word took the comma with it.
    func testCommaComesBackToTheReplacedWord() {
        XCTAssertEqual(
            restore(
                "\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{043B}\u{0435}\u{0436}\u{0430}\u{0442} \u{0432} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}\u{0435}, \u{0430} \u{043A}\u{044D}\u{0448} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}.",
                "\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{043B}\u{0435}\u{0436}\u{0430}\u{0442} \u{0432} Postgres \u{0430} \u{043A}\u{044D}\u{0448} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}."
            ),
            "\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{043B}\u{0435}\u{0436}\u{0430}\u{0442} \u{0432} Postgres, \u{0430} \u{043A}\u{044D}\u{0448} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}."
        )
    }

    func testSentenceFinalPeriodIsNotLost() {
        XCTAssertEqual(
            restore("\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}.", "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres"),
            "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres."
        )
    }

    /// Your resorer sign is more important - otherwise it would turn out to be “Postgres,,”.
    func testMarkIsNeverDoubled() {
        XCTAssertEqual(
            restore("\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C}", "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C}"),
            "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C}"
        )
    }

    /// Gluing together several words into a term: the sign gives only the last of them,
    /// and punctuation does not fit inside the term.
    func testMergingTwoWordsKeepsOnlyTheTrailingMark() {
        let result = restore("\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C}", "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} pull-request \u{043F}\u{043E}\u{0442}\u{043E}\u{043C}")
        XCTAssertEqual(result, "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} pull-request, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C}")
        XCTAssertFalse(result.contains("pull,"), "\u{0432}\u{043D}\u{0443}\u{0442}\u{0440}\u{044C} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\u{0430} \u{0437}\u{043D}\u{0430}\u{043A} \u{043D}\u{0435} \u{0437}\u{0430}\u{0435}\u{0437}\u{0436}\u{0430}\u{0435}\u{0442}")
    }

    /// Breaking a word into several: the sign sits at the end, not inside.
    func testSplittingAWordDoesNotScatterMarksInside() {
        let result = restore("\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}.", "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Post gres")
        XCTAssertFalse(result.contains("Post. gres"))
        XCTAssertTrue(result.hasSuffix("."), "\u{0442}\u{043E}\u{0447}\u{043A}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{0432} \u{043A}\u{043E}\u{043D}\u{0446}\u{0435}")
    }

    // MARK: - What you can’t touch

    /// Signs inside the word are not removed - they are removed only from the edges.
    func testPunctuationInsideAWordIsNeverTouched() {
        let samples = [
            "\u{0427}\u{0438}\u{0441}\u{043B}\u{043E} 3.14 \u{0442}\u{043E}\u{0447}\u{043D}\u{043E}\u{0435}",
            "\u{0418} \u{0442}.\u{0434}. \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}",
            "\u{0421}\u{0441}\u{044B}\u{043B}\u{043A}\u{0430} https://wai.computer/openramble/ here",
            "I don't know",
            "\u{041F}\u{0438}\u{0448}\u{0435}\u{043C} \u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}",
        ]
        for text in samples {
            XCTAssertEqual(restore(text, text), text, "\u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}: \(text)")
        }
    }

    /// The texts have spread too much - we are returning them as is.
    ///
    /// This is not quiet degradation, but today’s behavior: inventing punctuation
    /// worse than losing her.
    func testTooDifferentTextsAreLeftAlone() {
        let rescored = "\u{0441}\u{043E}\u{0432}\u{0435}\u{0440}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E} \u{0434}\u{0440}\u{0443}\u{0433}\u{043E}\u{0439} \u{043D}\u{0430}\u{0431}\u{043E}\u{0440} \u{0441}\u{043B}\u{043E}\u{0432} \u{0431}\u{0435}\u{0437} \u{0435}\u{0434}\u{0438}\u{043D}\u{043E}\u{0433}\u{043E} \u{0441}\u{043E}\u{0432}\u{043F}\u{0430}\u{0434}\u{0435}\u{043D}\u{0438}\u{044F}"
        XCTAssertEqual(restore("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0425}\u{043E}\u{0440}\u{043E}\u{0448}\u{043E}.", rescored), rescored)
    }

    func testNewlinesAndSpacingSurvive() {
        let original = "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430},\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}."
        let rescored = "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"
        let result = restore(original, rescored)
        XCTAssertTrue(result.contains("\n"), "\u{043F}\u{0435}\u{0440}\u{0435}\u{0432}\u{043E}\u{0434} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438} \u{043D}\u{0430} \u{043C}\u{0435}\u{0441}\u{0442}\u{0435}")
        XCTAssertEqual(result, "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430},\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}.")
    }

    func testEmptyStrings() {
        XCTAssertEqual(restore("", ""), "")
        XCTAssertEqual(restore("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}.", ""), "")
        XCTAssertEqual(restore("", "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"), "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}")
    }

    // MARK: - Invariants

    private let corpus: [(String, String)] = [
        ("\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{043B}\u{0435}\u{0436}\u{0430}\u{0442} \u{0432} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}\u{0435}, \u{0430} \u{043A}\u{044D}\u{0448} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}.", "\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{043B}\u{0435}\u{0436}\u{0430}\u{0442} \u{0432} Postgres \u{0430} \u{043A}\u{044D}\u{0448} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}."),
        ("\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}.", "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres"),
        ("\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}!", "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} pull-request \u{043F}\u{043E}\u{0442}\u{043E}\u{043C} deploy"),
        ("\u{0427}\u{0438}\u{0441}\u{043B}\u{043E} 3.14, \u{0438} \u{0442}.\u{0434}.", "\u{0427}\u{0438}\u{0441}\u{043B}\u{043E} 3.14 \u{0438} \u{0442}.\u{0434}."),
        ("\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430},\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}.", "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"),
        ("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}?", "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}"),
    ]

    /// Invariant 3, the most important: words never change.
    ///
    /// Otherwise, returning punctuation would cancel the dictionary edit - just for the sake of
    /// which is why the resorer works.
    func testWordsAreNeverChanged() {
        for (original, rescored) in corpus {
            XCTAssertEqual(
                cores(restore(original, rescored)),
                cores(rescored),
                "\u{0441}\u{043B}\u{043E}\u{0432}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}\u{043C}\u{0438} \u{0440}\u{0435}\u{0441}\u{043E}\u{0440}\u{0435}\u{0440}\u{0430}"
            )
        }
    }

    /// Invariant 1: the sign given by the resorer is not removed.
    func testMarksProducedByTheRescorerAreNeverRemoved() {
        for (original, rescored) in corpus {
            let result = restore(original, rescored)
            XCTAssertGreaterThanOrEqual(
                markCount(result), markCount(rescored),
                "\u{043D}\u{0435}\u{043B}\u{044C}\u{0437}\u{044F} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{0442}\u{044C} \u{0442}\u{043E}, \u{0447}\u{0442}\u{043E} \u{0440}\u{0435}\u{0441}\u{043E}\u{0440}\u{0435}\u{0440} \u{0443}\u{0436}\u{0435} \u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B}"
            )
        }
    }

    /// Invariant 2: no new signs appear.
    func testNoMarkIsEverInvented() {
        for (original, rescored) in corpus {
            let result = restore(original, rescored)
            XCTAssertLessThanOrEqual(
                markCount(result), max(markCount(original), markCount(rescored)),
                "\u{0437}\u{043D}\u{0430}\u{043A}\u{0438} \u{0431}\u{0435}\u{0440}\u{0443}\u{0442}\u{0441}\u{044F} \u{0442}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0438}\u{0437} \u{043E}\u{0431}\u{044A}\u{0435}\u{0434}\u{0438}\u{043D}\u{0435}\u{043D}\u{0438}\u{044F} \u{0441}\u{0442}\u{043E}\u{0440}\u{043E}\u{043D}"
            )
        }
    }

    /// What is it all for: the marks on the body stop disappearing.
    func testMarkCountRecoversTowardTheOriginal() {
        for (original, rescored) in corpus where markCount(original) > markCount(rescored) {
            let result = restore(original, rescored)
            XCTAssertGreaterThan(
                markCount(result), markCount(rescored),
                "\u{0432}\u{043E}\u{0441}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043B}\u{0435}\u{043D}\u{0438}\u{0435} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{043E} \u{0447}\u{0442}\u{043E}-\u{0442}\u{043E} \u{0432}\u{0435}\u{0440}\u{043D}\u{0443}\u{0442}\u{044C}: \(original)"
            )
        }
    }
}

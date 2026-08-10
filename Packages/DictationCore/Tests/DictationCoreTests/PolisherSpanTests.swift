import XCTest
@testable import DictationCore

/// Polisher and protected spans.
///
/// This is where the fix for the defect lives, for which the span model appeared.
final class PolisherSpanTests: XCTestCase {
    /// The same defect: the space after the dot before the capital letter was causing names to fall apart.
    func testDoesNotSplitADottedIdentifier() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} TextPipeline.Output"),
            "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} TextPipeline.Output"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0437}\u{043E}\u{0432}\u{0438} AppState.shared"),
            "\u{0417}\u{043E}\u{0432}\u{0438} AppState.shared"
        )
        XCTAssertEqual(TranscriptPolisher.polish("\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} Foo.Bar"), "\u{041F}\u{0440}\u{0430}\u{0432}\u{044C} Foo.Bar")
    }

    /// The actual supply boundary is still being broken up.
    ///
    /// The rule about identifiers is only about ASCII, so the Russian text is
    /// not relevant at all.
    func testStillSplitsARealSentenceBoundary() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}.\u{0414}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435} \u{043F}\u{043E}\u{0435}\u{0434}\u{0435}\u{043C}"),
            "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}. \u{0414}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435} \u{043F}\u{043E}\u{0435}\u{0434}\u{0435}\u{043C}"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}.\u{041F}\u{043E}\u{0439}\u{0434}\u{0451}\u{043C} \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"),
            "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}. \u{041F}\u{043E}\u{0439}\u{0434}\u{0451}\u{043C} \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"
        )
    }

    /// The capital guard remained in place: numbers, versions, domains and
    /// contractions do not become spans and stick to it.
    func testConservativeDotAndColonRulesAreUnchangedThroughSpans() {
        let untouched = [
            "Testing numbers like 3.14 and dates like January 5.",
            "\u{0412}\u{0435}\u{0440}\u{0441}\u{0438}\u{044F} 2.0.1 \u{0432}\u{044B}\u{0448}\u{043B}\u{0430}",
            "\u{0421}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} \u{043D}\u{0430} wai.computer",
            "\u{042D}\u{0442}\u{043E} \u{0442}.\u{0434}. \u{0438} \u{0442}.\u{043F}.",
            "\u{0412}\u{0441}\u{0442}\u{0440}\u{0435}\u{0447}\u{0430} \u{0432} 12:30",
        ]
        for input in untouched {
            XCTAssertEqual(TranscriptPolisher.polish(input), input, "\u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}: \(input)")
        }
    }

    func testPolisherNeverEditsInsideBackticks() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `swift  test` \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"),
            "\u{0417}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `swift  test` \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"
        )
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} `a , b` \u{0432}\u{043E}\u{0442} \u{0442}\u{0430}\u{043A}"),
            "\u{041D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} `a , b` \u{0432}\u{043E}\u{0442} \u{0442}\u{0430}\u{043A}"
        )
    }

    func testPathsAndFlagsSurvivePolishing() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts \u{0438} \u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{044C} --dry-run"),
            "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts \u{0438} \u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{044C} --dry-run"
        )
    }

    /// The first word of the identifier is not capitalized: it is a name, not a beginning
    /// offers. `OnTextInserted` is a different name.
    func testIdentifierAtTheStartKeepsItsCase() {
        XCTAssertEqual(
            TranscriptPolisher.polish("onTextInserted \u{0441}\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{043B}"),
            "onTextInserted \u{0441}\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{043B}"
        )
        XCTAssertEqual(TranscriptPolisher.polish("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"), "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", "\u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{043E}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E} — \u{043A}\u{0430}\u{043A} \u{0440}\u{0430}\u{043D}\u{044C}\u{0448}\u{0435}")
    }

    /// Collapse of spaces does not go inside the span, but it removes the extra space nearby.
    func testWhitespaceCollapseStopsAtTheSpanBoundary() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0434}\u{043E}   `a  b`   \u{043F}\u{043E}\u{0441}\u{043B}\u{0435}"),
            "\u{0414}\u{043E} `a  b` \u{043F}\u{043E}\u{0441}\u{043B}\u{0435}"
        )
    }
}

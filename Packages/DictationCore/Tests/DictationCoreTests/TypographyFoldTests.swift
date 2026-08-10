import XCTest
@testable import DictationCore

/// Typography convolution: bring the writing to what a person would type by hand.
///
/// The stage is narrow by design. She repairs symbols that can be in dictation
/// only traces of someone else's edits or invisible garbage, and does not touch anything that
/// makes sense.
final class TypographyFoldTests: XCTestCase {
    func testTableHasExactlyTwelveEntries() {
        XCTAssertEqual(TypographyFold.table.count, 12)
    }

    /// Invisible characters: part becomes a regular space, part disappears.
    ///
    /// They come from `written` in the dictionary - the person inserts the term by copy-paste
    /// along with a non-breaking space or BOM, but they are not visible in the settings at all.
    func testInvisibleCharactersDisappear() {
        XCTAssertEqual(TypographyFold.fold("\u{0434}\u{0432}\u{0430}\u{00A0}\u{0441}\u{043B}\u{043E}\u{0432}\u{0430}"), "\u{0434}\u{0432}\u{0430} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}")
        XCTAssertEqual(TypographyFold.fold("\u{0434}\u{0432}\u{0430}\u{202F}\u{0441}\u{043B}\u{043E}\u{0432}\u{0430}"), "\u{0434}\u{0432}\u{0430} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}")
        XCTAssertEqual(TypographyFold.fold("\u{0434}\u{0432}\u{0430}\u{2009}\u{0441}\u{043B}\u{043E}\u{0432}\u{0430}"), "\u{0434}\u{0432}\u{0430} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}")
        XCTAssertEqual(TypographyFold.fold("\u{0441}\u{043B}\u{043E}\u{200B}\u{0432}\u{043E}"), "\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}")
        XCTAssertEqual(TypographyFold.fold("\u{FEFF}\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}"), "\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}")
        XCTAssertEqual(TypographyFold.fold("\u{0441}\u{043B}\u{043E}\u{00AD}\u{0432}\u{043E}"), "\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}")
    }

    func testCurlyQuotesBecomeStraight() {
        XCTAssertEqual(TypographyFold.fold("\u{2018}\u{043E}\u{0434}\u{0438}\u{043D}\u{0430}\u{0440}\u{043D}\u{044B}\u{0435}\u{2019}"), "'\u{043E}\u{0434}\u{0438}\u{043D}\u{0430}\u{0440}\u{043D}\u{044B}\u{0435}'")
        XCTAssertEqual(TypographyFold.fold("\u{201C}\u{0434}\u{0432}\u{043E}\u{0439}\u{043D}\u{044B}\u{0435}\u{201D}"), "\"\u{0434}\u{0432}\u{043E}\u{0439}\u{043D}\u{044B}\u{0435}\"")
    }

    /// The minus is not a hyphen, and this breaks flag recognition.
    func testMinusSignBecomesAHyphenSoFlagsStayFlags() {
        let folded = TypographyFold.fold("\u{043A}\u{043B}\u{044E}\u{0447} \u{2212}x \u{043F}\u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{044C}")
        XCTAssertEqual(folded, "\u{043A}\u{043B}\u{044E}\u{0447} -x \u{043F}\u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{044C}")
        XCTAssertEqual(ProtectedSpanDetector.detect(in: folded).map(\.kind), [.flag])
    }

    func testHorizontalBarBecomesEmDash() {
        XCTAssertEqual(TypographyFold.fold("\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430} \u{2015} \u{0441}\u{0442}\u{043E}\u{043B}\u{0438}\u{0446}\u{0430}"), "\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430} — \u{0441}\u{0442}\u{043E}\u{043B}\u{0438}\u{0446}\u{0430}")
    }

    /// Christmas trees are correct Russian typography, not garbage. This is a person's text.
    ///
    /// The dash also has a meaning: it cannot be folded into a hyphen, otherwise “Moscow -
    /// capital" will turn into "Moscow is the capital", and at the same time pairs of hyphens will appear,
    /// which the span detector will take as a flag.
    func testGuillemetsAndDashesAreNeverFolded() {
        let text = "«\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430} — \u{0441}\u{0442}\u{043E}\u{043B}\u{0438}\u{0446}\u{0430}», \u{0430} \u{041F}\u{0438}\u{0442}\u{0435}\u{0440} – \u{043D}\u{0435}\u{0442}"
        XCTAssertEqual(TypographyFold.fold(text), text)
    }

    /// The polysher owns the ellipsis: it has `…` in both sets of characters,
    /// and convolution into three points would take it to the conservative point rule.
    func testEllipsisIsNeverFoldedBecauseThePolisherOwnsIt() {
        XCTAssertEqual(TypographyFold.fold("\u{041D}\u{0443}\u{2026} \u{043B}\u{0430}\u{0434}\u{043D}\u{043E}"), "\u{041D}\u{0443}\u{2026} \u{043B}\u{0430}\u{0434}\u{043D}\u{043E}")
    }

    func testOrdinaryTextIsUntouched() {
        let text = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0412}\u{0441}\u{0451} \u{0445}\u{043E}\u{0440}\u{043E}\u{0448}\u{043E}: 3.14 \u{0438} \u{0442}.\u{0434}."
        XCTAssertEqual(TypographyFold.fold(text), text)
    }

    func testEmptyText() {
        XCTAssertEqual(TypographyFold.fold(""), "")
    }

    // MARK: - Spans

    /// There is code inside the backticks: the quotation mark is significant and cannot be changed.
    func testFoldSkipsProtectedSpans() {
        let text = "\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} `let s = \u{201C}hi\u{201D}` \u{0438} \u{201C}\u{0446}\u{0438}\u{0442}\u{0430}\u{0442}\u{0443}\u{201D}"
        let spans = ProtectedSpanDetector.detect(in: text)
        let folded = TypographyFold.fold(text, protecting: spans)

        XCTAssertTrue(folded.contains("`let s = \u{201C}hi\u{201D}`"), "\u{043A}\u{043E}\u{0434} \u{043D}\u{0435} \u{0442}\u{0440}\u{043E}\u{043D}\u{0443}\u{0442}")
        XCTAssertTrue(folded.contains("\"\u{0446}\u{0438}\u{0442}\u{0430}\u{0442}\u{0443}\""), "\u{0430} \u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{044B}\u{0439} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0441}\u{0432}\u{0451}\u{0440}\u{043D}\u{0443}\u{0442}")
    }

    /// Without spans, the convolution goes through the entire text - this is the same path as before.
    func testEmptySpanSetFoldsEverything() {
        let text = "\u{201C}\u{0440}\u{0430}\u{0437}\u{201D} \u{0438} \u{201C}\u{0434}\u{0432}\u{0430}\u{201D}"
        XCTAssertEqual(TypographyFold.fold(text, protecting: []), TypographyFold.fold(text))
    }

    /// Convolution does not move the span boundaries: the length of the protected pieces is preserved.
    func testFoldKeepsSpansIntact() {
        let text = "\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} TextPipeline.Output\u{00A0}\u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"
        let spans = ProtectedSpanDetector.detect(in: text)
        let folded = TypographyFold.fold(text, protecting: spans)
        XCTAssertEqual(
            ProtectedSpanDetector.detect(in: folded).map(\.text),
            spans.map(\.text)
        )
    }
}

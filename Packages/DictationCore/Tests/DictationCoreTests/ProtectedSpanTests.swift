import XCTest
@testable import DictationCore

/// Protected spans: pieces of text that no one touches after the dictionary.
///
/// The rules are intentionally conservative. False span suppresses dictionary and polisher
/// silently - a person sees an uncorrected term and does not understand why. Missed
/// span looks worse, but can be repaired with a dictionary. Therefore, wherever the choice is not obvious,
/// “not span” is selected.
final class ProtectedSpanDetectorTests: XCTestCase {
    private func kinds(_ text: String) -> [ProtectedSpan.Kind] {
        ProtectedSpanDetector.detect(in: text).map(\.kind)
    }

    private func texts(_ text: String) -> [String] {
        ProtectedSpanDetector.detect(in: text).map(\.text)
    }

    // MARK: - Baktiki

    func testBacktickedFragmentIsOneSpanIncludingTheDelimiters() {
        XCTAssertEqual(texts("\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `swift test` \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"), ["`swift test`"])
        XCTAssertEqual(kinds("\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `swift test` \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"), [.backticks])
    }

    /// An unclosed backtick is a dictation, not a code.
    func testUnpairedBacktickIsNotASpan() {
        XCTAssertEqual(texts("\u{0442}\u{0443}\u{0442} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} `\u{0431}\u{044D}\u{043A}\u{0442}\u{0438}\u{043A} \u{0438} \u{0432}\u{0441}\u{0451}"), [])
    }

    /// Nothing is searched inside backticks: the code is already there, and it is completely protected.
    func testBacktickSpanSwallowsEverythingInside() {
        let spans = ProtectedSpanDetector.detect(in: "`TextPipeline.Output --flag /etc/hosts`")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.kind, .backticks)
    }

    /// A backtick behind a quotation mark or a bracket is still a backtick.
    ///
    /// The scan jumped straight to the end of the token, so a pair that did not
    /// open the token was never looked at at all: the polisher collapsed the
    /// spaces inside `"`a  b`"`, and phonetic matching fired inside the backticks.
    func testBacktickSpanIsFoundBehindAQuoteOrBracket() {
        XCTAssertEqual(texts("\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} \"`a  b`\" \u{0432}\u{043E}\u{0442} \u{0442}\u{0430}\u{043A}"), ["`a  b`"])
        XCTAssertEqual(texts("(`\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}`)"), ["`\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}`"])
        XCTAssertEqual(kinds("(`\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}`)"), [.backticks])
    }

    // MARK: - Paths

    func testAbsoluteAndHomePathsAreSpans() {
        XCTAssertEqual(texts("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts"), ["/etc/hosts"])
        XCTAssertEqual(texts("\u{043B}\u{0435}\u{0436}\u{0438}\u{0442} \u{0432} ~/Documents/Code"), ["~/Documents/Code"])
        XCTAssertEqual(kinds("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts"), [.path])
    }

    /// One slash between regular words is an “or”, not a path.
    ///
    /// “and/or” and “24/7” are found in live speech much more often than the path of the two
    /// bare segments, so either a second slash or a dot/hyphen is required
    /// inside the segment.
    func testRelativePathNeedsMoreThanASingleSlash() {
        XCTAssertEqual(texts("\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} src/main.swift"), ["src/main.swift"])
        XCTAssertEqual(texts("\u{043F}\u{0443}\u{0442}\u{044C} a/b/c \u{0442}\u{043E}\u{0436}\u{0435}"), ["a/b/c"])
        XCTAssertEqual(texts("\u{044D}\u{0442}\u{043E} \u{0438}/\u{0438}\u{043B}\u{0438} \u{0442}\u{043E}"), [])
        XCTAssertEqual(texts("\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{0435}\u{0442} 24/7"), [])
        XCTAssertEqual(texts("\u{0444}\u{043E}\u{0440}\u{043C}\u{0430}\u{0442} and/or"), [])
    }

    /// The period at the end of the phrase belongs to the phrase, not to the path.
    func testTrailingSentencePunctuationStaysOutsideThePath() {
        XCTAssertEqual(texts("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts."), ["/etc/hosts"])
        XCTAssertEqual(texts("\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} src/main.swift, \u{0442}\u{0430}\u{043C}"), ["src/main.swift"])
    }

    func testUrlIsOneSpanIncludingTheScheme() {
        XCTAssertEqual(
            texts("\u{0437}\u{0430}\u{0439}\u{0434}\u{0438} \u{043D}\u{0430} https://wai.computer/openramble/"),
            ["https://wai.computer/openramble/"]
        )
    }

    // MARK: - Flags

    func testLongAndShortFlagsAreSpans() {
        XCTAssertEqual(texts("\u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{044C} --dry-run"), ["--dry-run"])
        XCTAssertEqual(texts("\u{043A}\u{043B}\u{044E}\u{0447} -x \u{043F}\u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{044C}"), ["-x"])
        XCTAssertEqual(kinds("\u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{044C} --dry-run"), [.flag])
    }

    func testLongFlagCarriesItsValue() {
        XCTAssertEqual(texts("\u{043F}\u{0435}\u{0440}\u{0435}\u{0434}\u{0430}\u{0439} --out=build/app"), ["--out=build/app"])
    }

    /// A hyphen inside a word does not make a flag: there is a letter before it.
    ///
    /// The Russian dash-hyphen in “word - word” is especially important: there is a space next,
    /// and the rule does not apply to him.
    func testHyphenInsideAWordIsNotAFlag() {
        XCTAssertEqual(texts("\u{044D}\u{0442}\u{043E} well-known \u{0432}\u{0435}\u{0449}\u{044C}"), [])
        XCTAssertEqual(texts("\u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}"), [])
        XCTAssertEqual(texts("\u{043C}\u{0438}\u{043D}\u{0443}\u{0441} -5 \u{0433}\u{0440}\u{0430}\u{0434}\u{0443}\u{0441}\u{043E}\u{0432}"), [])
        XCTAssertEqual(texts("\u{041C}\u{043E}\u{0441}\u{043A}\u{0432}\u{0430} — \u{0441}\u{0442}\u{043E}\u{043B}\u{0438}\u{0446}\u{0430}"), [])
        XCTAssertEqual(texts("\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} -- \u{0438} \u{0432}\u{0441}\u{0451}"), [])
    }

    // MARK: - Identifiers

    /// CamelCase is a transition from lowercase to uppercase. An abbreviation is not one.
    func testCamelCaseIsASpanButAllCapsIsNot() {
        XCTAssertEqual(texts("\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} TextPipeline"), ["TextPipeline"])
        XCTAssertEqual(texts("\u{043A}\u{043E}\u{043B}\u{0431}\u{044D}\u{043A} onTextInserted"), ["onTextInserted"])
        XCTAssertEqual(texts("\u{043A}\u{043B}\u{0430}\u{0441}\u{0441} URLSession"), ["URLSession"])
        XCTAssertEqual(texts("\u{043E}\u{0442}\u{0434}\u{0430}\u{0439} API"), [])
        XCTAssertEqual(texts("\u{0444}\u{043E}\u{0440}\u{043C}\u{0430}\u{0442} JSON \u{0438} HTTP"), [])
    }

    /// A dot identifier needs a capitalization in at least one segment -
    /// otherwise the domains and versions would become spans and the dictionary would not touch them.
    func testDottedIdentifierNeedsAnUppercaseSegment() {
        XCTAssertEqual(texts("\u{0442}\u{0438}\u{043F} TextPipeline.Output"), ["TextPipeline.Output"])
        XCTAssertEqual(texts("\u{0437}\u{043E}\u{0432}\u{0438} AppState.shared"), ["AppState.shared"])
        XCTAssertEqual(texts("\u{0441}\u{0430}\u{0439}\u{0442} wai.computer"), [])
        XCTAssertEqual(texts("\u{0432}\u{0435}\u{0440}\u{0441}\u{0438}\u{044F} 2.0.1"), [])
        XCTAssertEqual(texts("\u{0438} \u{0442}.\u{0434}. \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"), [])
    }

    /// Known and accepted value of the rule: the glued English phrase looks like
    /// as an identifier and remains glued. Cyrillic alphabet is not affected - rule
    /// only about ASCII, so the polisher will still break “Done.Next”.
    func testGluedEnglishSentenceIsProtectedAndThatIsTheKnownCost() {
        XCTAssertEqual(texts("Done.Next"), ["Done.Next"])
        XCTAssertEqual(texts("\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}.\u{0414}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"), [])
    }

    // MARK: - Brackets and quotation marks

    /// Brackets and quotes around the token belong to the phrase, not to the token.
    ///
    /// Only the tail was cut off before, and the token was obliged to begin right
    /// after a space - so one leading character made the whole word invisible to
    /// the detector, and every later stage rewrote it: `«TextPipeline.Output»`
    /// came out as `«TextPipeline. Output»`. This is not an exotic case: « » is
    /// the standard Russian quotation mark, and the model emits it constantly.
    func testLeadingQuoteOrBracketDoesNotHideTheToken() {
        XCTAssertEqual(texts("\u{0442}\u{0438}\u{043F} «TextPipeline.Output» \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"), ["TextPipeline.Output"])
        XCTAssertEqual(texts("\u{0442}\u{0438}\u{043F} (TextPipeline.Output)"), ["TextPipeline.Output"])
        XCTAssertEqual(texts("\u{0437}\u{043E}\u{0432}\u{0438} [AppState.shared]"), ["AppState.shared"])
        XCTAssertEqual(texts("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} (/\u{043F}\u{0443}\u{0442}\u{044C}/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/\u{0444}\u{0430}\u{0439}\u{043B})"), ["/\u{043F}\u{0443}\u{0442}\u{044C}/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/\u{0444}\u{0430}\u{0439}\u{043B}"])
        XCTAssertEqual(kinds("\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} (/\u{043F}\u{0443}\u{0442}\u{044C}/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/\u{0444}\u{0430}\u{0439}\u{043B})"), [.path])
    }

    /// Cutting off the brackets has no right to turn ordinary speech into a span.
    ///
    /// A false span silently suppresses the dictionary and the polisher, and that
    /// is worse than a missed one: the person sees an uncorrected term and does
    /// not understand why.
    func testBracketsAroundOrdinarySpeechStillGiveNoSpans() {
        XCTAssertEqual(texts("\u{044D}\u{0442}\u{043E} (\u{0438}/\u{0438}\u{043B}\u{0438}) \u{0442}\u{043E}"), [])
        XCTAssertEqual(texts("«\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}?»"), [])
        XCTAssertEqual(texts("\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{0435}\u{0442} (24/7)"), [])
        XCTAssertEqual(texts("«\u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}»"), [])
        XCTAssertEqual(texts("\u{0441}\u{043C}\u{0435}\u{0448}\u{043D}\u{043E})))"), [])
        // Versions and domains in brackets remain the same as without them: they
        // are protected by the polisher's guard, and the dictionary has the right
        // to reach them.
        XCTAssertEqual(texts("\u{0432}\u{0435}\u{0440}\u{0441}\u{0438}\u{044F} (2.0.1)"), [])
        XCTAssertEqual(texts("\u{0441}\u{0430}\u{0439}\u{0442} «wai.computer»"), [])
        XCTAssertEqual(texts("\u{043E}\u{0442}\u{0434}\u{0430}\u{0439} «API»"), [])
    }

    // MARK: - General properties

    /// Detection is idempotent: the spans of the same text are the same.
    ///
    /// The entire contract rests on this - the stages recalculate the spans after each
    /// text edits, and if the detection were “floating”, the byte-to-byte gate would be false.
    func testDetectionIsIdempotent() {
        let text = "\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} `swift test` \u{0432} src/main.swift \u{0447}\u{0435}\u{0440}\u{0435}\u{0437} --dry-run \u{0434}\u{043B}\u{044F} TextPipeline.Output"
        let once = ProtectedSpanDetector.detect(in: text)
        let twice = ProtectedSpanDetector.detect(in: text)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.count, 4)
    }

    /// Span ranges actually point to their text.
    func testRangesPointAtTheirOwnText() {
        let text = "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts \u{0438} \u{043F}\u{0440}\u{0430}\u{0432}\u{044C} TextPipeline"
        let characters = Array(text)
        for span in ProtectedSpanDetector.detect(in: text) {
            XCTAssertEqual(String(characters[span.range]), span.text)
        }
    }

    func testSpansNeverOverlapAndComeInOrder() {
        let text = "`\u{043A}\u{043E}\u{0434}` \u{043F}\u{043E}\u{0442}\u{043E}\u{043C} /usr/local/bin \u{0437}\u{0430}\u{0442}\u{0435}\u{043C} --flag \u{0438} AppState.shared"
        let spans = ProtectedSpanDetector.detect(in: text)
        XCTAssertEqual(spans.count, 4)
        for (earlier, later) in zip(spans, spans.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.range.upperBound, later.range.lowerBound)
        }
    }

    func testOrdinaryRussianSpeechHasNoSpans() {
        XCTAssertEqual(texts("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{0445}\u{043E}\u{0440}\u{043E}\u{0448}\u{0430}\u{044F} \u{043F}\u{043E}\u{0433}\u{043E}\u{0434}\u{0430}."), [])
        XCTAssertEqual(texts("\u{041D}\u{0430}\u{0434}\u{043E} \u{043A}\u{0443}\u{043F}\u{0438}\u{0442}\u{044C} \u{043C}\u{043E}\u{043B}\u{043E}\u{043A}\u{0430} \u{0438} \u{0445}\u{043B}\u{0435}\u{0431}\u{0430}."), [])
    }

    func testEmptyText() {
        XCTAssertEqual(ProtectedSpanDetector.detect(in: ""), [])
    }
}

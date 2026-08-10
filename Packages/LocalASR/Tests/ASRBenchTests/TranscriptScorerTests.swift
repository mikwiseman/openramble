import XCTest
@testable import asr_bench

/// The scorer is the only thing on which all quality numbers rest. If he's lying,
/// conclusions also lie, and unnoticed: incorrect normalization turns the correct one
/// recognition into an error and vice versa.
final class TranscriptScorerTests: XCTestCase {
    private func words(_ text: String) -> [String] {
        TextNormalizer.normalize(text).words
    }

    // MARK: - Numerals

    func testFoldsRussianCardinalToDigits() {
        XCTAssertEqual(words("\u{0441}\u{0442}\u{043E} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C} \u{043C}\u{0435}\u{0433}\u{0430}\u{0431}\u{0430}\u{0439}\u{0442}"), ["128", "\u{043C}\u{0435}\u{0433}\u{0430}\u{0431}\u{0430}\u{0439}\u{0442}"])
        XCTAssertEqual(words("\u{0434}\u{0432}\u{0435}\u{0441}\u{0442}\u{0438} \u{043F}\u{044F}\u{0442}\u{044C}\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}"), ["250"])
        XCTAssertEqual(words("\u{0434}\u{0432}\u{0435} \u{0442}\u{044B}\u{0441}\u{044F}\u{0447}\u{0438} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}\u{0441}\u{0442}\u{0430} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}"), ["2400", "\u{0441}\u{0442}\u{0440}\u{043E}\u{043A}"])
        XCTAssertEqual(words("\u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044C}\u{0441}\u{043E}\u{0442} \u{0434}\u{0435}\u{0432}\u{044F}\u{043D}\u{043E}\u{0441}\u{0442}\u{043E} \u{0434}\u{0435}\u{0432}\u{044F}\u{0442}\u{044C} \u{0440}\u{0443}\u{0431}\u{043B}\u{0435}\u{0439}"), ["999", "\u{0440}\u{0443}\u{0431}\u{043B}\u{0435}\u{0439}"])
    }

    func testFoldsOrdinalAndCaseFormsToTheSameNumber() {
        // For this reason, the convolution goes into numbers, not into words: Russian changes
        // the numeral has both gender and case, but the number remains the same.
        for form in ["\u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{043E}\u{0435}", "\u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{043E}\u{0433}\u{043E}", "\u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{044C}", "\u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{0438} \u{043F}\u{044F}\u{0442}\u{0438}"] {
            XCTAssertEqual(words(form), ["25"], "\u{0424}\u{043E}\u{0440}\u{043C}\u{0430} «\(form)» \u{0441}\u{0432}\u{0435}\u{0440}\u{043D}\u{0443}\u{043B}\u{0430}\u{0441}\u{044C} \u{043D}\u{0435} \u{0432} 25")
        }
    }

    func testDigitsAndWordsCompareEqual() {
        let report = TranscriptScorer.score(
            reference: "\u{0444}\u{0430}\u{0439}\u{043B} \u{0432}\u{0435}\u{0441}\u{0438}\u{0442} \u{0441}\u{0442}\u{043E} \u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C} \u{043C}\u{0435}\u{0433}\u{0430}\u{0431}\u{0430}\u{0439}\u{0442}",
            hypothesis: "\u{0424}\u{0430}\u{0439}\u{043B} \u{0432}\u{0435}\u{0441}\u{0438}\u{0442} 128 \u{043C}\u{0435}\u{0433}\u{0430}\u{0431}\u{0430}\u{0439}\u{0442}."
        )

        XCTAssertEqual(report.words.errors, 0, "\u{0426}\u{0438}\u{0444}\u{0440}\u{044B} \u{0438} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{0441}\u{0440}\u{0430}\u{0432}\u{043D}\u{0438}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043A}\u{0430}\u{043A} \u{043E}\u{0434}\u{043D}\u{043E} \u{0438} \u{0442}\u{043E} \u{0436}\u{0435}")
    }

    func testOrdinalWithHyphenSuffixIsANumber() {
        // The model writes “10th thought” where it says “tenth thought”.
        XCTAssertEqual(words("10-\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}"), ["10", "\u{043C}\u{044B}\u{0441}\u{043B}\u{044C}"])
        XCTAssertEqual(words("\u{0434}\u{0435}\u{0441}\u{044F}\u{0442}\u{0430}\u{044F} \u{043C}\u{044B}\u{0441}\u{043B}\u{044C}"), ["10", "\u{043C}\u{044B}\u{0441}\u{043B}\u{044C}"])
    }

    func testTimeIsNotSummedIntoOneNumber() {
        // “fourteen thirty” is the time. Addition would give 44 and hide
        // any error in hours or minutes.
        XCTAssertEqual(words("\u{0432} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{043D}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{0442}\u{0440}\u{0438}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C}"), ["\u{0432}", "14", "30"])
        XCTAssertEqual(words("at nine forty five"), ["at", "9", "45"])
    }

    func testHalfBecomesFraction() {
        XCTAssertEqual(words("\u{0442}\u{0440}\u{0438} \u{0441} \u{043F}\u{043E}\u{043B}\u{043E}\u{0432}\u{0438}\u{043D}\u{043E}\u{0439} \u{0447}\u{0430}\u{0441}\u{0430}"), ["3.5", "\u{0447}\u{0430}\u{0441}\u{0430}"])
        XCTAssertEqual(words("one and a half hours"), ["1.5", "hours"])
    }

    func testDecimalSeparatorStaysInsideNumber() {
        XCTAssertEqual(words("\u{0432}\u{0435}\u{0440}\u{0441}\u{0438}\u{044F} 2.01"), ["\u{0432}\u{0435}\u{0440}\u{0441}\u{0438}\u{044F}", "2.01"])
        XCTAssertEqual(words("\u{0437}\u{0430}\u{043D}\u{044F}\u{043B} 3,5 \u{0447}\u{0430}\u{0441}\u{0430}"), ["\u{0437}\u{0430}\u{043D}\u{044F}\u{043B}", "3.5", "\u{0447}\u{0430}\u{0441}\u{0430}"])
    }

    func testPrepositionIsNotSwallowedByNumber() {
        // “s” is only useful in “and a half”. At “three in the morning” this is an excuse,
        // and the scorer has no right to lose it.
        XCTAssertEqual(words("\u{0442}\u{0440}\u{0438} \u{0441} \u{0443}\u{0442}\u{0440}\u{0430}"), ["3", "\u{0441}", "\u{0443}\u{0442}\u{0440}\u{0430}"])
    }

    func testEnglishHundredMultiplies() {
        XCTAssertEqual(words("three hundred and twenty one files"), ["321", "files"])
        XCTAssertEqual(words("two hundred milliseconds"), ["200", "milliseconds"])
    }

    func testNonNumbersAreLeftAlone() {
        // “hundred” and “table” differ in one letter - guessing by stem
        // would turn the furniture into a number.
        XCTAssertEqual(words("\u{0441}\u{0442}\u{043E}\u{043B} \u{0438} \u{0441}\u{0442}\u{043E}\u{0439}\u{043A}\u{0430}"), ["\u{0441}\u{0442}\u{043E}\u{043B}", "\u{0438}", "\u{0441}\u{0442}\u{043E}\u{0439}\u{043A}\u{0430}"])
        XCTAssertEqual(words("\u{043E}\u{0434}\u{0438}\u{043D}\u{043E}\u{0447}\u{0435}\u{0441}\u{0442}\u{0432}\u{043E}"), ["\u{043E}\u{0434}\u{0438}\u{043D}\u{043E}\u{0447}\u{0435}\u{0441}\u{0442}\u{0432}\u{043E}"])
    }

    // MARK: - Punctuation

    func testPunctuationIsNotSilentlyDropped() {
        let normalized = TextNormalizer.normalize("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0412}\u{0441}\u{0451} \u{0445}\u{043E}\u{0440}\u{043E}\u{0448}\u{043E}!")

        XCTAssertEqual(normalized.marks, [",", "?", "!"], "\u{0417}\u{043D}\u{0430}\u{043A}\u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{043F}\u{043E}\u{043F}\u{0430}\u{0434}\u{0430}\u{0442}\u{044C} \u{0432} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{044B}\u{0439} \u{043F}\u{043E}\u{0442}\u{043E}\u{043A}")
        XCTAssertFalse(normalized.words.contains(where: { $0.contains(",") }))
        XCTAssertTrue(normalized.tokens.contains(","), "\u{0417}\u{043D}\u{0430}\u{043A}\u{0438} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{0431}\u{044B}\u{0442}\u{044C} \u{0432}\u{0438}\u{0434}\u{043D}\u{044B} \u{0438} \u{0432} \u{043E}\u{0431}\u{0449}\u{0435}\u{043C} \u{043F}\u{043E}\u{0442}\u{043E}\u{043A}\u{0435} \u{0442}\u{043E}\u{043A}\u{0435}\u{043D}\u{043E}\u{0432}")
    }

    func testMissingPunctuationCostsNothingInWordsButShowsUpSeparately() {
        let report = TranscriptScorer.score(
            reference: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}?",
            hypothesis: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}"
        )

        XCTAssertEqual(report.words.errors, 0, "\u{0421}\u{043B}\u{043E}\u{0432}\u{0430} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{043D}\u{044B} \u{0432}\u{0435}\u{0440}\u{043D}\u{043E}")
        XCTAssertEqual(report.punctuation.deletions, 2, "\u{041F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{043D}\u{043D}\u{044B}\u{0435} \u{0437}\u{043D}\u{0430}\u{043A}\u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{043E}\u{0441}\u{0447}\u{0438}\u{0442}\u{0430}\u{043D}\u{044B}")
        XCTAssertGreaterThan(
            report.wordsWithPunctuation.rate,
            report.words.rate,
            "\u{0426}\u{0435}\u{043D}\u{0430} \u{043F}\u{0443}\u{043D}\u{043A}\u{0442}\u{0443}\u{0430}\u{0446}\u{0438}\u{0438} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{0432}\u{0438}\u{0434}\u{043D}\u{0430} \u{0432} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}\u{0439} \u{043C}\u{0435}\u{0442}\u{0440}\u{0438}\u{043A}\u{0435}"
        )
    }

    func testInnerHyphenAndApostropheStayInsideWord() {
        XCTAssertEqual(words("\u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}"), ["\u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}"])
        XCTAssertEqual(words("don't stop"), ["don't", "stop"])
        XCTAssertEqual(TextNormalizer.normalize("\u{0434}\u{0430} — \u{043D}\u{0435}\u{0442}").marks, ["—"])
    }

    func testPercentSignIsSeparatedButIsNotPunctuation() {
        let normalized = TextNormalizer.normalize("\u{0441}\u{043A}\u{0438}\u{0434}\u{043A}\u{0430} 75%")

        XCTAssertEqual(normalized.words, ["\u{0441}\u{043A}\u{0438}\u{0434}\u{043A}\u{0430}", "75"], "\u{0427}\u{0438}\u{0441}\u{043B}\u{043E} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0441}\u{043B}\u{0438}\u{043F}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0441} \u{0441}\u{0438}\u{043C}\u{0432}\u{043E}\u{043B}\u{043E}\u{043C}")
        XCTAssertTrue(normalized.marks.isEmpty, "\u{041F}\u{0440}\u{043E}\u{0446}\u{0435}\u{043D}\u{0442} — \u{043D}\u{0435} \u{0437}\u{043D}\u{0430}\u{043A} \u{043F}\u{0440}\u{0435}\u{043F}\u{0438}\u{043D}\u{0430}\u{043D}\u{0438}\u{044F}")
    }

    // MARK: - Counting errors

    func testCountsSubstitutionsDeletionsAndInsertions() {
        let report = TranscriptScorer.score(
            reference: "\u{0443}\u{0442}\u{0440}\u{043E} \u{0434}\u{0435}\u{043D}\u{044C} \u{0432}\u{0435}\u{0447}\u{0435}\u{0440} \u{043D}\u{043E}\u{0447}\u{044C}",
            hypothesis: "\u{0443}\u{0442}\u{0440}\u{043E} \u{0434}\u{0430}\u{043D}\u{044C} \u{0432}\u{0435}\u{0447}\u{0435}\u{0440} \u{043D}\u{043E}\u{0447}\u{044C} \u{0441}\u{043D}\u{043E}\u{0432}\u{0430}"
        )

        XCTAssertEqual(report.words.substitutions, 1)
        XCTAssertEqual(report.words.insertions, 1)
        XCTAssertEqual(report.words.deletions, 0)
        XCTAssertEqual(report.words.referenceLength, 4)
        XCTAssertEqual(report.words.rate, 0.5, accuracy: 0.0001)
    }

    func testDeletionIsReportedAsLostWord() {
        let report = TranscriptScorer.score(
            reference: "\u{043D}\u{0443}\u{0436}\u{043D}\u{043E} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{0438}\u{0442}\u{044C} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435}\u{0434}\u{043D}\u{044E}\u{044E} \u{0444}\u{0440}\u{0430}\u{0437}\u{0443}",
            hypothesis: "\u{043D}\u{0443}\u{0436}\u{043D}\u{043E} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{0438}\u{0442}\u{044C} \u{0444}\u{0440}\u{0430}\u{0437}\u{0443}"
        )

        XCTAssertEqual(report.words.deletions, 1)
        XCTAssertEqual(
            report.differences.map(\.description),
            ["Missing: \u{043F}\u{043E}\u{0441}\u{043B}\u{0435}\u{0434}\u{043D}\u{044E}\u{044E}"],
            "A missing word must be named explicitly"
        )
    }

    func testEmptyReferenceWithTextIsFullError() {
        // The silence from which the text was born is a hundred percent mistake,
        // not zero due to division by zero.
        let report = TranscriptScorer.score(reference: "", hypothesis: "\u{043E}\u{0442}\u{043A}\u{0443}\u{0434}\u{0430}-\u{0442}\u{043E} \u{0432}\u{0437}\u{044F}\u{043B}\u{0441}\u{044F} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}")

        XCTAssertEqual(report.words.rate, 1)
        XCTAssertEqual(report.characterErrorRate, 1)
    }

    func testSilenceMatchedBySilenceIsNotAnError() {
        let report = TranscriptScorer.score(reference: "", hypothesis: "")

        XCTAssertEqual(report.words.rate, 0)
        XCTAssertEqual(report.characterErrorRate, 0)
    }

    func testCaseAndYoAreNotErrors() {
        let report = TranscriptScorer.score(
            reference: "\u{0412}\u{0441}\u{0451} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}",
            hypothesis: "\u{0432}\u{0441}\u{0435} \u{0413}\u{041E}\u{0422}\u{041E}\u{0412}\u{041E}"
        )

        XCTAssertEqual(report.words.errors, 0)
    }

    func testCharacterErrorRateCountsLetters() {
        let report = TranscriptScorer.score(reference: "\u{043A}\u{043E}\u{0442}", hypothesis: "\u{043A}\u{043E}\u{0434}")

        XCTAssertEqual(report.words.rate, 1, "\u{041E}\u{0434}\u{043D}\u{043E} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E} \u{0438}\u{0437} \u{043E}\u{0434}\u{043D}\u{043E}\u{0433}\u{043E} — \u{0446}\u{0435}\u{043B}\u{0438}\u{043A}\u{043E}\u{043C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430}")
        XCTAssertEqual(report.characterErrorRate, 1.0 / 3.0, accuracy: 0.0001)
    }

    func testAlignmentAgreesWithLevenshteinDistance() {
        // Path and distance are considered different functions; if they break up,
        // WER and CER will also diverge.
        let reference = "\u{043E}\u{0434}\u{0438}\u{043D} \u{0434}\u{0432}\u{0430} \u{0442}\u{0440}\u{0438} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435} \u{043F}\u{044F}\u{0442}\u{044C} \u{0448}\u{0435}\u{0441}\u{0442}\u{044C}".split(separator: " ").map(String.init)
        let hypothesis = "\u{043E}\u{0434}\u{0438}\u{043D} \u{0442}\u{0440}\u{0438} \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435} \u{043F}\u{044F}\u{0442}\u{044C} \u{0432}\u{043E}\u{0441}\u{0435}\u{043C}\u{044C} \u{0441}\u{0435}\u{043C}\u{044C}".split(separator: " ").map(String.init)

        let (counts, _) = TranscriptScorer.align(reference, hypothesis)
        // Same sequences, but one character per word: distance
        // is considered another function, and they have no right to separate.
        let distance = TranscriptScorer.distance(
            Array(reference.map { $0.first! }),
            Array(hypothesis.map { $0.first! })
        )

        XCTAssertEqual(counts.errors, distance, "\u{0412}\u{044B}\u{0440}\u{0430}\u{0432}\u{043D}\u{0438}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435} \u{0438} \u{0440}\u{0430}\u{0441}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{0441}\u{043E}\u{0432}\u{043F}\u{0430}\u{0434}\u{0430}\u{0442}\u{044C}")
    }
}

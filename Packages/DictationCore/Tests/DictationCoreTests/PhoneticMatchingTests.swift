import XCTest
@testable import DictationCore

/// Phonetic key: what he considers to be one word and what is different.
///
/// Tests are written based on the rules of Russian phonetics, and not on a list of successful cases:
/// if the rule breaks, a line will appear explaining which one it is.
final class PhoneticKeyTests: XCTestCase {
    private func same(_ left: String, _ right: String, _ why: String) {
        XCTAssertEqual(
            PhoneticKey.of(left), PhoneticKey.of(right),
            "«\(left)» \u{0438} «\(right)» \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{0431}\u{044B}\u{0442}\u{044C} \u{043E}\u{0434}\u{043D}\u{0438}\u{043C} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E}\u{043C}: \(why)"
        )
    }

    private func different(_ left: String, _ right: String, _ why: String) {
        XCTAssertNotEqual(
            PhoneticKey.of(left), PhoneticKey.of(right),
            "«\(left)» \u{0438} «\(right)» \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0440}\u{0430}\u{0437}\u{043D}\u{044B}\u{043C}\u{0438}: \(why)"
        )
    }

    func testUnstressedVowelsCollapse() {
        same("\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{0431}\u{0435}\u{0437}\u{0443}\u{0434}\u{0430}\u{0440}\u{043D}\u{044B}\u{0435} «\u{0438}» \u{0438} «\u{0435}» \u{0437}\u{0432}\u{0443}\u{0447}\u{0430}\u{0442} \u{043E}\u{0434}\u{0438}\u{043D}\u{0430}\u{043A}\u{043E}\u{0432}\u{043E}")
        same("\u{0431}\u{044D}\u{043A}\u{044D}\u{043D}\u{0434}", "\u{0431}\u{044D}\u{043A}\u{0435}\u{043D}\u{0434}", "«\u{044D}» \u{0438} «\u{0435}» — \u{043E}\u{0434}\u{043D}\u{0430} \u{0433}\u{043B}\u{0430}\u{0441}\u{043D}\u{0430}\u{044F}")
        same("\u{043A}\u{0430}\u{043C}\u{0438}\u{0442}", "\u{043A}\u{043E}\u{043C}\u{0438}\u{0442}", "\u{0431}\u{0435}\u{0437}\u{0443}\u{0434}\u{0430}\u{0440}\u{043D}\u{043E}\u{0435} «\u{043E}» \u{0437}\u{0432}\u{0443}\u{0447}\u{0438}\u{0442} \u{043A}\u{0430}\u{043A} «\u{0430}»")
        same("\u{043C}\u{043E}\u{0440}\u{0434}\u{0436}", "\u{043C}\u{0451}\u{0440}\u{0434}\u{0436}", "«\u{0451}» — \u{044D}\u{0442}\u{043E} «\u{043E}» \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043C}\u{044F}\u{0433}\u{043A}\u{043E}\u{0433}\u{043E}")
    }

    func testDoubledLettersCollapse() {
        same("\u{043A}\u{043E}\u{043C}\u{0438}\u{0442}", "\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}", "\u{0443}\u{0434}\u{0432}\u{043E}\u{0435}\u{043D}\u{0438}\u{0435} \u{043D}\u{0430} \u{0441}\u{043B}\u{0443}\u{0445} \u{043D}\u{0435} \u{0440}\u{0430}\u{0437}\u{043B}\u{0438}\u{0447}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
        same("\u{0440}\u{0438}\u{043B}\u{0438}\u{0441}", "\u{0440}\u{0438}\u{043B}\u{043B}\u{0438}\u{0441}", "\u{0442}\u{043E} \u{0436}\u{0435} \u{0441}\u{0430}\u{043C}\u{043E}\u{0435}")
    }

    func testVoicingCollapsesOnlyWhereRussianNeutralisesIt() {
        same("\u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0441}", "\u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0437}", "\u{0432} \u{043A}\u{043E}\u{043D}\u{0446}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430} \u{0437}\u{0432}\u{043E}\u{043D}\u{043A}\u{0438}\u{0435} \u{043E}\u{0433}\u{043B}\u{0443}\u{0448}\u{0430}\u{044E}\u{0442}\u{0441}\u{044F}")
        same("\u{0444}\u{0440}\u{043E}\u{043D}\u{0442}\u{0435}\u{043D}\u{0442}", "\u{0444}\u{0440}\u{043E}\u{043D}\u{0442}\u{0435}\u{043D}\u{0434}", "\u{0442}\u{043E} \u{0436}\u{0435} \u{0441}\u{0430}\u{043C}\u{043E}\u{0435}")
        same("\u{0445}\u{043E}\u{0442}\u{0444}\u{0438}\u{043A}\u{0441}", "\u{0445}\u{043E}\u{0434}\u{0444}\u{0438}\u{043A}\u{0441}", "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} \u{0433}\u{043B}\u{0443}\u{0445}\u{0438}\u{043C} «\u{0444}» \u{0437}\u{0432}\u{043E}\u{043D}\u{043A}\u{0430}\u{044F} «\u{0434}» \u{043E}\u{0433}\u{043B}\u{0443}\u{0448}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")

        // For the sake of these three lines, the stun is made positional. Without them set
        // ate 161 ordinary Russian words instead of 70 - with the same winnings.
        different("\u{0442}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{0432} \u{043D}\u{0430}\u{0447}\u{0430}\u{043B}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430} \u{0440}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439} \u{043D}\u{0438}\u{0447}\u{0435}\u{0433}\u{043E} \u{043D}\u{0435} \u{043E}\u{0433}\u{043B}\u{0443}\u{0448}\u{0430}\u{0435}\u{0442}")
        different("\u{0431}\u{0435}\u{0442}\u{043E}\u{043D}", "\u{043F}\u{0438}\u{0442}\u{043E}\u{043D}", "\u{0442}\u{043E} \u{0436}\u{0435} \u{0441}\u{0430}\u{043C}\u{043E}\u{0435}")
        different("\u{043F}\u{0440}\u{043E}\u{0442}\u{0451}\u{043A}\u{0448}", "\u{043F}\u{0440}\u{043E}\u{0434}\u{0430}\u{043A}\u{0448}", "\u{043C}\u{0435}\u{0436}\u{0434}\u{0443} \u{0433}\u{043B}\u{0430}\u{0441}\u{043D}\u{044B}\u{043C}\u{0438} \u{043E}\u{0433}\u{043B}\u{0443}\u{0448}\u{0435}\u{043D}\u{0438}\u{044F} \u{043D}\u{0435}\u{0442}")
    }

    func testFinalVowelIsNeverFolded() {
        // The main protection of the dictionary: the case ending lives in the last vowel.
        different("\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}", "\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", "\u{0438}\u{043D}\u{0430}\u{0447}\u{0435} «\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}» \u{0441}\u{0442}\u{0430}\u{043D}\u{0435}\u{0442} «\u{0432} Sentry \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}»")
        different("\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0435}", "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0438}", "\u{0442}\u{0430} \u{0436}\u{0435} \u{043F}\u{0440}\u{0438}\u{0447}\u{0438}\u{043D}\u{0430}")
    }

    func testSoftSignIsPartOfTheWord() {
        different("\u{043A}\u{0430}\u{043C}\u{0435}\u{0434}\u{044C}", "\u{043A}\u{0430}\u{043C}\u{0435}\u{0442}", "\u{043C}\u{044F}\u{0433}\u{043A}\u{0438}\u{0439} \u{0437}\u{043D}\u{0430}\u{043A} — \u{043D}\u{0435} \u{0443}\u{043A}\u{0440}\u{0430}\u{0448}\u{0435}\u{043D}\u{0438}\u{0435}")
        different("\u{0440}\u{0435}\u{0432}\u{044E}", "\u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "«\u{0440}\u{0435}\u{0432}\u{044E}» — \u{0441}\u{0432}\u{043E}\u{0451} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E}")
    }
}

/// Second pass of the dictionary on the real output of the model.
///
/// All left parts are from the Parakeet run: this is what the model wrote on
/// in fact, when the voice pronounced an English term inside a Russian phrase.
/// None of these spellings are in the dictionary and cannot be - in another phrase
/// the same word will come out differently.
final class PhoneticMatchingTests: XCTestCase {
    private func polished(_ text: String) -> String {
        DictionaryReplacements.apply(StarterDictionary.developer, to: text)
    }

    func testSpellingsTheDictionaryNeverSawAreStillRecognised() {
        let measured = [
            ("\u{0417}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} \u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439} \u{0432} \u{043F}\u{044F}\u{0442}\u{043D}\u{0438}\u{0446}\u{0443} \u{0432}\u{0435}\u{0447}\u{0435}\u{0440}\u{043E}\u{043C}.", "deploy"),
            ("\u{042F} \u{043F}\u{043E}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043B} \u{0431}\u{044D}\u{043A}\u{044D}\u{043D}\u{0434} \u{0438} \u{0437}\u{0430}\u{043B}\u{0438}\u{043B} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0435}\u{043D}\u{0438}\u{044F}.", "backend"),
            ("\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043A}\u{043E}\u{043C}\u{0438}\u{0442} \u{0432} \u{0432}\u{0435}\u{0442}\u{043A}\u{0443}.", "commit"),
            ("\u{041F}\u{043E}\u{0442}\u{043E}\u{043C} \u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0441} \u{0438} \u{043C}\u{043E}\u{0440}\u{0434}\u{0436}.", "merge"),
            ("\u{041F}\u{043E}\u{0442}\u{043E}\u{043C} \u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0441} \u{0438} \u{043C}\u{043E}\u{0440}\u{0434}\u{0436}.", "rebase"),
            ("\u{0412}\u{044B}\u{043A}\u{0430}\u{0442}\u{0438} \u{0440}\u{043E}\u{043B}\u{043B}\u{0431}\u{044B}\u{043A} \u{0431}\u{0435}\u{0437} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}.", "rollback"),
            ("\u{0424}\u{0440}\u{043E}\u{043D}\u{0442}\u{0435}\u{043D}\u{0442} \u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{0435}\u{0442} \u{043C}\u{0435}\u{0434}\u{043B}\u{0435}\u{043D}\u{043D}\u{043E}.", "frontend"),
            ("\u{041C}\u{044B} \u{0432}\u{044B}\u{043A}\u{0430}\u{0442}\u{0438}\u{043B}\u{0438} \u{0440}\u{0438}\u{043B}\u{043B}\u{0438}\u{0441} \u{0432}\u{0447}\u{0435}\u{0440}\u{0430} \u{043D}\u{043E}\u{0447}\u{044C}\u{044E}.", "release"),
        ]

        for (heard, expected) in measured {
            XCTAssertTrue(
                polished(heard).contains(expected),
                "«\(heard)» \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{043E} \u{0434}\u{0430}\u{0442}\u{044C} «\(expected)», \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} «\(polished(heard))»"
            )
        }
    }

    func testTermSplitInTwoWordsIsGluedBack() {
        // The model either glues the term together or breaks it apart - in the same record.
        XCTAssertEqual(polished("\u{0432}\u{044B}\u{043A}\u{0430}\u{0442}\u{044B}\u{0432}\u{0430}\u{0439} \u{0431}\u{0435}\u{0437} \u{0434}\u{0430}\u{0443}\u{043D} \u{0442}\u{0430}\u{0439}\u{043C}\u{0430}"), "\u{0432}\u{044B}\u{043A}\u{0430}\u{0442}\u{044B}\u{0432}\u{0430}\u{0439} \u{0431}\u{0435}\u{0437} downtime")
        XCTAssertEqual(polished("\u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{0438}\u{043B} \u{044D}\u{043D}\u{0434} \u{043F}\u{043E}\u{0438}\u{043D}\u{0442}"), "\u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{0438}\u{043B} endpoint")
        XCTAssertEqual(polished("\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} \u{043D}\u{0430} \u{0434}\u{0436}\u{0430}\u{0432}\u{0430} \u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}\u{0435}"), "\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} \u{043D}\u{0430} JavaScript")
        XCTAssertEqual(polished("\u{043C}\u{044B} \u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{043D}\u{0430} \u{0442}\u{0430}\u{0439}\u{043F} \u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}\u{0435}"), "\u{043C}\u{044B} \u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{043D}\u{0430} TypeScript")
    }

    func testUnknownSpellingInAnObliqueCaseIsRecognised() {
        // The Russian declines the term, and the model writes it as she hears it. Meet
        // both troubles at once, and most often this is the case.
        XCTAssertEqual(polished("\u{0441}\u{0440}\u{0430}\u{0437}\u{0443} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{044F}"), "\u{0441}\u{0440}\u{0430}\u{0437}\u{0443} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} deploy")
        XCTAssertEqual(polished("\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} \u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0435}\u{043C}"), "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} deploy")
        XCTAssertEqual(polished("\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430} \u{043D}\u{0430}\u{0434} \u{0431}\u{044D}\u{043A}\u{044D}\u{043D}\u{0434}\u{043E}\u{043C}"), "\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430} \u{043D}\u{0430}\u{0434} backend")
    }

    func testWordsBrokenByPunctuationAreNotGluedTogether() {
        // “End, point” are two different places in the phrase, not a broken term.
        XCTAssertEqual(polished("\u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{043B} \u{044D}\u{043D}\u{0434}, \u{043F}\u{043E}\u{0438}\u{043D}\u{0442} \u{043D}\u{0435} \u{0442}\u{0440}\u{043E}\u{0433}\u{0430}\u{0439}"), "\u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{043B} \u{044D}\u{043D}\u{0434}, \u{043F}\u{043E}\u{0438}\u{043D}\u{0442} \u{043D}\u{0435} \u{0442}\u{0440}\u{043E}\u{0433}\u{0430}\u{0439}")
    }

    // MARK: - What phonetics doesn't do

    func testShortReplacementsStayExact() {
        // Short words have too much normal speech per key.
        let replacements = [DictionaryReplacement(spoken: "\u{0430}\u{043F}\u{0438}", written: "API")]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "\u{044D}\u{043F}\u{0438} \u{0438} \u{043E}\u{043F}\u{0430}"), "\u{044D}\u{043F}\u{0438} \u{0438} \u{043E}\u{043F}\u{0430}")
    }

    func testLatinReplacementsAreNotMatchedPhonetically() {
        // The rules are Russian: applying them to the Latin alphabet means guessing.
        let replacements = [DictionaryReplacement(spoken: "swift", written: "Swift")]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "sweft"), "sweft")
    }

    func testDeletingReplacementsAreNeverMatchedPhonetically() {
        // The empty right side crosses out the filler word. Cross out by guess
        // impossible: a person will see the replaced word in the text, but the disappeared word will be visible
        // No. The price is fair: “shorter” will have to be crossed out as a separate entry.
        let replacements = [DictionaryReplacement(spoken: "\u{043A}\u{043E}\u{0440}\u{043E}\u{0447}\u{0435}", written: "")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043A}\u{0430}\u{0440}\u{043E}\u{0447}\u{0435} \u{044F} \u{043F}\u{043E}\u{0448}\u{0451}\u{043B}"),
            "\u{043A}\u{0430}\u{0440}\u{043E}\u{0447}\u{0435} \u{044F} \u{043F}\u{043E}\u{0448}\u{0451}\u{043B}"
        )
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043A}\u{043E}\u{0440}\u{043E}\u{0447}\u{0435} \u{044F} \u{043F}\u{043E}\u{0448}\u{0451}\u{043B}"),
            " \u{044F} \u{043F}\u{043E}\u{0448}\u{0451}\u{043B}"
        )
    }

    func testOneKeyForTwoTermsIsNotAGuess() {
        // If two entries sound the same but are spelled differently, select
        // not possible. Exact match still works.
        let replacements = [
            DictionaryReplacement(spoken: "\u{0440}\u{044D}\u{043D}\u{0434}\u{043E}\u{043C}", written: "random"),
            DictionaryReplacement(spoken: "\u{0440}\u{044B}\u{043D}\u{0434}\u{0430}\u{043C}", written: "rundum"),
        ]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "\u{0440}\u{044B}\u{043D}\u{0434}\u{043E}\u{043C}"), "\u{0440}\u{044B}\u{043D}\u{0434}\u{043E}\u{043C}")
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "\u{0440}\u{044D}\u{043D}\u{0434}\u{043E}\u{043C}"), "random")
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "\u{0440}\u{044B}\u{043D}\u{0434}\u{0430}\u{043C}"), "rundum")
    }

    func testDigitsNextToLettersMakeADifferentWord() {
        let replacements = [DictionaryReplacement(spoken: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", written: "deploy")]
        XCTAssertEqual(DictionaryReplacements.apply(replacements, to: "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}2"), "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}2")
    }
}

/// Comparison price: ordinary Russian speech.
///
/// This is the main test of the dictionary. A product that impairs normal speech is worse
/// of a product that does not recognize the term: the person sees the missing term and
/// is correct, the substituted word is not.
///
/// The list of words is not made up. It was obtained by brute force: for each dictionary entry
/// all spellings are built with the same phonetic key, and system
/// The spell checker selected real Russian words from them. Here -
/// the entire catch.
final class DictionaryFalsePositiveTests: XCTestCase {
    private func assertUntouched(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            DictionaryReplacements.apply(StarterDictionary.developer, to: text),
            text,
            file: file,
            line: line
        )
    }

    func testOrdinaryRussianSpeechSurvivesTheStarterDictionary() {
        let speech = [
            // Previously, the set would turn this into "on commit to the telescope".
            "\u{0432}\u{0447}\u{0435}\u{0440}\u{0430} \u{043C}\u{044B} \u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}\u{043B}\u{0438} \u{043D}\u{0430} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0443} \u{0432} \u{0442}\u{0435}\u{043B}\u{0435}\u{0441}\u{043A}\u{043E}\u{043F}",
            "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0430} \u{0413}\u{0430}\u{043B}\u{043B}\u{0435}\u{044F} \u{0432}\u{0435}\u{0440}\u{043D}\u{0451}\u{0442}\u{0441}\u{044F} \u{043D}\u{0435} \u{0441}\u{043A}\u{043E}\u{0440}\u{043E}",
            "\u{043E}\u{043D} \u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B} \u{0440}\u{0435}\u{0444}\u{0435}\u{0440}\u{0430}\u{0442} \u{043E} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0435}",
            "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{044B} \u{0432}\u{0438}\u{0434}\u{043D}\u{043E} \u{0442}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0432} \u{044F}\u{0441}\u{043D}\u{0443}\u{044E} \u{043D}\u{043E}\u{0447}\u{044C}",
            "\u{043D}\u{0430}\u{0431}\u{043B}\u{044E}\u{0434}\u{0435}\u{043D}\u{0438}\u{0435} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442} \u{043F}\u{0440}\u{043E}\u{0434}\u{043E}\u{043B}\u{0436}\u{0430}\u{043B}\u{043E}\u{0441}\u{044C} \u{0432}\u{0441}\u{044E} \u{043D}\u{043E}\u{0447}\u{044C}",
            "\u{044D}\u{043C}\u{0438}\u{0442} \u{0441}\u{043E}\u{0431}\u{044B}\u{0442}\u{0438}\u{0435} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0431}\u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{043A}\u{0438} \u{0437}\u{0430}\u{043F}\u{0440}\u{043E}\u{0441}\u{0430}",
            // Previously - “Docker unloaded the ship.”
            "\u{0434}\u{043E}\u{043A}\u{0435}\u{0440}\u{044B} \u{0440}\u{0430}\u{0437}\u{0433}\u{0440}\u{0443}\u{0436}\u{0430}\u{043B}\u{0438} \u{0441}\u{0443}\u{0434}\u{043D}\u{043E} \u{0432} \u{043F}\u{043E}\u{0440}\u{0442}\u{0443}",
            "\u{0434}\u{043E}\u{043A}\u{0435}\u{0440} \u{0440}\u{0430}\u{0431}\u{043E}\u{0442}\u{0430}\u{043B} \u{0432} \u{043D}\u{043E}\u{0447}\u{043D}\u{0443}\u{044E} \u{0441}\u{043C}\u{0435}\u{043D}\u{0443}",
            // Previously - "Python compressed mining."
            "\u{043F}\u{0438}\u{0442}\u{043E}\u{043D} \u{0441}\u{0436}\u{0430}\u{043B} \u{0434}\u{043E}\u{0431}\u{044B}\u{0447}\u{0443} \u{0438} \u{0437}\u{0430}\u{043C}\u{0435}\u{0440}",
            "\u{043F}\u{0438}\u{0442}\u{043E}\u{043D}\u{044B} \u{0441}\u{043F}\u{044F}\u{0442} \u{043F}\u{043E}\u{0447}\u{0442}\u{0438} \u{0432}\u{0441}\u{0451} \u{0432}\u{0440}\u{0435}\u{043C}\u{044F}",
            // Previously, “Redis grow in the garden bed.”
            "\u{043D}\u{0430} \u{0433}\u{0440}\u{044F}\u{0434}\u{043A}\u{0435} \u{0440}\u{0430}\u{0441}\u{0442}\u{0443}\u{0442} \u{0440}\u{0435}\u{0434}\u{0438}\u{0441} \u{0438} \u{0443}\u{043A}\u{0440}\u{043E}\u{043F}",
            "\u{043C}\u{044B} \u{043F}\u{043E}\u{0448}\u{043B}\u{0438} \u{043D}\u{0430} \u{0431}\u{0440}\u{0430}\u{043D}\u{0447} \u{0432} \u{0432}\u{043E}\u{0441}\u{043A}\u{0440}\u{0435}\u{0441}\u{0435}\u{043D}\u{044C}\u{0435}",
            // It has always worked and must continue to work.
            "\u{0432}\u{0441}\u{0442}\u{0440}\u{0435}\u{0442}\u{0438}\u{043C}\u{0441}\u{044F} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}",
            "\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0430}\u{043B}\u{044C}\u{043D}\u{0430}\u{044F} \u{0443}\u{043B}\u{0438}\u{0446}\u{0430} \u{0431}\u{044B}\u{043B}\u{0430} \u{043F}\u{0435}\u{0440}\u{0435}\u{043A}\u{0440}\u{044B}\u{0442}\u{0430}",
            // It would appear if we minimized the sonority anywhere.
            "\u{0432} \u{0442}\u{0451}\u{043F}\u{043B}\u{043E}\u{0439} \u{0432}\u{043E}\u{0434}\u{0435} \u{043F}\u{043B}\u{0430}\u{0432}\u{0430}\u{043B}\u{0438} \u{0443}\u{0442}\u{043A}\u{0438}",
            "\u{0431}\u{0435}\u{0442}\u{043E}\u{043D} \u{0437}\u{0430}\u{0441}\u{0442}\u{044B}\u{043B} \u{0442}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{043A} \u{0443}\u{0442}\u{0440}\u{0443}",
            "\u{0431}\u{0438}\u{0434}\u{043E}\u{043D} \u{0441} \u{043C}\u{043E}\u{043B}\u{043E}\u{043A}\u{043E}\u{043C} \u{0441}\u{0442}\u{043E}\u{044F}\u{043B} \u{0432} \u{0441}\u{0435}\u{043D}\u{044F}\u{0445}",
            "\u{043C}\u{044B} \u{0440}\u{044B}\u{043B}\u{0438}\u{0441}\u{044C} \u{0432} \u{0441}\u{0442}\u{0430}\u{0440}\u{044B}\u{0445} \u{0431}\u{0443}\u{043C}\u{0430}\u{0433}\u{0430}\u{0445} \u{0432}\u{0435}\u{0441}\u{044C} \u{0432}\u{0435}\u{0447}\u{0435}\u{0440}",
            "\u{043F}\u{0440}\u{043E}\u{0442}\u{0451}\u{043A}\u{0448}\u{0430}\u{044F} \u{043A}\u{0440}\u{044B}\u{0448}\u{0430} \u{0438}\u{0441}\u{043F}\u{043E}\u{0440}\u{0442}\u{0438}\u{043B}\u{0430} \u{043F}\u{043E}\u{0442}\u{043E}\u{043B}\u{043E}\u{043A}",
            "\u{043A}\u{0430}\u{043C}\u{0435}\u{0434}\u{044C} \u{043D}\u{0430} \u{0441}\u{0442}\u{0432}\u{043E}\u{043B}\u{0435} \u{0432}\u{0438}\u{0448}\u{043D}\u{0438} \u{0437}\u{0430}\u{0441}\u{0442}\u{044B}\u{043B}\u{0430} \u{043A}\u{0430}\u{043F}\u{043B}\u{044F}\u{043C}\u{0438}",
            "\u{044D}\u{043A}\u{0437}\u{043E}\u{0442}\u{044B} \u{0432} \u{044D}\u{0442}\u{043E}\u{0439} \u{043E}\u{0440}\u{0430}\u{043D}\u{0436}\u{0435}\u{0440}\u{0435}\u{0435} \u{043D}\u{0435} \u{043F}\u{0440}\u{0438}\u{0436}\u{0438}\u{0432}\u{0430}\u{044E}\u{0442}\u{0441}\u{044F}",
            "\u{0432}\u{0435}\u{0447}\u{0435}\u{0440}\u{043D}\u{0435}\u{0435} \u{0440}\u{0435}\u{0432}\u{044E} \u{043C}\u{044B} \u{0434}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}\u{043B}\u{0438} \u{0434}\u{043E} \u{043A}\u{043E}\u{043D}\u{0446}\u{0430}",
            // Just similar words.
            "\u{043D}\u{0430} \u{043B}\u{044C}\u{0434}\u{0438}\u{043D}\u{0435} \u{0441}\u{0438}\u{0434}\u{0435}\u{043B} \u{043C}\u{043E}\u{0440}\u{0436}",
            "\u{043A}\u{043E}\u{043C}\u{0438}\u{0442}\u{0435}\u{0442} \u{0441}\u{043E}\u{0431}\u{0440}\u{0430}\u{043B}\u{0441}\u{044F} \u{0432} \u{0441}\u{0440}\u{0435}\u{0434}\u{0443}",
            "\u{0434}\u{043E}\u{043A}\u{0442}\u{043E}\u{0440} \u{0432}\u{0435}\u{043B}\u{0435}\u{043B} \u{0431}\u{043E}\u{043B}\u{044C}\u{0448}\u{0435} \u{0433}\u{0443}\u{043B}\u{044F}\u{0442}\u{044C}",
            "\u{043B}\u{0438}\u{043D}\u{0435}\u{0439}\u{043A}\u{0443} \u{044F} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{043B} \u{0435}\u{0449}\u{0451} \u{0432} \u{043F}\u{0440}\u{043E}\u{0448}\u{043B}\u{043E}\u{043C} \u{0433}\u{043E}\u{0434}\u{0443}",
            "\u{043F}\u{0440}\u{043E}\u{0434}\u{0430}\u{0432}\u{0449}\u{0438}\u{0446}\u{0430} \u{043F}\u{043E}\u{0441}\u{043E}\u{0432}\u{0435}\u{0442}\u{043E}\u{0432}\u{0430}\u{043B}\u{0430} \u{0432}\u{0437}\u{044F}\u{0442}\u{044C} \u{0431}\u{0430}\u{0442}\u{043E}\u{043D} \u{043F}\u{043E}\u{0441}\u{0432}\u{0435}\u{0436}\u{0435}\u{0435}",
        ]

        for phrase in speech {
            assertUntouched(phrase)
        }
    }

    func testConnectedSpeechIsNotTouchedAnywhere() {
        // A coherent piece, not a collection of individual words: substitution in the middle of a phrase
        // is the worst visible.
        assertUntouched("""
            \u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{0443}\u{0442}\u{0440}\u{043E}\u{043C} \u{044F} \u{0432}\u{044B}\u{0448}\u{0435}\u{043B} \u{0438}\u{0437} \u{0434}\u{043E}\u{043C}\u{0430} \u{043F}\u{043E}\u{0440}\u{0430}\u{043D}\u{044C}\u{0448}\u{0435} \u{0438} \u{0443}\u{0441}\u{043F}\u{0435}\u{043B} \u{043D}\u{0430} \u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{0439} \u{0430}\u{0432}\u{0442}\u{043E}\u{0431}\u{0443}\u{0441}. \
            \u{0412} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430} \u{0431}\u{044B}\u{043B}\u{043E} \u{043F}\u{0443}\u{0441}\u{0442}\u{043E}, \u{0442}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0434}\u{0432}\u{043E}\u{0440}\u{043D}\u{0438}\u{043A}\u{0438} \u{043C}\u{0435}\u{043B}\u{0438} \u{0442}\u{0440}\u{043E}\u{0442}\u{0443}\u{0430}\u{0440}\u{044B}. \
            \u{0414}\u{043E}\u{043A}\u{0442}\u{043E}\u{0440} \u{0441}\u{043E}\u{0432}\u{0435}\u{0442}\u{043E}\u{0432}\u{0430}\u{043B} \u{0431}\u{043E}\u{043B}\u{044C}\u{0448}\u{0435} \u{0433}\u{0443}\u{043B}\u{044F}\u{0442}\u{044C}, \u{0438} \u{044F} \u{0440}\u{0435}\u{0448}\u{0438}\u{043B} \u{043F}\u{0440}\u{043E}\u{0439}\u{0442}\u{0438}\u{0441}\u{044C} \u{043F}\u{0435}\u{0448}\u{043A}\u{043E}\u{043C} \u{0434}\u{043E} \u{043F}\u{0430}\u{0440}\u{043A}\u{0430}, \
            \u{0433}\u{0434}\u{0435} \u{043C}\u{044B} \u{0434}\u{043E}\u{0433}\u{043E}\u{0432}\u{043E}\u{0440}\u{0438}\u{043B}\u{0438}\u{0441}\u{044C} \u{0432}\u{0441}\u{0442}\u{0440}\u{0435}\u{0442}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{0443} \u{0441}\u{0442}\u{0430}\u{0440}\u{043E}\u{0439} \u{0432}\u{043E}\u{0434}\u{043E}\u{043D}\u{0430}\u{043F}\u{043E}\u{0440}\u{043D}\u{043E}\u{0439} \u{0431}\u{0430}\u{0448}\u{043D}\u{0438}. \
            \u{0412}\u{0435}\u{0447}\u{0435}\u{0440}\u{043E}\u{043C} \u{043F}\u{043E}\u{0448}\u{0451}\u{043B} \u{0434}\u{043E}\u{0436}\u{0434}\u{044C}, \u{0438} \u{0432}\u{0441}\u{0435} \u{0441}\u{043F}\u{0440}\u{044F}\u{0442}\u{0430}\u{043B}\u{0438}\u{0441}\u{044C} \u{043F}\u{043E}\u{0434} \u{043D}\u{0430}\u{0432}\u{0435}\u{0441}\u{043E}\u{043C} \u{0443} \u{043C}\u{0430}\u{0433}\u{0430}\u{0437}\u{0438}\u{043D}\u{0430} \u{043D}\u{0430} \u{0443}\u{0433}\u{043B}\u{0443}.
            """)
    }

    func testVoicingIsNotFoldedWhereRussianKeepsIt() {
        // The rule is also checked on the user record: it can no longer be typed
        // contains, and the person starts one.
        let replacements = [DictionaryReplacement(spoken: "\u{043F}\u{0438}\u{0442}\u{043E}\u{043D}", written: "Python")]
        for phrase in ["\u{0431}\u{0435}\u{0442}\u{043E}\u{043D} \u{0437}\u{0430}\u{0441}\u{0442}\u{044B}\u{043B} \u{043A} \u{0443}\u{0442}\u{0440}\u{0443}", "\u{0431}\u{0438}\u{0434}\u{043E}\u{043D} \u{0441} \u{043C}\u{043E}\u{043B}\u{043E}\u{043A}\u{043E}\u{043C}", "\u{0431}\u{0443}\u{0442}\u{043E}\u{043D} \u{0440}\u{0430}\u{0441}\u{043A}\u{0440}\u{044B}\u{043B}\u{0441}\u{044F}"] {
            XCTAssertEqual(DictionaryReplacements.apply(replacements, to: phrase), phrase)
        }
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}\u{044B} \u{0443} \u{043D}\u{0430}\u{0441} \u{043D}\u{0430} \u{043F}\u{0438}\u{0442}\u{043E}\u{043D}\u{0435}"),
            "\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}\u{044B} \u{0443} \u{043D}\u{0430}\u{0441} \u{043D}\u{0430} Python"
        )
    }
}

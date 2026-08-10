import XCTest
@testable import DictationCore

/// The user fills the dictionary with his hands, and anything goes there:
/// "etc", "c++", ":)", empty right side. Replacement inside is regular
/// expression, which means that any such character can turn from text into
/// instructions. A damaged replacement breaks not just one word, but the entire phrase, and
/// a person finds out about this after inserting it into someone else’s window.
final class DictionaryReplacementsEdgeCaseTests: XCTestCase {

    // MARK: - Special characters in what is heard

    func testDotsInTheSpokenFormAreTakenLiterally() {
        // Abbreviations with dots are common in the dictionary. Point in regular
        // expression means "any character", and no escaping rule
        // "etc." it would hit anything similar in length.
        let replacements = [DictionaryReplacement(spoken: "\u{0442}.\u{0434}.", written: "\u{0442}\u{0430}\u{043A} \u{0434}\u{0430}\u{043B}\u{0435}\u{0435}")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043C}\u{043E}\u{043B}\u{043E}\u{043A}\u{043E}, \u{0445}\u{043B}\u{0435}\u{0431} \u{0438} \u{0442}.\u{0434}. \u{043A}\u{0443}\u{043F}\u{0438}"),
            "\u{043C}\u{043E}\u{043B}\u{043E}\u{043A}\u{043E}, \u{0445}\u{043B}\u{0435}\u{0431} \u{0438} \u{0442}\u{0430}\u{043A} \u{0434}\u{0430}\u{043B}\u{0435}\u{0435} \u{043A}\u{0443}\u{043F}\u{0438}"
        )
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0442}\u{0445}\u{0434}\u{0445} \u{043D}\u{0435} \u{0442}\u{0440}\u{043E}\u{0433}\u{0430}\u{0435}\u{043C}"),
            "\u{0442}\u{0445}\u{0434}\u{0445} \u{043D}\u{0435} \u{0442}\u{0440}\u{043E}\u{0433}\u{0430}\u{0435}\u{043C}"
        )
    }

    func testPlusesAndBracketsInTheSpokenFormDoNotBreakTheRule() {
        // “c++” and “:)” are valid dictionary entries and at the same time chunks
        // regular expression. Unescaped parentheses make the expression
        // invalid, and the rule silently stops working entirely.
        let replacements = [
            DictionaryReplacement(spoken: "c++", written: "C++"),
            DictionaryReplacement(spoken: ":)", written: "🙂"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043F}\u{0438}\u{0448}\u{0443} \u{043D}\u{0430} c++ \u{0438} \u{0440}\u{0430}\u{0434} :)"),
            "\u{043F}\u{0438}\u{0448}\u{0443} \u{043D}\u{0430} C++ \u{0438} \u{0440}\u{0430}\u{0434} 🙂"
        )
    }

    func testStarInTheSpokenFormMatchesTheStarItself() {
        // An asterisk in a regular expression is a repeat of the previous character.
        // In the dictionary it's just a symbol.
        let replacements = [DictionaryReplacement(spoken: "*", written: "\u{0437}\u{0432}\u{0451}\u{0437}\u{0434}\u{043E}\u{0447}\u{043A}\u{0430}")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043F}\u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{044C} * \u{0442}\u{0443}\u{0442}"),
            "\u{043F}\u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{044C} \u{0437}\u{0432}\u{0451}\u{0437}\u{0434}\u{043E}\u{0447}\u{043A}\u{0430} \u{0442}\u{0443}\u{0442}"
        )
    }

    // MARK: - Special characters in what is written

    func testDollarInTheWrittenFormIsNotATemplateReference() {
        // In the replacement pattern, "$1" means "first captured group". Without
        // escaping the price "$100" would turn into "00": user
        // would get silently corrupted text, not an error.
        let replacements = [DictionaryReplacement(spoken: "\u{0446}\u{0435}\u{043D}\u{0430}", written: "$100")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0446}\u{0435}\u{043D}\u{0430} \u{0432}\u{043E}\u{043F}\u{0440}\u{043E}\u{0441}\u{0430}"),
            "$100 \u{0432}\u{043E}\u{043F}\u{0440}\u{043E}\u{0441}\u{0430}"
        )
    }

    func testBackslashInTheWrittenFormSurvives() {
        let replacements = [DictionaryReplacement(spoken: "\u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441}", written: #"\n"#)]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0442}\u{0443}\u{0442} \u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}"),
            "\u{0442}\u{0443}\u{0442} \\n \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}"
        )
    }

    // MARK: - Degenerate records

    func testEmptyWrittenFormRemovesTheWordWithoutLeavingHoles() {
        // The empty right side is a way to remove the filler word. After removal
        // two spaces remain in a row, and the conveyor must remove them, otherwise
        // “cleaning” will be more noticeable than the parasite itself.
        let pipeline = TextPipeline(replacements: [
            DictionaryReplacement(spoken: "\u{043A}\u{043E}\u{0440}\u{043E}\u{0447}\u{0435}", written: ""),
        ])

        XCTAssertEqual(pipeline.process("\u{043A}\u{043E}\u{0440}\u{043E}\u{0447}\u{0435} \u{043D}\u{0443}\u{0436}\u{043D}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{043A}\u{043E}\u{0440}\u{043E}\u{0447}\u{0435} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{043E}").text, "\u{041D}\u{0443}\u{0436}\u{043D}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{043E}")
    }

    func testWhitespaceOnlySpokenFormIsIgnored() {
        // The empty left part is a dictionary line left due to inattention.
        // The "replace space" rule would rewrite the entire text.
        let replacements = [
            DictionaryReplacement(spoken: "   ", written: "\u{041F}\u{0420}\u{041E}\u{0411}\u{0415}\u{041B}"),
            DictionaryReplacement(spoken: "", written: "\u{041F}\u{0423}\u{0421}\u{0422}\u{041E}"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{044B}\u{0439} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0431}\u{0435}\u{0437} \u{0441}\u{044E}\u{0440}\u{043F}\u{0440}\u{0438}\u{0437}\u{043E}\u{0432}"),
            "\u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{044B}\u{0439} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0431}\u{0435}\u{0437} \u{0441}\u{044E}\u{0440}\u{043F}\u{0440}\u{0438}\u{0437}\u{043E}\u{0432}"
        )
    }

    func testSelfReplacementOnlyNormalizesTheCase() {
        // A word replaced by itself occurs when a person rules
        // dictionary and changes his mind. Nothing bad should happen:
        // no looping, no doubling - just reduction to the written form.
        let replacements = [DictionaryReplacement(spoken: "Swift", written: "Swift")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043F}\u{0438}\u{0448}\u{0443} \u{043D}\u{0430} swift \u{043A}\u{0430}\u{0436}\u{0434}\u{044B}\u{0439} \u{0434}\u{0435}\u{043D}\u{044C}"),
            "\u{043F}\u{0438}\u{0448}\u{0443} \u{043D}\u{0430} Swift \u{043A}\u{0430}\u{0436}\u{0434}\u{044B}\u{0439} \u{0434}\u{0435}\u{043D}\u{044C}"
        )
    }

    // MARK: - Word boundaries

    func testReplacementWorksAtBothEndsOfTheText() {
        let replacements = [DictionaryReplacement(spoken: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", written: "deploy")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439} \u{043F}\u{0440}\u{043E}\u{0448}\u{0451}\u{043B}, \u{043F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440}\u{0438}\u{043C} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}"),
            "deploy \u{043F}\u{0440}\u{043E}\u{0448}\u{0451}\u{043B}, \u{043F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440}\u{0438}\u{043C} deploy"
        )
    }

    func testDigitsCountAsPartOfAWord() {
        // “api2” is not “api”: otherwise the version at the end of the word would lose its meaning.
        let replacements = [DictionaryReplacement(spoken: "\u{0430}\u{043F}\u{0438}", written: "API")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0430}\u{043F}\u{0438}2 \u{0438} \u{0430}\u{043F}\u{0438}"),
            "\u{0430}\u{043F}\u{0438}2 \u{0438} API"
        )
    }

    // MARK: - Order of rules

    func testLaterRuleCanRewriteWhatAnEarlierRuleProduced() {
        // The rules are applied one by one to the already modified text, long
        // first. This means that the short rule sees the result of the long one - and this
        // exactly what happens when a person turns on each other
        // intersecting replacements. Behavior is fixed intentionally: it must
        // be predictable rather than dependent on the order of the lines in the list.
        let replacements = [
            DictionaryReplacement(spoken: "\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", written: "PR"),
            DictionaryReplacement(spoken: "PR", written: "\u{043F}\u{0438}\u{0430}\u{0440}"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}"),
            "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{0438}\u{0430}\u{0440}"
        )
    }

    // MARK: - Large dictionary

    func testLargeDictionaryStaysCorrectAndFast() {
        // The dictionary has been growing over the years: five hundred terms is a plausible size
        // for a person who dictates every day. Replacement occurs at the moment
        // when the user is already waiting for text, so both sides are important:
        // and that the desired rule worked, and that it did not take a second.
        var replacements = (0..<500).map {
            DictionaryReplacement(spoken: "\u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\($0)", written: "term\($0)")
        }
        replacements.append(DictionaryReplacement(spoken: "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", written: "Sentry"))

        let text = "\u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{0443}\u{043F}\u{0430}\u{043B} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}, \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} \u{043B}\u{043E}\u{0433}\u{0438} \u{0438} \u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} \u{0432} \u{0447}\u{0430}\u{0442}, \u{0447}\u{0442}\u{043E} \u{0432}\u{0441}\u{0451} \u{043F}\u{043E}\u{0434} \u{043A}\u{043E}\u{043D}\u{0442}\u{0440}\u{043E}\u{043B}\u{0435}\u{043C}"

        let started = Date()
        let result = DictionaryReplacements.apply(replacements, to: text)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.contains("Sentry"))
        XCTAssertFalse(result.contains("\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}"))
        // The threshold is rough: it catches not a slow car, but an accidentally skidded one
        // quadratic processing.
        XCTAssertLessThan(elapsed, 3, "\u{0417}\u{0430}\u{043C}\u{0435}\u{043D}\u{0430} \u{043F}\u{043E} \u{0431}\u{043E}\u{043B}\u{044C}\u{0448}\u{043E}\u{043C}\u{0443} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}\u{0440}\u{044E} \u{0437}\u{0430}\u{043D}\u{044F}\u{043B}\u{0430} \(elapsed) \u{0441}")
    }
}

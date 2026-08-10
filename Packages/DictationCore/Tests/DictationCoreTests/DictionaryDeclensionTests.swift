import XCTest
@testable import DictationCore

/// Replacement of a term in case.
///
/// The Russian word is inflected, but the Latin term is not. The man says "before"
/// release" and waits "before release". Exact match didn't work here
/// never, and the dictionary was silent exactly where it was needed.
final class DictionaryDeclensionTests: XCTestCase {
    private func apply(_ pairs: [(String, String)], to text: String) -> String {
        DictionaryReplacements.apply(
            pairs.map { DictionaryReplacement(spoken: $0.0, written: $0.1) },
            to: text
        )
    }

    func testCasesOfASingleWordTerm() {
        let pairs = [("\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}", "release")]
        XCTAssertEqual(apply(pairs, to: "\u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}"), "\u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C} release")
        XCTAssertEqual(apply(pairs, to: "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{043E}\u{043C}"), "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} release")
        XCTAssertEqual(apply(pairs, to: "\u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0430}"), "\u{043F}\u{043E}\u{0441}\u{043B}\u{0435} release")
        XCTAssertEqual(apply(pairs, to: "\u{0432} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0435}"), "\u{0432} release")
        XCTAssertEqual(apply(pairs, to: "\u{043A} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0443}"), "\u{043A} release")
    }

    func testTermsEndingInShortI() {
        // “Deploy” declines, eating the “th”: deployment, deployment, deployment.
        let pairs = [("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "deploy")]
        XCTAssertEqual(apply(pairs, to: "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}"), "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} deploy")
        XCTAssertEqual(apply(pairs, to: "\u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{044F}"), "\u{043F}\u{043E}\u{0441}\u{043B}\u{0435} deploy")
        XCTAssertEqual(apply(pairs, to: "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{0438}\u{043C}\u{0441}\u{044F} \u{043A} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{044E}"), "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{0438}\u{043C}\u{0441}\u{044F} \u{043A} deploy")
        XCTAssertEqual(apply(pairs, to: "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0435}\u{043C}"), "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} deploy")
    }

    func testPluralsAndCasesTogether() {
        XCTAssertEqual(apply([("\u{0434}\u{043E}\u{043A}\u{0435}\u{0440}", "Docker")], to: "\u{043F}\u{043E}\u{0434}\u{043D}\u{0438}\u{043C}\u{0438} \u{0434}\u{043E}\u{043A}\u{0435}\u{0440}\u{044B}"), "\u{043F}\u{043E}\u{0434}\u{043D}\u{0438}\u{043C}\u{0438} Docker")
        XCTAssertEqual(apply([("\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}", "commit")], to: "\u{0442}\u{0440}\u{0438} \u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}\u{0430} \u{043D}\u{0430}\u{0437}\u{0430}\u{0434}"), "\u{0442}\u{0440}\u{0438} commit \u{043D}\u{0430}\u{0437}\u{0430}\u{0434}")
        XCTAssertEqual(apply([("\u{043F}\u{0438}\u{0442}\u{043E}\u{043D}", "Python")], to: "\u{0431}\u{044D}\u{043A}\u{0435}\u{043D}\u{0434} \u{043D}\u{0430} \u{043F}\u{0438}\u{0442}\u{043E}\u{043D}\u{0435}"), "\u{0431}\u{044D}\u{043A}\u{0435}\u{043D}\u{0434} \u{043D}\u{0430} Python")
        XCTAssertEqual(apply([("\u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}", "downtime")], to: "\u{0431}\u{0435}\u{0437} \u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}\u{0430}"), "\u{0431}\u{0435}\u{0437} downtime")
    }

    func testLastWordOfAPhraseAlsoInflects() {
        let pairs = [("\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", "pull request")]
        XCTAssertEqual(apply(pairs, to: "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}"), "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} pull request")
        XCTAssertEqual(apply(pairs, to: "\u{0436}\u{0434}\u{0443} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}\u{0430}"), "\u{0436}\u{0434}\u{0443} pull request")
        XCTAssertEqual(apply(pairs, to: "\u{0432} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}\u{0435}"), "\u{0432} pull request")
    }

    func testExtraSpacesInsideAPhraseDoNotBreakIt() {
        // Recognition does not promise exactly one space.
        XCTAssertEqual(
            apply([("\u{043A}\u{043E}\u{0434} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "code review")], to: "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043A}\u{043E}\u{0434}  \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}"),
            "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} code review"
        )
    }

    func testUnrelatedWordsWithTheSameBeginningAreLeftAlone() {
        // The main risk of such a replacement is eating someone else's word.
        XCTAssertEqual(apply([("\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}", "release")], to: "\u{0440}\u{0435}\u{043B}\u{0438}\u{0433}\u{0438}\u{044F}"), "\u{0440}\u{0435}\u{043B}\u{0438}\u{0433}\u{0438}\u{044F}")
        XCTAssertEqual(apply([("\u{0431}\u{0438}\u{043B}\u{0434}", "build")], to: "\u{0431}\u{0438}\u{043B}\u{0434}\u{0438}\u{043D}\u{0433}"), "\u{0431}\u{0438}\u{043B}\u{0434}\u{0438}\u{043D}\u{0433}")
        XCTAssertEqual(apply([("\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}", "commit")], to: "\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}\u{0438}\u{0442}\u{044C}"), "\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}\u{0438}\u{0442}\u{044C}")
        XCTAssertEqual(apply([("\u{0434}\u{043E}\u{043A}\u{0435}\u{0440}", "Docker")], to: "\u{0434}\u{043E}\u{043A}\u{0435}\u{0440}\u{0444}\u{0430}\u{0439}\u{043B}"), "\u{0434}\u{043E}\u{043A}\u{0435}\u{0440}\u{0444}\u{0430}\u{0439}\u{043B}")
    }

    func testShortTermsStayExact() {
        // In short words, the tail too often turns out to be the beginning of another.
        XCTAssertEqual(apply([("\u{0430}\u{043F}\u{0438}", "API")], to: "\u{0430}\u{043F}\u{0438} \u{043E}\u{0442}\u{0434}\u{0430}\u{0451}\u{0442} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442}"), "API \u{043E}\u{0442}\u{0434}\u{0430}\u{0451}\u{0442} \u{043E}\u{0442}\u{0432}\u{0435}\u{0442}")
        XCTAssertEqual(apply([("\u{0430}\u{043F}\u{0438}", "API")], to: "\u{0430}\u{043F}\u{0438}\u{043D}\u{043E}\u{0439}"), "\u{0430}\u{043F}\u{0438}\u{043D}\u{043E}\u{0439}")
    }

    func testLatinTermsAreNotGivenRussianEndings() {
        // English words in Russian speech are not declined, and there is an extra tail there
        // would mean a completely different word.
        XCTAssertEqual(apply([("swift", "Swift")], to: "swifty"), "swifty")
        XCTAssertEqual(apply([("swift", "Swift")], to: "\u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{043D}\u{0430} swift"), "\u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{043D}\u{0430} Swift")
    }

    func testStarterDictionaryCoversWhatTheModelActuallyProduces() {
        // The lines are taken from an actual model run, not made up.
        let measured = [
            ("\u{041E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0438}\u{0441}\u{0442} \u{043D}\u{0430} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "pull request"),
            ("\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043A}\u{043E}\u{0442} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", "code review"),
            ("\u{0437}\u{0430}\u{0434}\u{0430}\u{0447}\u{0430} \u{0432} \u{0433}\u{0438}\u{0442}\u{0445}\u{0435}\u{0431}", "GitHub"),
            ("\u{0431}\u{0430}\u{0437}\u{044B} \u{0434}\u{0430}\u{043D}\u{043D}\u{044B}\u{0445} \u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0438}\u{0437}", "Postgres"),
            ("\u{0432}\u{044B}\u{043A}\u{0430}\u{0442}\u{0438} \u{0445}\u{043E}\u{0434} \u{0444}\u{0438}\u{043A}\u{0441}", "hotfix"),
            ("\u{0444}\u{0440}\u{043E}\u{043D}\u{0442}\u{0438}\u{043D}\u{0433} \u{043D}\u{0430} \u{0442}\u{0430}\u{0439}\u{043F}-\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}\u{0435}", "TypeScript"),
            ("\u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043D}\u{043E} \u{043D}\u{0430} \u{0441}\u{0432}\u{0438}\u{0444}\u{0442}\u{0435}", "Swift"),
        ]

        for (heard, expected) in measured {
            let result = DictionaryReplacements.apply(StarterDictionary.developer, to: heard)
            XCTAssertTrue(
                result.contains(expected),
                "«\(heard)» \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{043E} \u{0434}\u{0430}\u{0442}\u{044C} «\(expected)», \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} «\(result)»"
            )
        }
    }
}

/// Declinability is a property of a record, not an inference from its letters.
final class DictionaryInflectionFlagTests: XCTestCase {
    func testReplacementMarkedLiteralTakesNoCaseEndings() {
        // “Comet” is not a word, but a recognition error. He has no cases, but
        // the inflected stem “comets-” ate “comet”.
        let literal = [DictionaryReplacement(spoken: "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}", written: "commit", inflects: false)]
        XCTAssertEqual(
            DictionaryReplacements.apply(literal, to: "\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}\u{043B}\u{0438} \u{043D}\u{0430} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0443}"),
            "\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}\u{043B}\u{0438} \u{043D}\u{0430} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0443}"
        )
        XCTAssertEqual(
            DictionaryReplacements.apply(literal, to: "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}"),
            "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} commit"
        )
    }

    func testReplacementsInflectByDefault() {
        // Silently changing the behavior of all user dictionaries would be
        // worse than the original disaster.
        let usual = [DictionaryReplacement(spoken: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", written: "deploy")]
        XCTAssertTrue(usual[0].inflects)
        XCTAssertEqual(
            DictionaryReplacements.apply(usual, to: "\u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{044F}"),
            "\u{043F}\u{043E}\u{0441}\u{043B}\u{0435} deploy"
        )
    }

    func testDictionariesSavedBeforeTheFlagExistedStillInflect() throws {
        // People have dictionaries on their disks without this key. His absence
        // means “leans” - exactly how these dictionaries worked.
        let saved = Data("""
            [{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spoken":"\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}","written":"release"}]
            """.utf8)

        let decoded = try JSONDecoder().decode([DictionaryReplacement].self, from: saved)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(decoded[0].inflects)
        XCTAssertEqual(
            DictionaryReplacements.apply(decoded, to: "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{043E}\u{043C}"),
            "\u{043F}\u{0435}\u{0440}\u{0435}\u{0434} release"
        )
    }

    func testFlagSurvivesSavingAndLoading() throws {
        let original = [DictionaryReplacement(spoken: "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}", written: "commit", inflects: false)]
        let restored = try JSONDecoder().decode(
            [DictionaryReplacement].self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(restored, original)
        XCTAssertFalse(restored[0].inflects)
    }
}

/// What a dictionary cannot do—and should not try.
final class DictionaryAmbiguityTests: XCTestCase {
    func testOrdinaryRussianWordsAreNotSacrificedForTerms() {
        // The model writes "Sentry" as "centre", but "centre" is regular Russian
        // word. Replacing it with Sentry means breaking normal speech for the sake of
        // one term.
        let result = DictionaryReplacements.apply(
            StarterDictionary.developer,
            to: "\u{0432}\u{0441}\u{0442}\u{0440}\u{0435}\u{0442}\u{0438}\u{043C}\u{0441}\u{044F} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}"
        )

        XCTAssertEqual(result, "\u{0432}\u{0441}\u{0442}\u{0440}\u{0435}\u{0442}\u{0438}\u{043C}\u{0441}\u{044F} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}")
    }

    func testStarterSetShipsNoReplacementThatIsAnOrdinaryRussianWord() {
        // The workpiece is offered to everyone indiscriminately, so the entry that matches
        // with an ordinary word, it breaks everyone’s speech. His replacement is a man
        // starts it himself and knows what he's getting into.
        //
        // The list was obtained by brute force: for each entry all spellings with
        // real Russian words were selected using the same phonetic key.
        let ordinary = ["\u{043F}\u{0438}\u{0442}\u{043E}\u{043D}", "\u{0440}\u{0435}\u{0434}\u{0438}\u{0441}", "\u{0434}\u{043E}\u{043A}\u{0435}\u{0440}", "\u{0431}\u{0440}\u{0430}\u{043D}\u{0447}"]
        let shipped = Set(StarterDictionary.developer.map { $0.spoken.lowercased() })

        for word in ordinary {
            XCTAssertFalse(shipped.contains(word), "«\(word)» — \u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{043E}\u{0435} \u{0440}\u{0443}\u{0441}\u{0441}\u{043A}\u{043E}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E}")
        }
    }
}

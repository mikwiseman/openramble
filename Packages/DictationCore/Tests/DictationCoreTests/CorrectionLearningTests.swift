import XCTest
@testable import DictationCore

/// Rules for learning a dictionary for editing the last dictation.
///
/// A person edits the text in our window - diff suggests replacements. Rules
/// intentionally conservative: learning garbage is worse than learning nothing,
/// because a bad replacement breaks future dictations silently.
final class CorrectionLearningTests: XCTestCase {
    func testScenario001() {
        // Main scenario: the model heard the term in Cyrillic, human
        // corrected to Latin. This is exactly what should be included in the dictionary.
        let proposals = CorrectionLearning.propose(
            original: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C} \u{0438}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}\u{044B}.",
            edited: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C} \u{0438}\u{043D}\u{0434}\u{0435}\u{043A}\u{0441}\u{044B}."
        )

        XCTAssertEqual(proposals.map(\.spoken), ["\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}"])
        XCTAssertEqual(proposals.map(\.written), ["Postgres"])
    }

    func testScenario002() {
        // “Fast” → “faster” is an edit of speech, not a term. Learn this
        // means replacing a person’s words in subsequent dictations.
        let proposals = CorrectionLearning.propose(
            original: "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{044D}\u{0442}\u{043E} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{043E} \u{0438} \u{0430}\u{043A}\u{043A}\u{0443}\u{0440}\u{0430}\u{0442}\u{043D}\u{043E}.",
            edited: "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{044D}\u{0442}\u{043E} \u{0431}\u{044B}\u{0441}\u{0442}\u{0440}\u{0435}\u{0435} \u{0438} \u{0430}\u{043A}\u{043A}\u{0443}\u{0440}\u{0430}\u{0442}\u{043D}\u{043E}."
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testScenario003() {
        // “github” → “GitHub” - brand spelling. This is a dictionary correction.
        let proposals = CorrectionLearning.propose(
            original: "\u{0417}\u{0430}\u{0433}\u{0440}\u{0443}\u{0437}\u{0438} \u{0432} github \u{0432}\u{0435}\u{0442}\u{043A}\u{0443}.",
            edited: "\u{0417}\u{0430}\u{0433}\u{0440}\u{0443}\u{0437}\u{0438} \u{0432} GitHub \u{0432}\u{0435}\u{0442}\u{043A}\u{0443}."
        )

        XCTAssertEqual(proposals.map(\.spoken), ["github"])
        XCTAssertEqual(proposals.map(\.written), ["GitHub"])
    }

    func testScenario004() {
        let existing = [DictionaryReplacement(spoken: "\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", written: "Postgres")]

        let proposals = CorrectionLearning.propose(
            original: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}.",
            edited: "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}.",
            existing: existing
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testScenario005() {
        let proposals = CorrectionLearning.propose(
            original: "\u{0421}\u{043A}\u{0438}\u{043D}\u{044C} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442} \u{0432} \u{0433}\u{0438}\u{0442} \u{0445}\u{0430}\u{0431}.",
            edited: "\u{0421}\u{043A}\u{0438}\u{043D}\u{044C} pull request \u{0432} GitHub."
        )

        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals[0].spoken, "\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}")
        XCTAssertEqual(proposals[0].written, "pull request")
        XCTAssertEqual(proposals[1].spoken, "\u{0433}\u{0438}\u{0442} \u{0445}\u{0430}\u{0431}")
        XCTAssertEqual(proposals[1].written, "GitHub")
    }

    func testScenario006() {
        let proposals = CorrectionLearning.propose(
            original: "\u{041D}\u{0443} \u{0432}\u{043E}\u{0442} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{044D}\u{0442}\u{043E} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}.",
            edited: "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{044D}\u{0442}\u{043E} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}."
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testScenario007() {
        XCTAssertTrue(CorrectionLearning.propose(original: "", edited: "").isEmpty)
        XCTAssertTrue(
            CorrectionLearning.propose(
                original: "\u{041E}\u{0434}\u{0438}\u{043D} \u{0438} \u{0442}\u{043E}\u{0442} \u{0436}\u{0435} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}.",
                edited: "\u{041E}\u{0434}\u{0438}\u{043D} \u{0438} \u{0442}\u{043E}\u{0442} \u{0436}\u{0435} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}."
            ).isEmpty
        )
    }

    func testScenario008() {
        // The same prohibition as for “quickly” → “faster”, but in the text, where
        // Latin alphabet is on both sides. Previously, the sign of the term was considered
        // “there is a Latin alphabet on the right” - in the English text it did not mean anything, and
        // any word edits fell through here.
        for (original, edited) in [
            ("please send me the file", "please send me a file"),
            ("the quick brown fox jumps", "the slow brown fox jumps"),
            ("I went to the store today", "I ran to the store today"),
        ] {
            XCTAssertTrue(
                CorrectionLearning.propose(original: original, edited: edited).isEmpty,
                "\u{041F}\u{0440}\u{0430}\u{0432}\u{043A}\u{0430} \u{0440}\u{0435}\u{0447}\u{0438} «\(original)» → «\(edited)» \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{0437}\u{0430}\u{043C}\u{0435}\u{043D}\u{043E}\u{0439}"
            )
        }
    }

    func testScenario009() {
        // The cost of an error for which the filter exists: one edit of “the” →
        // “a” rewrote each subsequent dictation.
        let learned = CorrectionLearning.propose(
            original: "please send me the file",
            edited: "please send me a file"
        )
        let text = TextPipeline(replacements: learned).process("The report is on the desk").text

        XCTAssertEqual(text, "The report is on the desk")
    }

    func testScenario010() {
        // Rearranging capitalization when moving words inside a paragraph gave a pair
        // "The" → "the" along with its opposite "the" → "The": two
        // rules that argue with each other in every future dictation.
        let proposals = CorrectionLearning.propose(
            original: "The file is ready. the build passed.",
            edited: "the file is ready. The build passed."
        )

        XCTAssertTrue(proposals.isEmpty)
    }

    func testScenario011() {
        // There is formally a change in writing, but there is no term, but there is a change throughout
        // the text is worth more than any benefit.
        let proposals = CorrectionLearning.propose(original: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}", edited: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} a")

        XCTAssertTrue(proposals.isEmpty)
    }

    func testScenario012() {
        // The only sign of a term that works in the entire text
        // in Latin: capital is not at the beginning of the word.
        for (spoken, written) in [("api", "API"), ("iphone", "iPhone"), ("mac os", "macOS")] {
            let proposals = CorrectionLearning.propose(
                original: "open \(spoken) now",
                edited: "open \(written) now"
            )
            XCTAssertEqual(proposals.map(\.written), [written], "«\(spoken)» → «\(written)»")
        }
    }

    func testScenario013() {
        let proposals = CorrectionLearning.propose(
            original: "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438} \u{0438} \u{0437}\u{0430}\u{043A}\u{0440}\u{043E}\u{0439} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}",
            edited: "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Sentry \u{0438} \u{0437}\u{0430}\u{043A}\u{0440}\u{043E}\u{0439} Sentry"
        )

        XCTAssertEqual(proposals.count, 1, "\u{0414}\u{0443}\u{0431}\u{043B}\u{0438}\u{043A}\u{0430}\u{0442} \u{0432} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}\u{0440}\u{0435} \u{0447}\u{0435}\u{043B}\u{043E}\u{0432}\u{0435}\u{043A}\u{0443} \u{043F}\u{0440}\u{0438}\u{0434}\u{0451}\u{0442}\u{0441}\u{044F} \u{0443}\u{0434}\u{0430}\u{043B}\u{044F}\u{0442}\u{044C} \u{043E}\u{0442}\u{0434}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E}")
        XCTAssertEqual(proposals.map(\.spoken), ["\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}"])
    }

    func testScenario014() {
        // Not editing terms, but different text: anchor words are in place, but between
        // everything is replaced by them. Set so many silent rules at once
        // irreversible - it’s more honest to learn nothing.
        var original = ""
        var edited = ""
        for index in 0..<40 {
            original += "\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}\(index) sep "
            edited += "Term\(index)X sep "
        }

        XCTAssertTrue(CorrectionLearning.propose(original: original, edited: edited).isEmpty)
    }

    func testScenario015() {
        // The border should skip the actual edit: five terms in a row -
        // still editing, not replacing text.
        var original = ""
        var edited = ""
        for index in 0..<CorrectionLearning.maximumProposalsPerCorrection {
            original += "\u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\(index) sep "
            edited += "Term\(index)X sep "
        }

        XCTAssertEqual(
            CorrectionLearning.propose(original: original, edited: edited).count,
            CorrectionLearning.maximumProposalsPerCorrection
        )
    }

    func testScenario016() {
        // “sentry” → “center”-like pairs without Latin letters do not pass the filter:
        // without the “this is a term” signal, the chance of learning a regular edit is too high.
        let proposals = CorrectionLearning.propose(
            original: "\u{041C}\u{044B} \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}\u{043B}\u{0438} \u{0432} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438} \u{0432}\u{0447}\u{0435}\u{0440}\u{0430}.",
            edited: "\u{041C}\u{044B} \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}\u{043B}\u{0438} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0432}\u{0447}\u{0435}\u{0440}\u{0430}."
        )

        XCTAssertTrue(proposals.isEmpty)
    }
}

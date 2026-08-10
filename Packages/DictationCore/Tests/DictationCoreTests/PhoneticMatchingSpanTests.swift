import XCTest
@testable import DictationCore

/// Splitting the dictionary into exact and phonetic passages.
///
/// Service splitting: span detection comes between the passes. Therefore
/// the main thing here is to prove that the splitting itself did not change anything.
final class DictionaryPassSplitTests: XCTestCase {
    private let dictionary = [
        DictionaryReplacement(spoken: "\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", written: "Postgres", inflects: false),
        DictionaryReplacement(spoken: "\u{043A}\u{043E}\u{0434}", written: "code", inflects: false),
        DictionaryReplacement(spoken: "\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", written: "pull request", inflects: false),
    ]

    func testExactPassAloneEqualsThePipelineWithPhoneticOff() {
        let corpus = [
            "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}",
            "\u{044D}\u{0442}\u{043E} \u{043A}\u{043E}\u{0434}, \u{0430} \u{044D}\u{0442}\u{043E} \u{043A}\u{043E}\u{0434}\u{0438}\u{0440}\u{043E}\u{0432}\u{043A}\u{0430}",
            "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}",
            "\u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{0430}\u{044F} \u{0440}\u{0443}\u{0441}\u{0441}\u{043A}\u{0430}\u{044F} \u{0444}\u{0440}\u{0430}\u{0437}\u{0430} \u{0431}\u{0435}\u{0437} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\u{043E}\u{0432}",
            "",
        ]
        for text in corpus {
            XCTAssertEqual(
                DictionaryReplacements.applyExact(dictionary, to: text),
                DictionaryReplacements.apply(dictionary, to: text, phoneticMatching: false),
                "\u{0440}\u{0430}\u{0441}\u{0449}\u{0435}\u{043F}\u{043B}\u{0435}\u{043D}\u{0438}\u{0435} \u{043D}\u{0435} \u{0438}\u{043C}\u{0435}\u{0435}\u{0442} \u{043F}\u{0440}\u{0430}\u{0432}\u{0430} \u{043C}\u{0435}\u{043D}\u{044F}\u{0442}\u{044C} \u{0442}\u{043E}\u{0447}\u{043D}\u{044B}\u{0439} \u{043F}\u{0440}\u{043E}\u{0445}\u{043E}\u{0434}"
            )
        }
    }

    func testFacadeStillEqualsExactThenPhonetic() {
        let text = "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}"
        let manual = DictionaryReplacements.applyPhonetic(
            dictionary,
            to: DictionaryReplacements.applyExact(dictionary, to: text),
            protecting: []
        )
        XCTAssertEqual(DictionaryReplacements.apply(dictionary, to: text), manual)
    }

    /// An empty set of spans must give exactly the same result.
    ///
    /// The matcher is greedy, and its behavior is emergent: the shift here would not be noticeable
    /// eye, but would ruin every second dictation. We're racing at full throttle
    /// dictionary, and not on three pairs.
    func testEmptySpanSetChangesNothing() {
        let starter = StarterDictionary.developer
        let corpus = [
            "\u{043D}\u{0430}\u{0434}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439} \u{043D}\u{0430} \u{0441}\u{0435}\u{0440}\u{0432}\u{0435}\u{0440}",
            "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} \u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{044D}\u{043A}\u{0440}\u{0430}\u{043D}\u{0430}",
            "\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442} \u{0443}\u{0436}\u{0435} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}, \u{0430} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0430} \u{043D}\u{0435}\u{0442}",
            "\u{0434}\u{0436}\u{0430}\u{0432}\u{0430} \u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442} \u{0438} \u{0434}\u{0436}\u{0430}\u{0432}\u{0430}\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442} — \u{043E}\u{0434}\u{043D}\u{043E} \u{0438} \u{0442}\u{043E} \u{0436}\u{0435}",
            "\u{0443} \u{043D}\u{0430}\u{0441} \u{0434}\u{0430}\u{0443}\u{043D} \u{0442}\u{0430}\u{0439}\u{043C} \u{0441} \u{0443}\u{0442}\u{0440}\u{0430}",
            "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}? \u{0421}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{0445}\u{043E}\u{0440}\u{043E}\u{0448}\u{0430}\u{044F} \u{043F}\u{043E}\u{0433}\u{043E}\u{0434}\u{0430}.",
        ]
        for text in corpus {
            XCTAssertEqual(
                PhoneticMatching.apply(starter, to: text, protecting: []),
                PhoneticMatching.apply(starter, to: text),
                "\u{043F}\u{0443}\u{0442}\u{044C} \u{0431}\u{0435}\u{0437} \u{0441}\u{043F}\u{0430}\u{043D}\u{043E}\u{0432} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{043D}\u{0435}\u{043E}\u{0442}\u{043B}\u{0438}\u{0447}\u{0438}\u{043C} \u{043E}\u{0442} \u{043F}\u{0440}\u{0435}\u{0436}\u{043D}\u{0435}\u{0433}\u{043E}"
            )
        }
    }
}

/// Phonetic selection and protected spans are collision fixtures.
final class PhoneticMatchingSpanTests: XCTestCase {
    /// “sentry” is phonetically close to Sentry - this makes the fixture a collision.
    private let dictionary = [
        DictionaryReplacement(spoken: "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", written: "Sentry", inflects: false)
    ]

    private func phonetic(_ text: String) -> String {
        let spans = ProtectedSpanDetector.detect(in: text)
        return DictionaryReplacements.applyPhonetic(dictionary, to: text, protecting: spans)
    }

    /// Collision 1: dictionary term inside backticks.
    func testPhoneticDoesNotFireInsideBackticks() {
        let result = phonetic("\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} `\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}` \u{0438} \u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}")
        XCTAssertTrue(result.contains("`\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}`"), "\u{0432}\u{043D}\u{0443}\u{0442}\u{0440}\u{0438} \u{0431}\u{044D}\u{043A}\u{0442}\u{0438}\u{043A}\u{043E}\u{0432} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043A}\u{0430}\u{043A} \u{0435}\u{0441}\u{0442}\u{044C}")
        XCTAssertTrue(result.contains("\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} Sentry"), "\u{0441}\u{043D}\u{0430}\u{0440}\u{0443}\u{0436}\u{0438} — \u{0437}\u{0430}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}")
    }

    /// Collision 2: phonetic neighbor inside the path.
    func testPhoneticDoesNotFireInsideAPath() {
        let result = phonetic("\u{043B}\u{0435}\u{0436}\u{0438}\u{0442} \u{0432} /Users/mik/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/log")
        XCTAssertEqual(result, "\u{043B}\u{0435}\u{0436}\u{0438}\u{0442} \u{0432} /Users/mik/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/log")
    }

    /// A window of three words has no right to step over the span.
    func testPhoneticWindowNeverStraddlesASpanBoundary() {
        let terms = [DictionaryReplacement(spoken: "\u{0434}\u{0430}\u{0443}\u{043D} \u{0442}\u{0430}\u{0439}\u{043C}", written: "downtime", inflects: false)]
        let text = "\u{0431}\u{044B}\u{043B} \u{0434}\u{0430}\u{0443}\u{043D} `\u{043A}\u{043E}\u{0434}` \u{0442}\u{0430}\u{0439}\u{043C} \u{0432}\u{0447}\u{0435}\u{0440}\u{0430}"
        let spans = ProtectedSpanDetector.detect(in: text)
        let result = DictionaryReplacements.applyPhonetic(terms, to: text, protecting: spans)
        XCTAssertEqual(result, text, "\u{0447}\u{0435}\u{0440}\u{0435}\u{0437} \u{0437}\u{0430}\u{0449}\u{0438}\u{0449}\u{0451}\u{043D}\u{043D}\u{044B}\u{0439} \u{043A}\u{0443}\u{0441}\u{043E}\u{043A} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D} \u{043D}\u{0435} \u{0441}\u{043E}\u{0431}\u{0438}\u{0440}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
    }

    /// Exact replacement is the explicit will of a person, and it is above the protection of span.
    ///
    /// It works not by the priority rule, but by order: the exact pass is processed
    /// before the spans are even counted.
    func testExactReplacementOutranksSpanProtection() {
        let text = "\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} `\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}` \u{0442}\u{0443}\u{0442}"
        let afterExact = DictionaryReplacements.applyExact(dictionary, to: text)
        XCTAssertEqual(afterExact, "\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} `Sentry` \u{0442}\u{0443}\u{0442}")
    }

    /// Spans are recalculated after exact replacement, and are not taken from the raw text.
    func testSpansAreRecomputedAfterTheExactPass() {
        let terms = [DictionaryReplacement(spoken: "\u{043F}\u{0443}\u{0442}\u{044C}", written: "/etc/hosts", inflects: false)]
        let afterExact = DictionaryReplacements.applyExact(terms, to: "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{0443}\u{0442}\u{044C} \u{0441}\u{043A}\u{043E}\u{0440}\u{0435}\u{0435}")
        XCTAssertEqual(afterExact, "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} /etc/hosts \u{0441}\u{043A}\u{043E}\u{0440}\u{0435}\u{0435}")
        XCTAssertEqual(
            ProtectedSpanDetector.detect(in: afterExact).map(\.kind), [.path],
            "\u{0437}\u{0430}\u{043C}\u{0435}\u{043D}\u{0430} \u{043F}\u{043E}\u{0440}\u{043E}\u{0434}\u{0438}\u{043B}\u{0430} \u{043F}\u{0443}\u{0442}\u{044C} — \u{043E}\u{043D} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0441}\u{0442}\u{0430}\u{0442}\u{044C} \u{0441}\u{043F}\u{0430}\u{043D}\u{043E}\u{043C}"
        )
    }
}

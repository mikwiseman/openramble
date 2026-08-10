import XCTest
@testable import DictationCore

/// Training on edits and protected spans.
///
/// Editing inside the code is editing the code, not the term. Turn it into
/// the silent rule of future dictations is impossible: the person was repairing a specific line,
/// rather than teaching the application the language.
final class CorrectionLearningSpanTests: XCTestCase {
    func testProposalsAreNeverBuiltFromTextInsideASpan() {
        let inserted = "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}` \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"
        let spans = ProtectedSpanDetector.detect(in: inserted)
        XCTAssertEqual(spans.map(\.kind), [.backticks], "\u{043F}\u{0440}\u{0435}\u{0434}\u{0443}\u{0441}\u{043B}\u{043E}\u{0432}\u{0438}\u{0435} \u{0442}\u{0435}\u{0441}\u{0442}\u{0430}")

        let proposals = CorrectionLearning.propose(
            original: inserted,
            edited: "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} `Sentry` \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}",
            protecting: spans
        )
        XCTAssertTrue(proposals.isEmpty, "\u{043F}\u{0440}\u{0430}\u{0432}\u{043A}\u{0430} \u{0432}\u{043D}\u{0443}\u{0442}\u{0440}\u{0438} \u{0431}\u{044D}\u{043A}\u{0442}\u{0438}\u{043A}\u{043E}\u{0432} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\u{0430} \u{043D}\u{0435} \u{0434}\u{0435}\u{043B}\u{0430}\u{0435}\u{0442}")
    }

    func testPathEditsDoNotTeachTheDictionary() {
        let inserted = "\u{043B}\u{0435}\u{0436}\u{0438}\u{0442} \u{0432} /Users/mik/\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}/log"
        let proposals = CorrectionLearning.propose(
            original: inserted,
            edited: "\u{043B}\u{0435}\u{0436}\u{0438}\u{0442} \u{0432} /Users/mik/sentry/log",
            protecting: ProtectedSpanDetector.detect(in: inserted)
        )
        XCTAssertTrue(proposals.isEmpty)
    }

    /// The same edit outside of span teaches as before - otherwise the test above would have passed
    /// and “training is completely broken.”
    func testTheSameEditOutsideASpanStillTeaches() {
        let inserted = "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438} \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}"
        let proposals = CorrectionLearning.propose(
            original: inserted,
            edited: "\u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438} Sentry \u{0441}\u{0435}\u{0439}\u{0447}\u{0430}\u{0441}",
            protecting: ProtectedSpanDetector.detect(in: inserted)
        )
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.spoken, "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}")
        XCTAssertEqual(proposals.first?.written, "Sentry")
    }

    /// Defaulting to an empty list keeps the previous behavior.
    ///
    /// Pairs are compared, not entire structures: `id` - fresh UUID for each
    /// call, and there will never be equality of structures.
    func testWithoutSpansProposalsAreExactlyWhatTheyWere() {
        let original = "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437} \u{0438} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}"
        let edited = "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres \u{0438} Sentry"
        let pairs = { (proposals: [DictionaryReplacement]) in
            proposals.map { [$0.spoken, $0.written, "\($0.inflects)"] }
        }
        XCTAssertEqual(
            pairs(CorrectionLearning.propose(original: original, edited: edited)),
            pairs(CorrectionLearning.propose(original: original, edited: edited, protecting: []))
        )
    }
}

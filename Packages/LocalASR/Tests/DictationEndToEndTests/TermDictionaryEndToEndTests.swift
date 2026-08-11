import DictationCore
import Foundation
import XCTest

/// Starting dictionary on the real output of the model.
///
/// The main end-to-end test shows that the chain works. This one shows on
/// how many terms does the promise itself hold: “said in English - received”
/// in Latin." You can’t check this in parts: the dictionary is assembled based on the output of the model,
/// and the “correctness” of the replacement exists only with it.
@MainActor
final class TermDictionaryEndToEndTests: EndToEndScenario {
    private struct Probe {
        let phrase: String
        /// Terms that reach the insertion in Latin.
        let converted: [String]
        /// Terms that the set does not take, and how the model hears them.
        let gaps: [(term: String, heard: String)]

        init(_ phrase: String, converted: [String] = [], gaps: [(term: String, heard: String)] = []) {
            self.phrase = phrase
            self.converted = converted
            self.gaps = gaps
        }
    }

    /// Eleven phrases with developer terms - all the way to insertion.
    ///
    /// Known unresolved terms are marked with `XCTExpectFailure`. This is not fitting
    /// an expectation to a model: the expectation remains the product promise (“said
    /// Sentry, got Sentry”), while each measured gap stays visible without hiding
    /// regressions in terms that already work.
    func testStarterDictionaryOnRealModelOutput() async throws {
        let probes = [
            Probe("\u{0421}\u{043E}\u{0431}\u{0435}\u{0440}\u{0438} build \u{0438} \u{0432}\u{044B}\u{043B}\u{043E}\u{0436}\u{0438} release.", converted: ["build", "release"]),
            Probe(
                "\u{041C}\u{044B} \u{043F}\u{0438}\u{0448}\u{0435}\u{043C} \u{043D}\u{0430} Swift, \u{0430} \u{0440}\u{0430}\u{043D}\u{044C}\u{0448}\u{0435} \u{043F}\u{0438}\u{0441}\u{0430}\u{043B}\u{0438} \u{043D}\u{0430} TypeScript.",
                converted: ["Swift", "TypeScript"]
            ),
            Probe("\u{042D}\u{0442}\u{043E}\u{0442} PR \u{044F} \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{044E} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0431}\u{0435}\u{0434}\u{0430}.", converted: ["PR"]),
            Probe("\u{0412}\u{044B}\u{043A}\u{0430}\u{0442}\u{0438} rollback \u{0431}\u{0435}\u{0437} downtime.", converted: ["rollback", "downtime"]),
            Probe(
                "\u{0412}\u{043A}\u{043B}\u{044E}\u{0447}\u{0438} feature flag \u{043D}\u{0430} staging.",
                converted: ["feature flag", "staging"]
            ),
            Probe(
                "\u{042F} \u{043F}\u{043E}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043B} backend \u{043D}\u{0430} Python, \u{0434}\u{043E}\u{0431}\u{0430}\u{0432}\u{0438}\u{043B} endpoint \u{0438} \u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043B} hotfix.",
                converted: ["backend", "endpoint", "hotfix"],
                gaps: [
                    // Not a dictionary hole, but a loss of a word: instead of the term model
                    // I heard another Russian word - “written”. This is not a replacement
                    // is being repaired, and the “python” entry has been removed from the set: on fresh ones
                    // it never worked in the records, but it converted
                    // "python compressed prey" in "Python compressed prey."
                    ("Python", "\u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043D}"),
                ]
            ),
            Probe(
                "\u{041E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{043F}\u{0440}\u{0438}\u{043B}\u{0435}\u{0442}\u{0435}\u{043B}\u{0430} \u{0432} Sentry, \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} \u{043B}\u{043E}\u{0433}\u{0438} \u{0432} Docker \u{0438} \u{0432} Kubernetes.",
                converted: ["Docker", "Kubernetes"],
                gaps: [
                    // Conscious refusal, recorded in docs/benchmarks.md: “center” -
                    // an ordinary Russian word, and the replacement would break “in the city center.”
                    ("Sentry", "\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}"),
                ]
            ),
            Probe(
                "\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} commit \u{0432} branch, \u{043F}\u{043E}\u{0442}\u{043E}\u{043C} rebase \u{0438} merge.",
                converted: ["commit", "branch", "rebase", "merge"]
            ),
            Probe(
                "\u{0414}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435} \u{0432} Postgres, \u{043A}\u{044D}\u{0448} \u{0432} Redis.",
                converted: ["Postgres", "Redis"]
            ),
            Probe("\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Xcode \u{0438} \u{0441}\u{043E}\u{0431}\u{0435}\u{0440}\u{0438} \u{043F}\u{0440}\u{043E}\u{0435}\u{043A}\u{0442}.", converted: ["Xcode"]),
            Probe("\u{0421}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} code review \u{0434}\u{043E} \u{043E}\u{0431}\u{0435}\u{0434}\u{0430}.", converted: ["code review"]),
        ]

        var report: [String] = []

        for probe in probes {
            let text = try await dictated(probe.phrase)
            report.append("  \u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{043D}\u{043E}:  \(probe.phrase)")
            report.append("  \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{0435}\u{043D}\u{043E}: \(text)")

            for term in probe.converted {
                XCTAssertTrue(
                    text.contains(term),
                    "\u{0422}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D} «\(term)» \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{0451}\u{043B} \u{043B}\u{0430}\u{0442}\u{0438}\u{043D}\u{0438}\u{0446}\u{0435}\u{0439}. \u{041F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(text)"
                )
            }

            for gap in probe.gaps {
                XCTExpectFailure(
                    "«\(gap.term)» \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C} \u{043F}\u{0438}\u{0448}\u{0435}\u{0442} \u{043A}\u{0430}\u{043A} «\(gap.heard)» — \u{0442}\u{0430}\u{043A}\u{043E}\u{0433}\u{043E} \u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043D}\u{0438}\u{044F} \u{0432} \u{043D}\u{0430}\u{0431}\u{043E}\u{0440}\u{0435} \u{043D}\u{0435}\u{0442}"
                ) {
                    XCTAssertTrue(
                        text.contains(gap.term),
                        "«\(gap.term)» \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{0451}\u{043B} \u{043B}\u{0430}\u{0442}\u{0438}\u{043D}\u{0438}\u{0446}\u{0435}\u{0439}. \u{041F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(text)"
                    )
                }
            }
        }

        let hits = probes.reduce(0) { $0 + $1.converted.count }
        let misses = probes.reduce(0) { $0 + $1.gaps.count }
        print("\n\u{0421}\u{0442}\u{0430}\u{0440}\u{0442}\u{043E}\u{0432}\u{044B}\u{0439} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430}\u{0440}\u{044C} \u{043D}\u{0430} \u{0432}\u{044B}\u{0445}\u{043E}\u{0434}\u{0435} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438}: \(hits) \u{0438}\u{0437} \(hits + misses) \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\u{043E}\u{0432} \u{043B}\u{0430}\u{0442}\u{0438}\u{043D}\u{0438}\u{0446}\u{0435}\u{0439}\n")
        print(report.joined(separator: "\n"))
        print("")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - One run of the phrase

    private func dictated(
        _ phrase: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        try await speak(phrase)
        let controller = makeController()
        let before = await inserter.texts.count

        await dictate(with: controller, file: file, line: line)

        let texts = await inserter.texts
        XCTAssertEqual(
            texts.count,
            before + 1,
            "\u{0424}\u{0440}\u{0430}\u{0437}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{043B}\u{0430} \u{0434}\u{043E} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438}: \(phrase)",
            file: file,
            line: line
        )
        return try XCTUnwrap(texts.last, file: file, line: line)
    }
}

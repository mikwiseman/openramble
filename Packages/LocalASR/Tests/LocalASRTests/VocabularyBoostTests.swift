import DictationCore
import XCTest
@testable import LocalASR

/// Rules for preparing a list of terms for the recognition hint.
///
/// No model needed here: this is pure normalization. The mistakes in it are quiet -
/// a duplicate or an empty line does not damage recognition, but simply spoils it
/// quality of hints, - therefore the rules are fixed by tests.
final class VocabularyBoostTests: XCTestCase {
    func testScenario001() {
        let boost = VocabularyBoost(terms: [.init(text: "deploy"), .init(text: ""), .init(text: "   "), .init(text: "GitHub")])

        XCTAssertEqual(boost.terms.map(\.text), ["deploy", "GitHub"])
    }

    func testScenario002() {
        // One term with two spellings is one term: spot model searches
        // acoustic body, not register. The first spelling wins
        // because it was the person who entered it first.
        let boost = VocabularyBoost(terms: [.init(text: "GitHub"), .init(text: "github"), .init(text: "Deploy"), .init(text: "deploy")])

        XCTAssertEqual(boost.terms.map(\.text), ["GitHub", "Deploy"])
    }

    func testScenario003() {
        let boost = VocabularyBoost(terms: [.init(text: "  pull request  ")])

        XCTAssertEqual(boost.terms.map(\.text), ["pull request"])
    }

    func testScenario004() {
        let boost = VocabularyBoost(terms: [])

        XCTAssertTrue(boost.terms.isEmpty)
        XCTAssertTrue(boost.isEmpty)
    }

    /// A ready-made set for the developer's dictionary is assembled from the replacement dictionary,
    /// but three terms never fall into it: the hinter sees the similarity
    /// through alphabets, and “deploy” caught “warm”, “Sentry” - “in the center”,
    /// “commit” - “comet”. Measurement - in docs/benchmarks.md; the test holds the output.
    func testScenario005() {
        let boost = VocabularyBoost.developerDefault()

        let texts = Set(boost.terms.map(\.text))
        XCTAssertFalse(texts.contains("deploy"), "«deploy» \u{043B}\u{043E}\u{0432}\u{0438}\u{043B} «\u{0442}\u{0451}\u{043F}\u{043B}\u{043E}\u{0439}»")
        XCTAssertFalse(texts.contains("Sentry"), "«Sentry» \u{043B}\u{043E}\u{0432}\u{0438}\u{043B} «\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}»")
        XCTAssertFalse(texts.contains("commit"), "«commit» \u{043B}\u{043E}\u{0432}\u{0438}\u{043B} «\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0443}»")

        // The rest of the dictionary is included in its entirety, with Cyrillic
        // aliases: without them, the bridge from sound to Latin does not work.
        XCTAssertTrue(texts.contains("Kubernetes"))
        XCTAssertTrue(texts.contains("pull request"))
        // Kubernetes has two Cyrillic spellings - inflected and ogres
        // recognition; both serve as bridges and both should go into the set.
        let kubernetes = boost.terms.first { $0.text == "Kubernetes" }
        XCTAssertEqual(Set(kubernetes?.aliases ?? []), ["\u{043A}\u{0443}\u{0431}\u{0435}\u{0440}\u{043D}\u{0435}\u{0442}\u{0435}\u{0441}", "\u{043A}\u{0443}\u{0431}\u{0435}\u{0440}\u{043D}\u{0435}\u{0442}\u{0438}\u{0441}"])
        XCTAssertFalse(
            boost.terms.first { $0.text == "code review" }?.aliases.contains("\u{043A}\u{043E}\u{0443}\u{0442}\u{0440}\u{0438}\u{0432}\u{044C}\u{044E}") ?? true,
            "an exact decoder repair must not become an acoustic bias"
        )
    }

    /// User substitutions - including those learned from edits - go into
    /// acoustic set with the same fuses as the starter ones.
    func testScenario006() {
        let boost = VocabularyBoost.withUserReplacements([
            // duplicate of the starter - does not reproduce
            DictionaryReplacement(spoken: "\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", written: "Postgres"),
            // new term - learns
            DictionaryReplacement(spoken: "\u{0433}\u{0440}\u{0430}\u{0444}\u{0430}\u{043D}\u{0430}", written: "Grafana"),
            // dangerous - the blank holds a flag on it, and the record of the person is his
            // does not cancel
            DictionaryReplacement(spoken: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", written: "Deploy"),
            // without Latin is not a term
            DictionaryReplacement(spoken: "\u{043A}\u{0430}\u{043A} \u{0441}\u{043B}\u{044B}\u{0448}\u{0438}\u{0442}\u{0441}\u{044F}", written: "\u{043A}\u{0430}\u{043A} \u{043F}\u{0438}\u{0448}\u{0435}\u{0442}\u{0441}\u{044F}"),
            // its own dangerous term: previously a person could not exclude anything
            DictionaryReplacement(spoken: "\u{043A}\u{0430}\u{0441}\u{0441}\u{0430}", written: "Kassa", noAcousticBoost: true),
        ])

        let texts = boost.terms.map(\.text)
        XCTAssertTrue(texts.contains("Grafana"))
        XCTAssertFalse(texts.contains { $0.lowercased() == "deploy" })
        XCTAssertFalse(texts.contains("\u{043A}\u{0430}\u{043A} \u{043F}\u{0438}\u{0448}\u{0435}\u{0442}\u{0441}\u{044F}"))
        XCTAssertFalse(texts.contains("Kassa"), "\u{0447}\u{0435}\u{043B}\u{043E}\u{0432}\u{0435}\u{043A} \u{043E}\u{0442}\u{043C}\u{0435}\u{0442}\u{0438}\u{043B} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D} — \u{0432} \u{0430}\u{043A}\u{0443}\u{0441}\u{0442}\u{0438}\u{043A}\u{0443} \u{043E}\u{043D} \u{043D}\u{0435} \u{0438}\u{0434}\u{0451}\u{0442}")
        XCTAssertEqual(texts.filter { $0.lowercased() == "postgres" }.count, 1)
        let postgres = boost.terms.first { $0.text == "Postgres" }
        XCTAssertTrue(postgres?.aliases.contains("\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}") == true)
        let grafana = boost.terms.first { $0.text == "Grafana" }
        XCTAssertEqual(grafana?.aliases, ["\u{0433}\u{0440}\u{0430}\u{0444}\u{0430}\u{043D}\u{0430}"])
    }

    /// Cyrillic spellings are a bridge between sound and Latin term:
    /// model text is Cyrillic, and without such aliases a candidate for
    /// there is no replacement at all.
    func testScenario007() {
        let boost = VocabularyBoost(terms: [
            .init(text: "deploy", aliases: [" \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439} ", "", "\u{0414}\u{0415}\u{041F}\u{041B}\u{041E}\u{0419}", "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}", "deploy"])
        ])

        XCTAssertEqual(boost.terms.first?.aliases, ["\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}"])
    }

    func testScenario008() {
        let boost = VocabularyBoost(terms: [.init(text: "GitHub")])

        XCTAssertEqual(boost.terms.first?.aliases, [])
    }

    func testScenario009() {
        let boost = VocabularyBoost.withUserReplacements([
            DictionaryReplacement(
                spoken: "\u{043F}\u{043E}\u{0441}\u{0442}\u{0433}\u{0440}\u{0435}\u{0441}",
                written: "Postgres",
                noAcousticBoost: true
            )
        ])

        XCTAssertFalse(
            boost.terms.contains { $0.text.lowercased() == "postgres" },
            "a personal text-only mark must disable even a safe built-in acoustic term"
        )
    }
}

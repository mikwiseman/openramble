import DictationCore
import XCTest

/// The application now runs its text pipeline through the shared core. This is
/// what makes that safe to do.
///
/// `DictationCore.TextPipeline` is still here and is still the specification —
/// the conformance fixtures are recordings of it. These tests run both
/// implementations over the same inputs and require identical output, so the
/// day they diverge is the day this fails, rather than the day somebody notices
/// their dictation reads differently.
final class SharedCorePipelineTests: XCTestCase {
    private func compare(
        _ input: String,
        replacements: [DictionaryReplacement] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let swift = TextPipeline(replacements: replacements).run(input)
        let shared = SharedCorePipeline(replacements: replacements).run(input)

        XCTAssertEqual(shared.output.text, swift.output.text, "text for \(input)", file: file, line: line)
        XCTAssertEqual(shared.output.command, swift.output.command, "command for \(input)", file: file, line: line)
        XCTAssertEqual(
            shared.provenance.afterDictionary, swift.provenance.afterDictionary,
            "post-dictionary state for \(input)", file: file, line: line
        )
        XCTAssertEqual(
            shared.provenance.spans, swift.provenance.spans,
            "spans for \(input)", file: file, line: line
        )
    }

    /// The corpus the conformance fixtures are built from, run through both.
    func testBothImplementationsAgreeOnTheCorpus() throws {
        let corpus = try Self.corpus()
        XCTAssertGreaterThan(corpus.count, 60, "the corpus shrank, which is a loss of coverage")

        for testCase in corpus {
            let replacements = testCase.dictionary.map {
                DictionaryReplacement(
                    spoken: $0.spoken,
                    written: $0.written,
                    inflects: $0.inflects,
                    allowsPhoneticMatching: $0.allowsPhoneticMatching
                )
            }
            let swift = TextPipeline(
                replacements: replacements,
                allowPressReturnCommand: testCase.allowPressReturnCommand,
                phoneticMatching: testCase.phoneticMatching
            ).run(testCase.input)
            let shared = SharedCorePipeline(
                replacements: replacements,
                allowPressReturnCommand: testCase.allowPressReturnCommand
            ).run(testCase.input)

            // Phonetic matching is always on in the shared path, so the two
            // are only comparable where the case leaves it on.
            guard testCase.phoneticMatching else { continue }
            XCTAssertEqual(shared.output.text, swift.output.text, "case \(testCase.name)")
            XCTAssertEqual(shared.output.command, swift.output.command, "case \(testCase.name)")
            XCTAssertEqual(shared.provenance.spans, swift.provenance.spans, "case \(testCase.name)")
        }
    }

    /// The starter dictionary is what most people actually dictate through.
    func testBothAgreeWithTheSuppliedDictionary() {
        let supplied = StarterDictionary.developer
        for phrase in [
            "сделай пул реквест сегодня",
            "в центре города красиво",
            "сегодня тёплый вечер",
            "наблюдение кометы",
            "ошибка в сентри опять",
            "без даун тайм работаем",
            "смотри TextPipeline.Output и `git log`",
            "открой /etc/hosts потом",
        ] {
            compare(phrase, replacements: supplied)
        }
    }

    func testBothAgreeOnEmptyAndBlankInput() {
        compare("")
        compare("     ")
    }

    // MARK: - The corpus file

    private struct Case: Decodable {
        struct Entry: Decodable {
            let spoken: String
            let written: String
            let inflects: Bool
            let allowsPhoneticMatching: Bool
        }
        let name: String
        let dictionary: [Entry]
        let allowPressReturnCommand: Bool
        let phoneticMatching: Bool
        let input: String
    }

    private static func corpus() throws -> [Case] {
        // The tests run from the built product, so walk up to the repository.
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory.appending(path: "core/conformance/corpus-text.json")
            if let data = FileManager.default.contents(atPath: candidate.path) {
                return try JSONDecoder().decode([Case].self, from: data)
            }
        }
        throw XCTSkip("the conformance corpus is not reachable from here")
    }
}

import DictationCore
import Foundation

/// One case: a dictionary, a setting, and something that was said.
///
/// The expected output is not written here. It is whatever the shipping macOS
/// pipeline produces — recording it by hand would only pin down what someone
/// believed it did.
struct Case: Codable {
    let name: String
    var dictionary: [Entry] = []
    var allowPressReturnCommand = false
    var phoneticMatching = true
    let input: String

    struct Entry: Codable {
        let spoken: String
        let written: String
        var inflects = true
        var allowsPhoneticMatching = true
    }
}

struct Fixture: Codable {
    let name: String
    let dictionary: [Case.Entry]
    let allowPressReturnCommand: Bool
    let phoneticMatching: Bool
    let input: String
    let text: String
    let command: String?
    let afterDictionary: String
    let spans: [Span]

    struct Span: Codable {
        let kind: String
        let start: Int
        let end: Int
        let text: String
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: GenerateFixtures <corpus.json> <out.json>\n".utf8))
    exit(2)
}

let corpusData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let cases = try JSONDecoder().decode([Case].self, from: corpusData)

let fixtures: [Fixture] = cases.map { testCase in
    let replacements = testCase.dictionary.map { entry in
        DictionaryReplacement(
            spoken: entry.spoken,
            written: entry.written,
            inflects: entry.inflects,
            allowsPhoneticMatching: entry.allowsPhoneticMatching
        )
    }
    let pipeline = TextPipeline(
        replacements: replacements,
        allowPressReturnCommand: testCase.allowPressReturnCommand,
        phoneticMatching: testCase.phoneticMatching
    )
    let run = pipeline.run(testCase.input)
    return Fixture(
        name: testCase.name,
        dictionary: testCase.dictionary,
        allowPressReturnCommand: testCase.allowPressReturnCommand,
        phoneticMatching: testCase.phoneticMatching,
        input: testCase.input,
        text: run.output.text,
        command: run.output.command?.rawValue,
        afterDictionary: run.provenance.afterDictionary,
        spans: run.provenance.spans.map {
            Fixture.Span(kind: $0.kind.rawValue, start: $0.range.lowerBound, end: $0.range.upperBound, text: $0.text)
        }
    )
}

/// The starter dictionary, recorded rather than hand-copied.
///
/// Its entries carry flags that were measured, not guessed — which terms must
/// stay out of the acoustic prompt, which must never be phonetic candidates —
/// and a second hand-maintained copy would drift from those measurements
/// silently. Generating it keeps one source of truth.
struct StarterEntry: Codable {
    let spoken: String
    let written: String
    let inflects: Bool
    let noAcousticBoost: Bool
    let allowsPhoneticMatching: Bool
}

let starter = StarterDictionary.developer.map {
    StarterEntry(
        spoken: $0.spoken,
        written: $0.written,
        inflects: $0.inflects,
        noAcousticBoost: $0.noAcousticBoost,
        allowsPhoneticMatching: $0.allowsPhoneticMatching
    )
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(fixtures).write(to: URL(fileURLWithPath: arguments[2]))
FileHandle.standardError.write(Data("wrote \(fixtures.count) fixtures\n".utf8))

let starterURL = URL(fileURLWithPath: arguments[2])
    .deletingLastPathComponent()
    .appendingPathComponent("starter-dictionary.json")
try encoder.encode(starter).write(to: starterURL)
FileHandle.standardError.write(Data("wrote \(starter.count) starter entries\n".utf8))

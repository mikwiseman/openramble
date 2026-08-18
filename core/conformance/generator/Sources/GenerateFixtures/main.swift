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

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(fixtures).write(to: URL(fileURLWithPath: arguments[2]))
FileHandle.standardError.write(Data("wrote \(fixtures.count) fixtures\n".utf8))

import DictationCore
import Foundation
import LocalASR
import XCTest

@MainActor
final class FileQualityTests: XCTestCase {
    func testNamesNumbersAndMixedLanguageSurviveLongFileBoundaries() async throws {
        let phrase = "Алексей Петров проверил 42 файла в GitHub. Мы обсуждали pull request, deploy и production. "
            + "Мария Иванова назначила встречу на пятнадцатое сентября. Сумма договора составляет 12900 рублей."
        let expectedText = Array(repeating: phrase, count: 4).joined(separator: " ")
            + " Последний номер 2026. Работа завершена."
        let transcriber = try await requireEndToEndTranscriber()
        let url = try await SpeechFixtures.shared.speech(expectedText)
        let whole = try await transcriber.transcribe(fileURL: url)
        let capture = Capture()
        try await FileTranscriber(transcriber: transcriber).transcribe(files: [url]) { _, result in
            await capture.store(result)
        }
        let result = try await capture.get()
        let expected = Self.words(expectedText)
        let baseline = Self.distance(expected, Self.words(whole.text))
        let chunked = Self.distance(expected, Self.words(result.text))
        print("[file-quality-mixed] referenceErrors=\(baseline) chunkErrors=\(chunked) words=\(expected.count)")
        XCTAssertLessThanOrEqual(chunked, baseline)
        XCTAssertEqual(result.text.occurrences(of: "Алексей Петров"), 4)
        XCTAssertEqual(result.text.occurrences(of: "Мария Иванова"), 4)
        XCTAssertTrue(result.text.contains("2026"))
        XCTAssertTrue(String(result.text.suffix(60)).containsInsensitive("Работа завершена"))
    }

    func testChunkProfilesPreserveRepeatedSpeechAndTheFinalWords() async throws {
        let transcriber = try await requireEndToEndTranscriber()
        let url = try await SpeechFixtures.shared.speech(Phrase.veryLong)
        let reference = try await transcriber.transcribe(fileURL: url)
        let expected = Self.words(Phrase.veryLong)
        let referenceErrors = Self.distance(expected, Self.words(reference.text))
        for length in [15, 30, 60] {
            let result = Capture()
            try await FileTranscriber(transcriber: transcriber, segmentSeconds: length).transcribe(files: [url]) {
                _, outcome in await result.store(outcome)
            }
            let transcript = try await result.get()
            let errors = Self.distance(expected, Self.words(transcript.text))
            print("[file-quality] chunk=\(length)s referenceErrors=\(referenceErrors) chunkErrors=\(errors) referenceWords=\(expected.count)")
            if length == 30 {
                XCTAssertLessThanOrEqual(errors, referenceErrors,
                                         "the shipping split must not lose quality versus whole-file decoding")
                XCTAssertEqual(transcript.text.occurrences(of: "Вечером мы собираем сборку"), 5)
                XCTAssertTrue(String(transcript.text.suffix(60)).containsInsensitive("заранее"))
            }
            XCTAssertTrue(transcript.words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= transcript.duration })
            XCTAssertTrue(zip(transcript.words, transcript.words.dropFirst()).allSatisfy { $0.start <= $1.start })
        }
    }

    private actor Capture {
        var outcome: Result<FileTranscript, Error>?
        func store(_ result: Result<FileTranscript, Error>) { outcome = result }
        func get() throws -> FileTranscript { try XCTUnwrap(outcome).get() }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func distance(_ expected: [String], _ actual: [String]) -> Int {
        var row = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var next = [i + 1]
            for (j, candidate) in actual.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (word == candidate ? 0 : 1)))
            }
            row = next
        }
        return row[actual.count]
    }
}

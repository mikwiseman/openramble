import DictationCore
import Foundation
import XCTest
@testable import LocalASR

final class TranscriptFormatTests: XCTestCase {
    private let transcript = FileTranscript(text: "Привет, world!", words: [
        .init(text: "Привет,", start: 59.9, end: 60.1),
        .init(text: "world!", start: 60.2, end: 60.5),
    ], duration: 61, recognitionSeconds: 0.1)

    func testSubtitleTimeCarriesAcrossMinutesAndPreservesUnicode() throws {
        let srt = String(decoding: try TranscriptFormat.srt.render(transcript), as: UTF8.self)
        XCTAssertEqual(srt, "1\n00:00:59,900 --> 00:01:00,500\nПривет, world!\n\n")
        let vtt = String(decoding: try TranscriptFormat.vtt.render(transcript), as: UTF8.self)
        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:59.900 --> 00:01:00.500\nПривет, world!\n\n")
    }

    func testJSONKeepsOriginalFileWordTimes() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: TranscriptFormat.json.render(transcript)) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, transcript.text)
        let words = try XCTUnwrap(json["words"] as? [[String: Any]])
        XCTAssertEqual(words[1]["start"] as? Double, 60.2)
        XCTAssertEqual(words[1]["text"] as? String, "world!")
    }

    func testExistingOutputIsPreservedAndNoTemporaryFileRemains() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appending(path: "text.txt")
        try Data("original".utf8).write(to: output)
        XCTAssertThrowsError(try TranscriptFormat.txt.write(transcript, to: output))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["text.txt"])
        let fresh = folder.appending(path: "fresh.json")
        try TranscriptFormat.json.write(transcript, to: fresh)
        XCTAssertEqual(try Data(contentsOf: fresh), try TranscriptFormat.json.render(transcript))
    }

    func testSilenceHasNoInventedSubtitleCue() throws {
        let silence = FileTranscript(text: "", words: [], duration: 10, recognitionSeconds: 0)
        XCTAssertTrue(try TranscriptFormat.srt.render(silence).isEmpty)
        XCTAssertEqual(String(decoding: try TranscriptFormat.vtt.render(silence), as: UTF8.self), "WEBVTT\n\n")
    }

    func testMillisecondQuantizationNeverRunsPastTheSourceEnd() throws {
        let tail = FileTranscript(text: "конец", words: [.init(text: "конец", start: 0.9, end: 1.0009)],
                                  duration: 1.0009, recognitionSeconds: 0)
        let text = String(decoding: try TranscriptFormat.srt.render(tail), as: UTF8.self)
        XCTAssertTrue(text.contains("--> 00:00:01,000"))
    }
}

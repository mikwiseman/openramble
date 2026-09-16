import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

final class FileAudioChunksTests: XCTestCase {
    func testQuietAudioBelowMeetingSpeechThresholdIsNotDiscarded() async throws {
        let url = try recording(seconds: 61, value: 0.001)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await FileAudioChunks(url: url)
        var covered = 0
        while let chunk = try await source.next() { covered = chunk.endFrame }
        XCTAssertEqual(covered, 61 * 16_000, "imported audio has no guaranteed microphone gain")
    }
    func testContinuousAudioHasBoundedChunksAndKeepsShortTail() async throws {
        let url = try recording(seconds: 61.13, value: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await FileAudioChunks(url: url)
        var end = 0
        var count = 0
        while let chunk = try await source.next() {
            XCTAssertEqual(chunk.boundaryFrame, end)
            XCTAssertLessThanOrEqual(chunk.startFrame, chunk.boundaryFrame)
            XCTAssertLessThanOrEqual(chunk.samples.count, 36 * 16_000)
            XCTAssertEqual(chunk.samples.last, 0.1)
            end = chunk.endFrame
            count += 1
        }
        XCTAssertEqual(end, Int(61.13 * 16_000))
        XCTAssertEqual(count, 2, "the final 1.13 s must be merged into the preceding chunk")
    }

    func testShortFileStaysWholeAndLongSilenceProducesNoChunks() async throws {
        let short = try recording(seconds: 29, value: 0)
        let silent = try recording(seconds: 90, value: 0)
        defer { try? FileManager.default.removeItem(at: short); try? FileManager.default.removeItem(at: silent) }
        let first = try await FileAudioChunks(url: short)
        let chunk = try await first.next()
        XCTAssertEqual(chunk?.samples.count, 29 * 16_000)
        let tail = try await first.next()
        XCTAssertNil(tail)
        let quiet = try await FileAudioChunks(url: silent)
        let none = try await quiet.next()
        XCTAssertNil(none)
        XCTAssertEqual(quiet.duration, 90)
    }

    func testTimestampJoinRemovesContextOnceAndPreservesRepeatedWordsAndFinalNumber() throws {
        var joiner = TimedTranscriptJoiner()
        func word(_ text: String, _ start: Double) -> ASRResult.Word {
            .init(text: text, start: start, end: start + 0.2)
        }
        try joiner.append(ASRResult(text: "Да да обсудим число", words: [
            word("Да", 1), word("да", 2), word("обсудим", 29), word("число", 30)
        ], audioDuration: 32, processingDuration: 0), chunk: .init(samples: [], startFrame: 0,
            boundaryFrame: 0, endFrame: 30 * 16_000), duration: 34)
        try joiner.append(ASRResult(text: "обсудим число 2026.", words: [
            word("обсудим", 1), word("число", 2), word("2026.", 3.8)
        ], audioDuration: 6, processingDuration: 0), chunk: .init(samples: [], startFrame: 28 * 16_000,
            boundaryFrame: 30 * 16_000, endFrame: 34 * 16_000), duration: 34)
        XCTAssertEqual(joiner.words.map(\.text), ["Да", "да", "обсудим", "число", "2026."])
        XCTAssertEqual(joiner.words.last?.start, 31.8)
        XCTAssertEqual(joiner.words.last?.end, 32)
    }

    private func recording(seconds: Double, value: Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chunks-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for offset in stride(from: 0, to: Int(seconds * 16_000), by: 16_000) {
            let count = min(16_000, Int(seconds * 16_000) - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count { buffer.floatChannelData![0][index] = value }
            try file.write(from: buffer)
        }
        return url
    }
}

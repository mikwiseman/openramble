import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

final class FileAudioChunksTests: XCTestCase {
    func testQuietSpeechFarBelowTheMicrophoneThresholdIsKept() async throws {
        // -54 dBFS, a tenth of the live microphone's speech peak.
        let url = try recording(seconds: 61) { self.syllables($0, level: 0.002) }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await FileAudioChunks(url: url)
        var covered = 0
        while let chunk = try await source.next() {
            XCTAssertEqual(chunk.startFrame, covered)
            covered = chunk.endFrame
        }
        XCTAssertEqual(covered, 61 * 16_000, "imported audio has no guaranteed microphone gain")
    }

    func testContinuousSpeechBecomesContiguousPiecesOfAtMostTwentySeconds() async throws {
        let url = try recording(seconds: 51.13) { self.syllables($0, level: 0.1) }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await FileAudioChunks(url: url)
        var end = 0
        var count = 0
        while let chunk = try await source.next() {
            XCTAssertEqual(chunk.startFrame, end)
            XCTAssertEqual(chunk.samples.count, chunk.endFrame - chunk.startFrame)
            XCTAssertLessThanOrEqual(chunk.samples.count, 20 * 16_000)
            end = chunk.endFrame
            count += 1
        }
        XCTAssertEqual(end, Int(51.13 * 16_000))
        XCTAssertEqual(count, 4, "51 s is ceil(51.13 / 16) = 4 nearly equal pieces")
    }

    func testSilenceBetweenSentencesIsLeftOut() async throws {
        let url = try recording(seconds: 70) { $0 < 20 * 16_000 || $0 >= 50 * 16_000 ? self.syllables($0, level: 0.1) : 0 }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await FileAudioChunks(url: url)
        var pieces: [Range<Int>] = []
        while let chunk = try await source.next() { pieces.append(chunk.startFrame..<chunk.endFrame) }
        XCTAssertEqual(pieces.first?.lowerBound, 0)
        XCTAssertEqual(pieces.last?.upperBound, 70 * 16_000)
        XCTAssertFalse(pieces.contains { $0.overlaps(22 * 16_000..<48 * 16_000) }, "\(pieces)")
        XCTAssertTrue(pieces.contains { $0.contains(20 * 16_000) }, "a second of audio after the last word")
    }

    func testSamplesInMemoryArePlannedLikeAFile() async throws {
        let samples = (0..<Int(51.13 * 16_000)).map { syllables($0, level: 0.1) }
        let url = try recording(seconds: 51.13) { self.syllables($0, level: 0.1) }
        defer { try? FileManager.default.removeItem(at: url) }
        let fromFile = try await FileAudioChunks(url: url)
        let fromMemory = FileAudioChunks(samples: samples)
        while let chunk = try await fromFile.next() {
            let same = try await fromMemory.next()
            XCTAssertEqual(same?.startFrame, chunk.startFrame)
            XCTAssertEqual(same?.samples, chunk.samples)
        }
        let rest = try await fromMemory.next()
        XCTAssertNil(rest)
    }

    func testShortFileStaysWholeAndLongSilenceProducesNoChunks() async throws {
        let short = try recording(seconds: 29) { _ in 0 }
        let silent = try recording(seconds: 90) { _ in 0 }
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

    func testJoinMovesWordsByTheirPieceAndKeepsRepeatsAndTheFinalNumber() throws {
        var joiner = TimedTranscriptJoiner()
        func word(_ text: String, _ start: Double) -> ASRResult.Word {
            .init(text: text, start: start, end: start + 0.2)
        }
        try joiner.append(ASRResult(text: "Да да обсудим", words: [
            word("Да", 1), word("да", 2), word("обсудим", 19.7)
        ], audioDuration: 20, processingDuration: 0), chunk: .init(samples: [], startFrame: 0,
            endFrame: 20 * 16_000), duration: 34)
        try joiner.append(ASRResult(text: "обсудим число 2026.", words: [
            word("обсудим", 0), word("число", 1), word("2026.", 13.9)
        ], audioDuration: 14, processingDuration: 0), chunk: .init(samples: [], startFrame: 20 * 16_000,
            endFrame: 34 * 16_000), duration: 34)
        XCTAssertEqual(joiner.words.map(\.text), ["Да", "да", "обсудим", "обсудим", "число", "2026."])
        XCTAssertEqual(joiner.words.map(\.start), [1, 2, 19.7, 20, 21, 33.9])
        XCTAssertEqual(joiner.words.last?.end, 34)
    }

    /// Noise whose loudness changes every 20 ms, as syllables do; a steady
    /// tone would be taken for the room's floor.
    private func syllables(_ index: Int, level: Float) -> Float {
        var state = UInt32(truncatingIfNeeded: index / 320) &* 2_654_435_761 &+ 1
        state = state &* 1_664_525 &+ 1_013_904_223
        let loudness = 0.4 + 1.2 * Float(state >> 8) / Float(1 << 24)
        var noise = UInt32(truncatingIfNeeded: index) &* 747_796_405 &+ 2_891_336_453
        noise ^= noise >> 13
        noise = noise &* 1_274_126_177
        return level * loudness * (Float(noise >> 8) / Float(1 << 23) - 1)
    }

    private func recording(seconds: Double, sample: (Int) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chunks-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for offset in stride(from: 0, to: Int(seconds * 16_000), by: 16_000) {
            let count = min(16_000, Int(seconds * 16_000) - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count { buffer.floatChannelData![0][index] = sample(offset + index) }
            try file.write(from: buffer)
        }
        return url
    }
}

import AVFoundation
import XCTest
@testable import DictationAudio

/// One stereo file, both sides in step, playable after a crash.
final class MeetingWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "meeting-writer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func constant(_ value: Float, _ count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    private func readChannels(_ url: URL) throws -> (left: [Float], right: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let count = Int(buffer.frameLength)
        return (
            Array(UnsafeBufferPointer(start: data[0], count: count)),
            Array(UnsafeBufferPointer(start: data[1], count: count)),
            format.sampleRate
        )
    }

    func testTheMicrophoneIsLeftAndTheSystemIsRightAndTheyStayInStep() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(microphone: constant(0.5, 1_600), system: constant(-0.5, 1_600))
        try writer.append(microphone: constant(0.25, 800), system: constant(0, 800))
        try writer.finish()

        let audio = try readChannels(writer.audioURL)
        XCTAssertEqual(audio.sampleRate, 16_000)
        XCTAssertEqual(audio.left.count, 2_400)
        XCTAssertEqual(audio.left[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(audio.right[0], -0.5, accuracy: 0.001)
        XCTAssertEqual(audio.left[2_000], 0.25, accuracy: 0.001)
        XCTAssertEqual(audio.right[2_000], 0, accuracy: 0.001)
        XCTAssertEqual(writer.frameCount, 2_400)
        XCTAssertEqual(writer.duration, 0.15, accuracy: 0.0001)
    }

    func testPeaksAreWrittenOneBucketPerHundredMilliseconds() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        // 2.5 buckets: two full and a partial one that finish() must flush.
        try writer.append(microphone: constant(0.1, 1_600), system: constant(0.9, 1_600))
        try writer.append(microphone: constant(0.3, 1_600), system: constant(0.0, 1_600))
        try writer.append(microphone: constant(0.7, 800), system: constant(0.2, 800))
        try writer.finish()

        let peaks = try PeakFile.read(url: writer.peaksURL)
        XCTAssertEqual(peaks.channels[0].count, 3)
        XCTAssertEqual(peaks.channels[0][0], 26.0 / 255, accuracy: 0.001)
        XCTAssertEqual(peaks.channels[1][0], 230.0 / 255, accuracy: 0.001)
        XCTAssertEqual(peaks.channels[0][2], 179.0 / 255, accuracy: 0.001, "the partial bucket was flushed")
    }

    func testMismatchedChannelLengthsAreRefusedBeforeAnythingIsWritten() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        XCTAssertThrowsError(try writer.append(microphone: constant(0, 100), system: constant(0, 99)))
        XCTAssertEqual(writer.frameCount, 0)
        XCTAssertFalse(writer.hasWriteFailure, "a caller mistake is not a disk failure")
        try writer.finish()
    }

    func testAFileAbandonedMidRecordingIsUnplayableUntilItsHeaderIsRepaired() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(microphone: constant(0.5, 3_200), system: constant(-0.5, 3_200))
        writer.abandon()

        // The header still says nothing was recorded. A reader either believes
        // it (length 0) or refuses the file; both mean "unplayable".
        if let unrepaired = try? AVAudioFile(forReading: writer.audioURL) {
            XCTAssertEqual(unrepaired.length, 0)
        }

        let frames = try MeetingWriter.repairHeader(at: writer.audioURL)
        XCTAssertEqual(frames, 3_200)
        XCTAssertEqual(MeetingWriter.frameCount(at: writer.audioURL), 3_200)
        let audio = try readChannels(writer.audioURL)
        XCTAssertEqual(audio.left.count, 3_200)
        XCTAssertEqual(audio.right[3_199], -0.5, accuracy: 0.001)
    }

    func testRepairRefusesAFileThatIsNotAWAV() throws {
        let url = directory.appending(path: "audio.wav")
        try Data(repeating: 0x41, count: 100).write(to: url)
        XCTAssertThrowsError(try MeetingWriter.repairHeader(at: url))
    }

    func testAppendingToAnUnopenedWriterFails() {
        let writer = MeetingWriter(directory: directory)
        XCTAssertThrowsError(try writer.append(microphone: constant(0, 10), system: constant(0, 10)))
    }
}

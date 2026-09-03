import DictationCore
import XCTest
@testable import DictationAudio

final class MeetingPCMWindowReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "pcm-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReadsOneChannelAtAnOffsetSampleExact() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        // Left counts up, right counts down, so a wrong channel or a wrong
        // offset is visible in the values.
        try writer.append(
            microphone: (0..<4_000).map { Float($0) / 8_000 },
            system: (0..<4_000).map { -Float($0) / 8_000 }
        )
        try writer.finish()

        let reader = MeetingPCMWindowReader(url: writer.audioURL)
        let left = try reader.read(channel: .microphone, startFrame: 1_000, frameCount: 10)
        let right = try reader.read(channel: .system, startFrame: 1_000, frameCount: 10)
        XCTAssertEqual(left[0], 1_000.0 / 8_000, accuracy: 0.0001)
        XCTAssertEqual(left[9], 1_009.0 / 8_000, accuracy: 0.0001)
        XCTAssertEqual(right[0], -1_000.0 / 8_000, accuracy: 0.0001)
        XCTAssertEqual(right[9], -1_009.0 / 8_000, accuracy: 0.0001)
    }

    func testReadsWhileTheHeaderStillSaysNothingWasRecorded() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(microphone: [Float](repeating: 0.5, count: 3_200), system: [Float](repeating: 0, count: 3_200))
        // Not finished: the header's sizes are still zero.
        let reader = MeetingPCMWindowReader(url: writer.audioURL)
        let samples = try reader.read(MeetingSegmentRef(channel: .microphone, startFrame: 1_600, frameCount: 1_600))
        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(samples[0], 0.5, accuracy: 0.001)
        try writer.finish()
    }

    func testAWindowPastTheEndIsAShortReadNotSilence() throws {
        let writer = MeetingWriter(directory: directory)
        try writer.open()
        try writer.append(microphone: [Float](repeating: 0.5, count: 100), system: [Float](repeating: 0, count: 100))
        try writer.finish()
        let reader = MeetingPCMWindowReader(url: writer.audioURL)
        XCTAssertThrowsError(try reader.read(channel: .microphone, startFrame: 50, frameCount: 100))
    }

    func testAMissingFileIsAnError() {
        let reader = MeetingPCMWindowReader(url: directory.appending(path: "nope.wav"))
        XCTAssertThrowsError(try reader.read(channel: .microphone, startFrame: 0, frameCount: 10))
    }
}

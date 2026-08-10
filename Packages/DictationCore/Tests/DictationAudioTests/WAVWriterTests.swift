import AVFoundation
import XCTest
@testable import DictationAudio

final class WAVWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wav-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWriter(name: String = "take.wav") -> WAVWriter {
        WAVWriter(url: directory.appending(path: name), sampleRate: 16_000, channels: 1)
    }

    func testProducesFileReadableByTheSystem() throws {
        let writer = makeWriter()
        try writer.open()
        // Half a second of a sine wave.
        let samples = (0..<8000).map { sin(Float($0) * 0.05) * 0.5 }
        try writer.append(samples)
        let url = try writer.close()

        // Main check: the file must be opened using standard system tools,
        // otherwise recognition won't read it.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.length, 8000)
    }

    func testHeaderSizesAreFixedUpOnClose() throws {
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.1, count: 1600))
        let url = try writer.close()

        let data = try Data(contentsOf: url)
        // 44 bytes of header plus 1600 samples of two bytes.
        XCTAssertEqual(data.count, 44 + 3200)

        // The title should contain real dimensions, not blank zeros.
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), 36 + 3200)
        XCTAssertEqual(Int(dataSize), 3200)
    }

    func testDurationTracksWhatWasWritten() throws {
        let writer = makeWriter()
        try writer.open()

        XCTAssertEqual(writer.duration, 0)
        try writer.append(Array(repeating: 0, count: 16_000))
        XCTAssertEqual(writer.duration, 1.0, accuracy: 0.001)
        try writer.append(Array(repeating: 0, count: 8_000))
        XCTAssertEqual(writer.duration, 1.5, accuracy: 0.001)

        try writer.close()
    }

    func testDiscardRemovesFile() throws {
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.2, count: 1000))
        let url = writer.fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        writer.discard()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0433}\u{043E}\u{043B}\u{043E}\u{0441}\u{0430} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}\u{0435}"
        )
    }

    func testAppendWithoutOpenFails() {
        let writer = makeWriter()

        XCTAssertThrowsError(try writer.append([0.1])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
    }

    func testClampsSamplesOutOfRange() throws {
        // An input that is too loud should not overflow the scale and turn into a crackle.
        let writer = makeWriter()
        try writer.open()
        try writer.append([2.0, -2.0])
        let url = try writer.close()

        let data = try Data(contentsOf: url)
        let first = data.subdata(in: 44..<46).withUnsafeBytes { $0.load(as: Int16.self) }
        let second = data.subdata(in: 46..<48).withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(first, 32767)
        XCTAssertEqual(second, -32767)
    }

    func testEmptyRecordingStillProducesValidFile() throws {
        // The user pressed and immediately released - the file must be correct,
        // just empty, not broken.
        let writer = makeWriter()
        try writer.open()
        let url = try writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 0)
    }
}

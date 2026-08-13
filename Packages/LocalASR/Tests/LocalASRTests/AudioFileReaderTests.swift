import AVFoundation
import XCTest
@testable import LocalASR

/// The audio reader is the bottleneck between recording and recognition.
///
/// Recognition is capable of exactly one format: mono, 16 kHz, Float32. Microphones
/// users are given anything: headset - 8 kHz, built-in input - 44.1,
/// external interface is 48, and stereo comes from any USB camera. Error
/// casts do not appear to be an error: the speech is simply recognized as slurred
/// or it turns out twice as long as it was.
final class AudioFileReaderTests: XCTestCase {
    private var directory: URL!
    private let reader = AudioFileReader()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Record a WAV of the desired frequency and number of channels.
    ///
    /// The record is wrapped in `autoreleasepool` intentionally: `AVAudioFile` appends
    /// data when freed, and file read when the write object is alive,
    /// will be empty.
    private func writeWAV(
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        name: String = "take"
    ) throws -> URL {
        let url = directory.appending(path: "\(name)-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)

        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<Int(channels) {
                for index in 0..<Int(frames) {
                    // Sine wave, not silence: otherwise “read” and “read zeros”
                    // would look the same.
                    buffer.floatChannelData?[channel][index] = sin(Float(index) * 0.03) * 0.4
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func assertRoughly(_ actual: Int, _ expected: Int, tolerance: Int, _ message: String) {
        XCTAssertEqual(Double(actual), Double(expected), accuracy: Double(tolerance), message)
    }

    // MARK: - Frequencies

    func testReadsOwnRecordingWithoutTouchingIt() throws {
        // Own dictation recording already in target format: cast here
        // not necessary, and the number of samples must match exactly.
        let url = try writeWAV(seconds: 0.5, sampleRate: 16_000, channels: 1)

        let samples = try reader.samples(from: url)

        XCTAssertEqual(samples.count, 8000)
        XCTAssertTrue(samples.contains { $0 != 0 }, "\u{041F}\u{0440}\u{043E}\u{0447}\u{0438}\u{0442}\u{0430}\u{043D}\u{0430} \u{0442}\u{0438}\u{0448}\u{0438}\u{043D}\u{0430} \u{0432}\u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{0441}\u{0438}\u{043D}\u{0443}\u{0441}\u{043E}\u{0438}\u{0434}\u{044B}")
    }

    func testUpsamplesNarrowbandHeadset() throws {
        // The Bluetooth headset gives 8 kHz in talk mode. Without casting
        // recognition would get twice as short a record.
        let url = try writeWAV(seconds: 1.0, sampleRate: 8_000, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "8 \u{043A}\u{0413}\u{0446} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{0441}\u{0442}\u{0430}\u{0442}\u{044C} 16 \u{043A}\u{0413}\u{0446}")
    }

    func testDownsamplesBuiltInMicrophone() throws {
        // Mac built-in input is 44.1 kHz.
        let url = try writeWAV(seconds: 1.0, sampleRate: 44_100, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "44,1 \u{043A}\u{0413}\u{0446} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{0441}\u{0442}\u{0430}\u{0442}\u{044C} 16 \u{043A}\u{0413}\u{0446}")
    }

    func testDownsamplesExternalInterface() throws {
        // External audio interface - 48 kHz.
        let url = try writeWAV(seconds: 1.0, sampleRate: 48_000, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "48 \u{043A}\u{0413}\u{0446} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{0441}\u{0442}\u{0430}\u{0442}\u{044C} 16 \u{043A}\u{0413}\u{0446}")
    }

    // MARK: - Channels

    func testMixesStereoDownToMono() throws {
        // USB cameras and most interfaces provide two channels. The engine is waiting
        // one: if you give him the stereo as is, the channels will be glued end to end and speech
        // will turn into an accelerated mess.
        let url = try writeWAV(seconds: 1.0, sampleRate: 44_100, channels: 2)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "\u{0421}\u{0442}\u{0435}\u{0440}\u{0435}\u{043E} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0441}\u{0432}\u{0435}\u{0440}\u{043D}\u{0443}\u{0442}\u{044C}\u{0441}\u{044F} \u{0432} \u{043C}\u{043E}\u{043D}\u{043E}")
        XCTAssertTrue(samples.contains { $0 != 0 }, "\u{0421}\u{0432}\u{0451}\u{0440}\u{0442}\u{043A}\u{0430} \u{043A}\u{0430}\u{043D}\u{0430}\u{043B}\u{043E}\u{0432} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0434}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C} \u{0442}\u{0438}\u{0448}\u{0438}\u{043D}\u{0443}")
    }

    // MARK: - Long entries

    func testDurationLimitRejectsBeforeBuildingFullSampleArray() throws {
        let url = try writeWAV(seconds: 2, sampleRate: 48_000, channels: 2)

        XCTAssertThrowsError(try reader.samples(from: url, maximumDuration: 1)) { error in
            guard case let .durationExceeded(actual, maximum) = error as? AudioFileReader.Failure else {
                return XCTFail("Expected duration limit, got \(error)")
            }
            XCTAssertEqual(actual, 2, accuracy: 0.01)
            XCTAssertEqual(maximum, 1)
        }
    }

    func testReadsRecordingLongerThanOneConversionChunk() throws {
        // The casting occurs in pieces of 16,384 frames, and gluing the pieces together is the most
        // fragile place: the error there cuts off the end of a long dictation.
        let url = try writeWAV(seconds: 3.0, sampleRate: 48_000, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 48_000, tolerance: 800, "\u{0422}\u{0440}\u{0438} \u{0441}\u{0435}\u{043A}\u{0443}\u{043D}\u{0434}\u{044B} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{044B} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{0442}\u{044C} \u{0445}\u{0432}\u{043E}\u{0441}\u{0442}")
    }

    // MARK: - Broken inputs

    func testBrokenHeaderIsReportedNotGuessed() throws {
        // File with .wav extension, but no sound: this is what a broken recording looks like
        // after the application crashes. You cannot silently return an empty array -
        // it would have been “dictation detected silence” instead of an honest mistake.
        let url = directory.appending(path: "broken.wav", directoryHint: .notDirectory)
        try Data("RIFF \u{044D}\u{0442}\u{043E} \u{043D}\u{0435} \u{0437}\u{0432}\u{0443}\u{043A}, \u{0430} \u{043E}\u{0431}\u{0440}\u{044B}\u{0432}\u{043E}\u{043A}".utf8).write(to: url)

        XCTAssertThrowsError(try reader.samples(from: url)) { error in
            guard case .unreadable = error as? AudioFileReader.Failure else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0447}\u{0442}\u{0435}\u{043D}\u{0438}\u{044F}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func testMissingFileIsReported() throws {
        let url = directory.appending(path: "\u{043D}\u{0435}\u{0442}-\u{0442}\u{0430}\u{043A}\u{043E}\u{0433}\u{043E}.wav", directoryHint: .notDirectory)

        XCTAssertThrowsError(try reader.samples(from: url)) { error in
            guard case .unreadable = error as? AudioFileReader.Failure else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0447}\u{0442}\u{0435}\u{043D}\u{0438}\u{044F}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func testEmptyRecordingIsReportedSeparately() throws {
        // Pressed and immediately released: the file is correct, but empty. This is separate
        // an accident, not a format failure - and you need to distinguish between them so as not to scare
        // person with a message about a broken sound.
        let url = try writeWAV(seconds: 0, sampleRate: 16_000, channels: 1, name: "empty")

        XCTAssertThrowsError(try reader.samples(from: url)) { error in
            XCTAssertEqual(error as? AudioFileReader.Failure, .emptyFile)
        }
    }
}

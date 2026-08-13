import AVFoundation
import DictationCore
import XCTest
@testable import DictationAudio

final class MicrophoneCaptureFormatTests: XCTestCase {
    private func format(rate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: channels,
                interleaved: false
            )
        )
    }

    func testMatchingFormatNeedsNoConverter() throws {
        let target = try format(rate: 16_000, channels: 1)

        let converter = try MicrophoneCapture.converter(
            from: target,
            to: target,
            factory: { _, _ in XCTFail("\u{0424}\u{0430}\u{0431}\u{0440}\u{0438}\u{043A}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0432}\u{044B}\u{0437}\u{044B}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}"); return nil }
        )

        XCTAssertNil(converter)
    }

    func testFailedConverterFor48kStereoIsFatal() throws {
        let source = try format(rate: 48_000, channels: 2)
        let target = try format(rate: 16_000, channels: 1)

        XCTAssertThrowsError(
            try MicrophoneCapture.converter(from: source, to: target, factory: { _, _ in nil })
        ) { error in
            guard case .unsupportedAudioFormat = error as? AudioCaptureError else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} unsupportedAudioFormat, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func test48kStereoGetsARealConverter() throws {
        let source = try format(rate: 48_000, channels: 2)
        let target = try format(rate: 16_000, channels: 1)

        let converter = try MicrophoneCapture.converter(
            from: source,
            to: target,
            factory: { AVAudioConverter(from: $0, to: $1) }
        )

        XCTAssertNotNil(converter)
    }

    func testRuntimeConversionFailureIsNotSilentlyDropped() throws {
        let expectedSource = try format(rate: 48_000, channels: 2)
        let unexpectedSource = try format(rate: 44_100, channels: 1)
        let target = try format(rate: 16_000, channels: 1)
        let converter = try XCTUnwrap(AVAudioConverter(from: expectedSource, to: target))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: unexpectedSource, frameCapacity: 256)
        )
        buffer.frameLength = 256

        XCTAssertThrowsError(
            try MicrophoneCapture.extractSamples(from: buffer, using: converter, target: target)
        ) { error in
            guard case .unsupportedAudioFormat = error as? AudioCaptureError else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{0432}\u{0438}\u{0434}\u{0438}\u{043C}\u{0430}\u{044F} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0444}\u{043E}\u{0440}\u{043C}\u{0430}\u{0442}\u{0430}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func testRecognitionBufferMovesSamplesWithoutKeepingASecondCopy() {
        var buffer = RecognitionSampleBuffer(maximumSamples: 4)
        buffer.append([0.1, 0.2])
        buffer.append([0.3, 0.4])

        XCTAssertEqual(buffer.take(), [0.1, 0.2, 0.3, 0.4])
        XCTAssertNil(buffer.take())
    }

    func testRecognitionBufferFallsBackToWAVAfterItsMemoryCap() {
        var buffer = RecognitionSampleBuffer(maximumSamples: 3)
        buffer.append([0.1, 0.2])
        buffer.append([0.3, 0.4])
        buffer.append([0.5])

        XCTAssertNil(buffer.take(), "overflow must disable the in-memory path for the whole take")

        buffer.reset()
        buffer.append([0.6])
        XCTAssertEqual(buffer.take(), [0.6], "a new take gets a fresh fast-path buffer")
    }
}

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
            factory: { _, _ in XCTFail("Фабрика не должна вызываться"); return nil }
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
                return XCTFail("Ожидалась unsupportedAudioFormat, получено: \(error)")
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
                return XCTFail("Ожидалась видимая ошибка формата, получено: \(error)")
            }
        }
    }
}

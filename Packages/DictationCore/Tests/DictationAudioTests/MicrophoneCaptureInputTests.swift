import AVFoundation
import CoreAudio
import DictationCore
import XCTest
@testable import DictationAudio

/// A take opens the microphone at its key-down, not before, and reads it the
/// way the device delivers it.
///
/// Building an AVAudioEngine graph after every key-down cost ~150 ms before
/// the device even started, and a person who spoke at once lost that much of
/// the first word: 3 of 77 takes kept it whole with speech 0-150 ms after the
/// press (research/first-word-2026-10). A HAL I/O proc is live in ~45 ms. It
/// hands over the device's own format, interleaved and at the device's rate,
/// which the engine used to normalize for us.
final class MicrophoneCaptureInputTests: XCTestCase {
    /// A microphone that records what it was asked to do.
    private final class FakeInput: CaptureInput, @unchecked Sendable {
        let format: AVAudioFormat
        private let lock = NSLock()
        private var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var startCount = 0
        private var stopCount = 0

        init(format: AVAudioFormat) {
            self.format = format
        }

        var starts: Int { lock.withLock { startCount } }
        var stops: Int { lock.withLock { stopCount } }

        func install(_ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
            lock.withLock { self.handler = handler }
        }

        func start() throws {
            lock.withLock { startCount += 1 }
        }

        func stop() {
            lock.withLock { stopCount += 1 }
        }

        func deliver(_ buffer: AVAudioPCMBuffer, sampleTime: AVAudioFramePosition) {
            let handler = lock.withLock { self.handler }
            handler?(buffer, AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate))
        }
    }

    private final class Opener: @unchecked Sendable {
        let format: AVAudioFormat
        private let lock = NSLock()
        private var inputs: [FakeInput] = []

        init(format: AVAudioFormat) {
            self.format = format
        }

        var opened: [FakeInput] { lock.withLock { inputs } }

        func open(_ device: AudioDeviceID?) throws -> any CaptureInput {
            let input = FakeInput(format: format)
            lock.withLock { inputs.append(input) }
            return input
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "capture-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// How a HAL I/O proc delivers the built-in microphone of many Macs.
    private let interleavedStereo = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
    )!

    /// One I/O cycle of a 440 Hz tone, the same on both channels.
    private func cycle(from start: Int, frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            let t = Double(start + frame) / format.sampleRate
            let value = Float(0.5 * sin(2 * Double.pi * 440 * t))
            for channel in 0..<channels {
                data[frame * channels + channel] = value
            }
        }
        return buffer
    }

    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTheMicrophoneOpensAtTheKeyDownAndClosesWithTheTake() async throws {
        let opener = Opener(format: interleavedStereo)
        let capture = MicrophoneCapture(directory: directory, openInput: opener.open)
        XCTAssertTrue(opener.opened.isEmpty, "nothing may be open before the key-down")

        let session = DictationSessionID()
        let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
        XCTAssertEqual(opener.opened.count, 1)
        let input = try XCTUnwrap(opener.opened.first)
        XCTAssertEqual(input.starts, 1)
        XCTAssertEqual(input.stops, 0)

        input.deliver(cycle(from: 0, frames: 512, format: interleavedStereo), sampleTime: 0)
        let recording = try await capture.freezeRecording(session: session, expectedURL: url)
        _ = try? await recording.durableURL()

        try await waitUntil { input.stops == 1 }
        XCTAssertEqual(opener.opened.count, 1, "one take opens the microphone once")
    }

    func testInterleavedStereoAtFortyEightKilohertzBecomesSixteenKilohertzMono() async throws {
        let opener = Opener(format: interleavedStereo)
        let capture = MicrophoneCapture(directory: directory, openInput: opener.open)
        let session = DictationSessionID()
        let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
        let input = try XCTUnwrap(opener.opened.first)

        // One second, in the 512-frame cycles a HAL device uses.
        for start in stride(from: 0, to: 48_000, by: 512) {
            let frames = min(512, 48_000 - start)
            input.deliver(
                cycle(from: start, frames: frames, format: interleavedStereo),
                sampleTime: AVAudioFramePosition(start)
            )
        }
        let arrived = await capture.waitForFirstFrame()
        XCTAssertTrue(arrived)
        let recording = try await capture.freezeRecording(session: session, expectedURL: url)
        _ = try? await recording.durableURL()

        let samples = try XCTUnwrap(recording.samples)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 64, "one second at 16 kHz")
        XCTAssertNotNil(recording.startupLatency)

        // The tone survives as itself: level of a 0.5 sine, and 440 cycles.
        let steady = samples.dropFirst(800).dropLast(800)
        let rms = (steady.reduce(0) { $0 + Double($1) * Double($1) } / Double(steady.count)).squareRoot()
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.02)
        let crossings = zip(steady, steady.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        let seconds = Double(steady.count) / 16_000
        XCTAssertEqual(Double(crossings) / seconds, 440, accuracy: 5)
    }
}

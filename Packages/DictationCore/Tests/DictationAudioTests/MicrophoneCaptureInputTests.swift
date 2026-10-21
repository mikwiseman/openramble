import AVFoundation
import CoreAudio
import DictationCore
import XCTest
@testable import DictationAudio

/// A take opens the microphone at its key-down, not before, and reads it the
/// way the device delivers it.
///
/// Building an AVAudioEngine graph after every key-down cost ~135 ms before
/// the device even started; a HAL I/O proc is live in ~48 ms. It hands over
/// the device's own format, interleaved and at the device's rate, which the
/// engine used to normalize for us. Opening it is a call into Core Audio that
/// can wedge, so it happens on the contained start lane and never on the
/// capture actor.
final class MicrophoneCaptureInputTests: XCTestCase {
    /// A microphone that records what it was asked to do.
    private final class FakeInput: CaptureInput, @unchecked Sendable {
        let format: AVAudioFormat
        private let lock = NSLock()
        private var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var onLost: (@Sendable () -> Void)?
        private var startCount = 0
        private var stopCount = 0

        init(format: AVAudioFormat) {
            self.format = format
        }

        var starts: Int { lock.withLock { startCount } }
        var stops: Int { lock.withLock { stopCount } }

        func install(
            _ handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
            onLost: @escaping @Sendable () -> Void
        ) {
            lock.withLock {
                self.handler = handler
                self.onLost = onLost
            }
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

        /// The device went away, or changed its format under the take.
        func deviceLost() {
            let onLost = lock.withLock { self.onLost }
            onLost?()
        }
    }

    /// Opens fake microphones. Can wedge one open call, or fail some.
    private final class Opener: @unchecked Sendable {
        let format: AVAudioFormat
        private let lock = NSLock()
        private var inputs: [Int: FakeInput] = [:]
        private var calls = 0
        private var wedgedCall: Int?
        private var wedge: DispatchSemaphore?
        private var failuresLeft = 0

        init(format: AVAudioFormat) {
            self.format = format
        }

        var openCalls: Int { lock.withLock { calls } }
        /// Every microphone opened so far, by the order its open was called.
        var opened: [FakeInput] {
            lock.withLock { inputs.keys.sorted().compactMap { inputs[$0] } }
        }
        func input(call: Int) -> FakeInput? { lock.withLock { inputs[call] } }

        func wedgeNextOpen(on semaphore: DispatchSemaphore) {
            lock.withLock {
                wedgedCall = calls + 1
                wedge = semaphore
            }
        }

        func failNextOpens(_ count: Int) {
            lock.withLock { failuresLeft = count }
        }

        func open(_ device: AudioDeviceID?) throws -> any CaptureInput {
            let (call, wedge, fails): (Int, DispatchSemaphore?, Bool) = lock.withLock {
                calls += 1
                let fails = failuresLeft > 0
                if fails { failuresLeft -= 1 }
                return (calls, calls == wedgedCall ? self.wedge : nil, fails)
            }
            wedge?.wait()
            if fails { throw AudioCaptureError.engineUnavailable("no microphone") }
            let input = FakeInput(format: format)
            lock.withLock { inputs[call] = input }
            return input
        }
    }

    private final class FailureLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(DictationSessionID, AudioCaptureError)] = []
        func append(_ session: DictationSessionID, _ error: AudioCaptureError) {
            lock.withLock { entries.append((session, error)) }
        }
        var all: [(DictationSessionID, AudioCaptureError)] { lock.withLock { entries } }
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

    /// One I/O cycle of a 440 Hz tone, at 0.5 on the first channel and at
    /// `otherChannels` times that on the rest.
    private func cycle(
        from start: Int,
        frames: Int,
        format: AVAudioFormat,
        otherChannels: Float = 1
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        let data = buffer.mutableAudioBufferList.pointee.mBuffers.mData!
            .assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            let t = Double(start + frame) / format.sampleRate
            let value = Float(0.5 * sin(2 * Double.pi * 440 * t))
            for channel in 0..<channels {
                data[frame * channels + channel] = channel == 0 ? value : value * otherChannels
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

    /// While a call holds voice processing, a Mac's built-in microphones are
    /// three interleaved channels. AVAudioFormat will not describe more than
    /// two without a layout, so the I/O proc gave up on the device, and the
    /// engine it fell back to recorded exact silence: every word of a take
    /// dictated during a call was lost.
    func testThreeMicrophonesUnderACallAreHeardThroughTheFirst() async throws {
        let description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 12,
            mFramesPerPacket: 1,
            mBytesPerFrame: 12,
            mChannelsPerFrame: 3,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let format = try XCTUnwrap(CaptureInputs.format(of: description), "the I/O proc describes three channels")
        XCTAssertEqual(format.channelCount, 3)
        XCTAssertTrue(format.isInterleaved)
        XCTAssertEqual(format.sampleRate, 48_000)

        let opener = Opener(format: format)
        let capture = MicrophoneCapture(directory: directory, openInput: opener.open)
        let session = DictationSessionID()
        let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
        let input = try XCTUnwrap(opener.opened.first)
        for start in stride(from: 0, to: 48_000, by: 512) {
            input.deliver(
                cycle(from: start, frames: min(512, 48_000 - start), format: format, otherChannels: 0.2),
                sampleTime: AVAudioFramePosition(start)
            )
        }
        let arrived = await capture.waitForFirstFrame()
        XCTAssertTrue(arrived)
        let recording = try await capture.freezeRecording(session: session, expectedURL: url)
        _ = try? await recording.durableURL()

        let samples = try XCTUnwrap(recording.samples)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 64, "one second at 16 kHz")
        let steady = samples.dropFirst(800).dropLast(800)
        let rms = (steady.reduce(0) { $0 + Double($1) * Double($1) } / Double(steady.count)).squareRoot()
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.02, "the first microphone, as itself")
    }

    /// Opening the device is a Core Audio call, and Core Audio calls wedge
    /// when coreaudiod is in trouble. Run on the capture actor, one wedged
    /// open held every later call behind it: the containment of that very
    /// take, and the next key-down's start.
    func testAMicrophoneThatNeverOpensDoesNotHoldTheNextTake() async throws {
        let wedge = DispatchSemaphore(value: 0)
        var wedgeReleased = false
        defer { if !wedgeReleased { wedge.signal() } }
        let opener = Opener(format: interleavedStereo)
        opener.wedgeNextOpen(on: wedge)
        let capture = MicrophoneCapture(directory: directory, openInput: opener.open)

        let stuck = DictationSessionID()
        let stuckStart = Task {
            try await capture.startRecording(session: stuck, disposition: RecordingDisposition())
        }
        try await waitUntil { opener.openCalls == 1 }

        let contained = expectation(description: "the wedged take is contained")
        Task {
            await capture.containRecording(session: stuck, expectedURL: nil)
            contained.fulfill()
        }
        let containment = await XCTWaiter.fulfillment(of: [contained], timeout: 1)
        if containment != .completed {
            // Open runs on the actor: let it go now, or the awaits below hang
            // instead of failing.
            XCTFail("a wedged open held the capture actor")
            wedge.signal()
            wedgeReleased = true
        }
        _ = try? await stuckStart.value

        let next = DictationSessionID()
        let started = expectation(description: "the next take starts")
        let nextStart = Task {
            defer { started.fulfill() }
            return try await capture.startRecording(session: next, disposition: RecordingDisposition())
        }
        await fulfillment(of: [started], timeout: 1)
        let url = try await nextStart.value
        let recording = try await capture.freezeRecording(session: next, expectedURL: url)
        _ = try? await recording.durableURL()

        // The wedged open finally returns, long after its take was contained.
        // Nobody owns that microphone: it must be closed, never started.
        wedge.signal()
        wedgeReleased = true
        try await waitUntil { opener.input(call: 1)?.stops == 1 }
        XCTAssertEqual(opener.input(call: 1)?.starts, 0, "a contained take's microphone never starts")
    }

    /// A microphone that cannot be opened must give back everything its take
    /// reserved, or two such failures leave every later take refused with
    /// "previous microphone shutdowns are still in progress".
    func testAMicrophoneThatCannotOpenGivesBackItsShutdownSlot() async throws {
        let opener = Opener(format: interleavedStereo)
        opener.failNextOpens(3)
        let capture = MicrophoneCapture(directory: directory, openInput: opener.open)

        for _ in 0..<3 {
            do {
                _ = try await capture.startRecording(
                    session: DictationSessionID(),
                    disposition: RecordingDisposition()
                )
                XCTFail("the open was meant to fail")
            } catch {
                XCTAssertEqual(error as? AudioCaptureError, .engineUnavailable("no microphone"))
            }
        }

        let session = DictationSessionID()
        let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
        let recording = try await capture.freezeRecording(session: session, expectedURL: url)
        _ = try? await recording.durableURL()
    }

    /// Without an engine there is no configuration-change notification for a
    /// microphone unplugged mid-take. The microphone itself says so, once,
    /// and only while its take is live.
    func testAMicrophoneThatDiesMidTakeReportsALiveFailure() async throws {
        let failures = FailureLog()
        let opener = Opener(format: interleavedStereo)
        let capture = MicrophoneCapture(
            directory: directory,
            onFailure: { failures.append($0, $1) },
            openInput: opener.open
        )

        let session = DictationSessionID()
        let url = try await capture.startRecording(session: session, disposition: RecordingDisposition())
        let input = try XCTUnwrap(opener.opened.first)
        input.deviceLost()
        input.deviceLost()
        try await waitUntil { failures.all.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(failures.all.count, 1, "one loss, one report")
        XCTAssertEqual(failures.all.first?.0, session)
        XCTAssertEqual(failures.all.first?.1, .deviceDisconnected)
        let recording = try await capture.freezeRecording(session: session, expectedURL: url)
        _ = try? await recording.durableURL()

        // After its take is frozen, the microphone has nobody to tell.
        let next = DictationSessionID()
        let nextURL = try await capture.startRecording(session: next, disposition: RecordingDisposition())
        let nextInput = try XCTUnwrap(opener.opened.last)
        let nextRecording = try await capture.freezeRecording(session: next, expectedURL: nextURL)
        _ = try? await nextRecording.durableURL()
        nextInput.deviceLost()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(failures.all.count, 1)
    }
}

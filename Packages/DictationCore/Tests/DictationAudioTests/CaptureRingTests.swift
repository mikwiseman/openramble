import AVFoundation
import CoreAudio
import XCTest
@testable import DictationAudio

/// The hand-off between the device's real-time thread and the capture.
///
/// What it must never do is the thing the dispatch queue it replaced did under
/// load: drop a cycle because the thread after it was late.
final class CaptureRingTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// One I/O cycle as the HAL hands it over: its own memory and timestamp.
    private final class Cycle {
        var samples: [Float]
        var list = AudioBufferList()
        var time = AudioTimeStamp()

        init(value: Float, frames: Int = 512, sampleTime: Double) {
            samples = [Float](repeating: value, count: frames)
            time.mSampleTime = sampleTime
            time.mFlags = .sampleTimeValid
        }

        func write(into ring: CaptureRing) {
            samples.withUnsafeMutableBytes { bytes in
                list.mNumberBuffers = 1
                list.mBuffers = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count),
                                            mData: bytes.baseAddress)
                ring.write(&list, at: &time)
            }
        }
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var cycles: [(first: Float, frames: Int, sampleTime: Double)] = []
        private var overflows = 0

        func add(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
            let first = buffer.floatChannelData?[0][0] ?? .nan
            lock.withLock { cycles.append((first, Int(buffer.frameLength), Double(time.sampleTime))) }
        }

        func overflowed() { lock.withLock { overflows += 1 } }

        var all: [(first: Float, frames: Int, sampleTime: Double)] { lock.withLock { cycles } }
        var overflowCount: Int { lock.withLock { overflows } }
    }

    private func worker(_ ring: CaptureRing, into received: Received) -> Thread {
        let thread = Thread {
            ring.run({ received.add($0, $1) }, onOverflow: { received.overflowed() })
        }
        thread.start()
        return thread
    }

    func testCyclesArriveInOrderWithTheirSamplesAndTimes() throws {
        let ring = try XCTUnwrap(CaptureRing(format: format, framesPerCycle: 512))
        let received = Received()
        _ = worker(ring, into: received)

        for index in 0..<50 {
            Cycle(value: Float(index), sampleTime: Double(index * 512)).write(into: ring)
        }
        ring.finish()

        let cycles = received.all
        XCTAssertEqual(cycles.count, 50)
        XCTAssertEqual(cycles.map(\.first), (0..<50).map(Float.init))
        XCTAssertEqual(cycles.map(\.sampleTime), (0..<50).map { Double($0 * 512) })
        XCTAssertTrue(cycles.allSatisfy { $0.frames == 512 })
    }

    /// The defect this exists for: a thread that is seconds late used to cost
    /// every cycle the device produced meanwhile. Now it costs only time.
    func testAWorkerThatStartsLateStillGetsEveryCycle() throws {
        let ring = try XCTUnwrap(CaptureRing(format: format, framesPerCycle: 512))
        let received = Received()
        for index in 0..<200 {
            Cycle(value: Float(index), sampleTime: Double(index * 512)).write(into: ring)
        }
        _ = worker(ring, into: received)
        ring.finish()

        XCTAssertEqual(received.all.map(\.first), (0..<200).map(Float.init))
        XCTAssertEqual(received.overflowCount, 0)
    }

    /// Past its capacity the ring says so, once, instead of recording a hole.
    func testOverflowIsReportedOnceAndWhatFitIsKept() throws {
        let ring = try XCTUnwrap(CaptureRing(format: format, framesPerCycle: 512))
        let received = Received()
        for index in 0..<(ring.slotCount + 10) {
            Cycle(value: Float(index), sampleTime: Double(index * 512)).write(into: ring)
        }
        _ = worker(ring, into: received)
        ring.finish()

        XCTAssertEqual(received.overflowCount, 1)
        XCTAssertEqual(received.all.map(\.first), (0..<ring.slotCount).map(Float.init))
    }

    /// About 2.7 s of a built-in microphone's 10.7 ms cycles, and a hard cap
    /// on memory for a device with many channels and long cycles.
    func testTheRingIsSizedByTimeAndCappedInMemory() throws {
        let microphone = try XCTUnwrap(CaptureRing(format: format, framesPerCycle: 512))
        XCTAssertEqual(microphone.slotCount, 253)

        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 32))
        let interface = AVAudioFormat(standardFormatWithSampleRate: 96_000, channelLayout: layout)
        let wide = try XCTUnwrap(CaptureRing(format: interface, framesPerCycle: 4_096))
        XCTAssertEqual(wide.slotCount, 16)
    }

    /// A start that fails and the stop after it both finish the ring; the
    /// second must not wait for a worker that has already gone.
    func testFinishingTwiceReturns() throws {
        let ring = try XCTUnwrap(CaptureRing(format: format, framesPerCycle: 512))
        _ = worker(ring, into: Received())
        ring.finish()
        let second = expectation(description: "second finish returns")
        DispatchQueue.global().async {
            ring.finish()
            second.fulfill()
        }
        wait(for: [second], timeout: 2)
    }

    /// Cycles larger than the device said it would deliver are cut to the
    /// slot, never written past it.
    func testAnOversizedCycleIsBoundedBySlotCapacity() throws {
        let ring = try XCTUnwrap(CaptureRing(format: format, framesPerCycle: 512))
        let received = Received()
        _ = worker(ring, into: received)
        Cycle(value: 1, frames: 4_096, sampleTime: 0).write(into: ring)
        ring.finish()

        XCTAssertEqual(received.all.map(\.frames), [1_024])
    }
}

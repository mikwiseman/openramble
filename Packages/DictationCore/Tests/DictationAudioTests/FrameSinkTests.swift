import XCTest
@testable import DictationAudio

/// A queue of frames between the audio stream and the disk.
///
/// Both defects that are guarded here are silent: the recording is obtained, the file
/// opens, and only the speech in it is not the same as what was said. Checked
/// a real recording in WAV, because it is she who can mix the frames.
final class FrameSinkTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Frame collector, repeating the work of the microphone: slow and on the actor.
    private actor Collector {
        private(set) var received: [Float] = []

        func consume(_ samples: [Float]) async {
            // Real writing to disk is not instantaneous, and it is at this pause
            // tasks overtook each other.
            try? await Task.sleep(for: .microseconds(50))
            received.append(contentsOf: samples)
        }
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testFramesArriveInTheOrderTheyWereProduced() async throws {
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = sink.start(capacity: 512) { await collector.consume($0) }

        // 400 frames in a row, each marked with its own number.
        let expected = (0..<400).map { Float($0) }
        for value in expected { enqueue([value]) }

        await sink.finish()

        let received = await collector.received
        XCTAssertEqual(received, expected, "\u{041A}\u{0430}\u{0434}\u{0440}\u{044B} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{043B}\u{0435}\u{0447}\u{044C} \u{0432} \u{0444}\u{0430}\u{0439}\u{043B} \u{0432} \u{0442}\u{043E}\u{043C} \u{0436}\u{0435} \u{043F}\u{043E}\u{0440}\u{044F}\u{0434}\u{043A}\u{0435}, \u{0432} \u{043A}\u{0430}\u{043A}\u{043E}\u{043C} \u{043F}\u{0440}\u{043E}\u{0437}\u{0432}\u{0443}\u{0447}\u{0430}\u{043B}\u{0438}")
    }

    func testOrderHoldsWhenFramesComeFromTheAudioThread() async throws {
        // The engine callback does not come from the thread where the actor lives.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = sink.start(capacity: 512) { await collector.consume($0) }

        let count = 300
        let done = expectation(description: "\u{0437}\u{0432}\u{0443}\u{043A}\u{043E}\u{0432}\u{043E}\u{0439} \u{043F}\u{043E}\u{0442}\u{043E}\u{043A} \u{043E}\u{0442}\u{0434}\u{0430}\u{043B} \u{0432}\u{0441}\u{0435} \u{043A}\u{0430}\u{0434}\u{0440}\u{044B}")
        Thread.detachNewThread {
            for index in 0..<count { enqueue([Float(index)]) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)

        await sink.finish()

        let received = await collector.received
        XCTAssertEqual(received, (0..<count).map { Float($0) })
    }

    func testFinishWaitsForTheLastFrame() async throws {
        // Tail of the phrase: the person releases the key exactly on the last word.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = sink.start(capacity: 256) { await collector.consume($0) }

        for index in 0..<200 { enqueue([Float(index)]) }
        await sink.finish()

        let received = await collector.received
        XCTAssertEqual(received.count, 200, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0438} \u{0432} \u{043E}\u{0447}\u{0435}\u{0440}\u{0435}\u{0434}\u{0438} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043D}\u{0438} \u{043E}\u{0434}\u{043D}\u{043E}\u{0433}\u{043E} \u{043A}\u{0430}\u{0434}\u{0440}\u{0430}")
        XCTAssertEqual(received.last, 199, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435}\u{0434}\u{043D}\u{0435}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E} \u{0442}\u{0435}\u{0440}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F} \u{043A}\u{0430}\u{043A} \u{0440}\u{0430}\u{0437} \u{0437}\u{0434}\u{0435}\u{0441}\u{044C}")
    }

    func testTailSurvivesIntoTheWAVFile() async throws {
        // The same thing, but until the very end: the file on disk must contain everything.
        let url = directory.appending(path: "take.wav")
        let writer = WAVWriter(url: url, sampleRate: 16_000, channels: 1)
        try writer.open()

        let sink = FrameSink()
        let enqueue = sink.start { samples in
            try? await Task.sleep(for: .microseconds(50))
            try? writer.append(samples)
        }

        // A second of sound in frames of 512 samples, as the engine produces.
        let frameCount = 16_000 / 512
        for _ in 0..<frameCount { enqueue(Array(repeating: 0.25, count: 512)) }

        await sink.finish()
        let closed = try writer.close()

        let size = try FileManager.default.attributesOfItem(atPath: closed.path)[.size] as? Int
        let expectedBytes = 44 + frameCount * 512 * 2
        XCTAssertEqual(size, expectedBytes, "\u{0424}\u{0430}\u{0439}\u{043B} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0430}\u{0442}\u{044C} \u{0432}\u{0441}\u{0435} \u{043A}\u{0430}\u{0434}\u{0440}\u{044B}, \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0430}\u{044F} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435}\u{0434}\u{043D}\u{0438}\u{0439}")
    }

    func testCancelDropsTheQueueInsteadOfWritingIt() async throws {
        // The dictation was canceled - there is nothing to add.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = sink.start { await collector.consume($0) }

        for index in 0..<500 { enqueue([Float(index)]) }
        sink.cancel()

        let received = await collector.received
        XCTAssertLessThan(received.count, 500, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0436}\u{0434}\u{0430}\u{0442}\u{044C} \u{0432}\u{0441}\u{044E} \u{043E}\u{0447}\u{0435}\u{0440}\u{0435}\u{0434}\u{044C}")
    }

    func testEnqueueAfterFinishIsHarmless() async throws {
        // The frame that came out of the iron simultaneously with the stop arrives already
        // after the queue is closed. You can't fall on this.
        let sink = FrameSink()
        let collector = Collector()
        let enqueue = sink.start { await collector.consume($0) }

        enqueue([1])
        await sink.finish()
        enqueue([2])

        let received = await collector.received
        XCTAssertEqual(received, [1])
    }

    func testBoundedQueueReportsOverflowOnceAndSealDoesNotWait() async throws {
        let sink = FrameSink()
        let gate = AsyncGate()
        let overflow = LockedCounter()
        let collector = Collector()
        let enqueue = sink.start(
            capacity: 2,
            onOverflow: { overflow.increment() },
            consume: { samples in
                await gate.wait()
                await collector.consume(samples)
            }
        )

        enqueue([0])
        // Let the drain take the first frame and block in the consumer.
        for _ in 0..<10 { await Task.yield() }
        for index in 1..<20 { enqueue([Float(index)]) }

        let drain = sink.seal()
        XCTAssertEqual(overflow.value, 1, "one full queue is one recording failure")

        // `seal` has already returned although the consumer is deliberately
        // blocked. Opening the gate only lets the detached durability work end.
        await gate.open()
        await drain.value
        let received = await collector.received
        XCTAssertLessThanOrEqual(received.count, 3, "the queue must remain physically bounded")
    }

    func testOldDrainCompletionCannotEraseTheNextSession() async throws {
        let sink = FrameSink()
        let oldGate = AsyncGate()
        let oldCollector = Collector()
        let first = sink.start { samples in
            await oldGate.wait()
            await oldCollector.consume(samples)
        }
        first([1])
        for _ in 0..<10 { await Task.yield() }
        let oldDrain = sink.seal()

        let newCollector = Collector()
        let second = sink.start { await newCollector.consume($0) }
        second([42])
        await sink.finish()

        await oldGate.open()
        await oldDrain.value
        let received = await newCollector.received
        XCTAssertEqual(received, [42])
    }
}

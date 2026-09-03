import XCTest
@testable import DictationCore

final class MeetingTranscriptionQueueTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(MeetingSegmentRef, MeetingTranscriptionQueue.Outcome)] = []
        func record(_ segment: MeetingSegmentRef, _ outcome: MeetingTranscriptionQueue.Outcome) {
            lock.withLock { items.append((segment, outcome)) }
        }
        var outcomes: [MeetingTranscriptionQueue.Outcome] { lock.withLock { items.map(\.1) } }
        var segments: [MeetingSegmentRef] { lock.withLock { items.map(\.0) } }
    }

    private func ref(_ channel: MeetingChannel, _ start: Int, _ count: Int = 16_000) -> MeetingSegmentRef {
        MeetingSegmentRef(channel: channel, startFrame: start, frameCount: count)
    }

    /// The samples "read" encode which segment they came from, so the decode
    /// can prove the queue handed it the right audio.
    private static func read(_ segment: MeetingSegmentRef) -> [Float] {
        [Float(segment.startFrame)]
    }

    func testSegmentsAreDecodedInOrderWithTheirOwnAudio() async {
        let recorder = Recorder()
        let queue = MeetingTranscriptionQueue(
            read: { Self.read($0) },
            decode: { samples in "text@\(Int(samples[0]))" },
            awaitTurn: {},
            emit: { recorder.record($0, $1) }
        )
        for start in [0, 16_000, 32_000] { await queue.submit(ref(.microphone, start)) }
        await queue.drain()
        XCTAssertEqual(recorder.outcomes, [
            .decoded(text: "text@0"), .decoded(text: "text@16000"), .decoded(text: "text@32000"),
        ])
        let decoded = await queue.decodedFrames
        XCTAssertEqual(decoded[.microphone], 48_000)
        let backlog = await queue.backlog
        XCTAssertEqual(backlog, 0)
    }

    func testOneFailureIsOneFailedSegmentAndTheNextProceeds() async {
        let recorder = Recorder()
        let queue = MeetingTranscriptionQueue(
            read: { Self.read($0) },
            decode: { samples in
                if Int(samples[0]) == 16_000 { throw CocoaError(.fileReadCorruptFile) }
                return "ok"
            },
            awaitTurn: {},
            emit: { recorder.record($0, $1) }
        )
        for start in [0, 16_000, 32_000] { await queue.submit(ref(.microphone, start)) }
        await queue.drain()
        let outcomes = recorder.outcomes
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(outcomes[0], .decoded(text: "ok"))
        if case .failed = outcomes[1] {} else { XCTFail("the middle one failed: \(outcomes[1])") }
        XCTAssertEqual(outcomes[2], .decoded(text: "ok"), "the queue did not stop")
        let paused = await queue.isPaused
        XCTAssertFalse(paused)
    }

    func testThreeFailuresInARowPauseTheQueueAndResumeTakesTheHeldOnesUp() async {
        let recorder = Recorder()
        let failing = UncheckedBox(true)
        let queue = MeetingTranscriptionQueue(
            read: { Self.read($0) },
            decode: { _ in
                if failing.value { throw CocoaError(.fileReadCorruptFile) }
                return "ok"
            },
            awaitTurn: {},
            emit: { recorder.record($0, $1) }
        )
        for start in [0, 16_000, 32_000, 48_000, 64_000] { await queue.submit(ref(.microphone, start)) }
        await queue.drain()
        let paused = await queue.isPaused
        XCTAssertTrue(paused)
        XCTAssertEqual(recorder.outcomes.count, 3, "the fourth and fifth are held, not failed")
        let backlog = await queue.backlog
        XCTAssertEqual(backlog, 2)

        failing.value = false
        await queue.resume()
        await queue.drain()
        XCTAssertEqual(recorder.outcomes.count, 5)
        XCTAssertEqual(recorder.outcomes.suffix(2), [.decoded(text: "ok"), .decoded(text: "ok")])
        XCTAssertEqual(recorder.segments.suffix(2).map(\.startFrame), [48_000, 64_000], "in their original order")
    }

    func testADecodeWaitsForItsTurn() async throws {
        let recorder = Recorder()
        let gate = EngineArbiter(engineReady: true)
        await gate.setDictationActive(true)
        let queue = MeetingTranscriptionQueue(
            read: { Self.read($0) },
            decode: { _ in "ok" },
            awaitTurn: { await gate.awaitMeetingTurn() },
            emit: { recorder.record($0, $1) }
        )
        await queue.submit(ref(.system, 0))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.outcomes, [], "nothing decodes while dictation holds the engine")
        await gate.setDictationActive(false)
        await queue.drain()
        XCTAssertEqual(recorder.outcomes, [.decoded(text: "ok")])
    }

    func testAWedgedDecodeIsCutOffAtTheDeadline() async {
        let recorder = Recorder()
        let queue = MeetingTranscriptionQueue(
            read: { Self.read($0) },
            decode: { _ in
                try await Task.sleep(for: .seconds(10))
                return "never"
            },
            awaitTurn: {},
            emit: { recorder.record($0, $1) },
            deadline: { _ in .milliseconds(50) }
        )
        await queue.submit(ref(.microphone, 0))
        await queue.drain()
        XCTAssertEqual(recorder.outcomes.count, 1)
        if case .failed = recorder.outcomes[0] {} else { XCTFail("expected a timeout failure") }
    }

    func testAReadFailureIsAFailedSegmentNotACrash() async {
        let recorder = Recorder()
        let queue = MeetingTranscriptionQueue(
            read: { _ in throw CocoaError(.fileNoSuchFile) },
            decode: { _ in "ok" },
            awaitTurn: {},
            emit: { recorder.record($0, $1) }
        )
        await queue.submit(ref(.microphone, 0))
        await queue.drain()
        if case .failed = recorder.outcomes.first {} else { XCTFail("expected a failure") }
    }

    func testAnEmptySegmentIsIgnored() async {
        let recorder = Recorder()
        let queue = MeetingTranscriptionQueue(
            read: { Self.read($0) }, decode: { _ in "ok" }, awaitTurn: {}, emit: { recorder.record($0, $1) }
        )
        await queue.submit(ref(.microphone, 0, 0))
        await queue.drain()
        XCTAssertEqual(recorder.outcomes, [])
    }
}

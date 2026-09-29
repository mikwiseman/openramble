import XCTest
@testable import DictationCore

@MainActor
final class LongDictationReliabilityTests: XCTestCase {
    func testHealthyFreezePastHalfASecondStillInserts() async throws {
        try await assertSlowStopSucceeds(freeze: .milliseconds(800), readable: .zero)
    }

    func testHealthyWAVPublicationPastTwoSecondsStillInserts() async throws {
        try await assertSlowStopSucceeds(freeze: .zero, readable: .milliseconds(2500))
    }

    func testReportsTheActualFailedStageWithoutAnErrorDescription() async throws {
        for stage in [DictationFailureStage.captureFreeze, .readableFile] {
            let capture = Capture(freeze: stage == .captureFreeze ? .seconds(1) : .zero,
                                  readable: stage == .readableFile ? .seconds(1) : .zero)
            let controller = DictationController(capture: capture,
                transcribe: { _ in XCTFail("timed-out take must not reach inference"); throw CancellationError() },
                inserter: FakeInserter(), overlay: FakeOverlay(), sounds: FakeSounds(),
                captureFreezeDeadline: .milliseconds(40), recordingReadableDeadline: .milliseconds(40))
            var failures: [(DictationFailureStage, Duration, Bool)] = []
            controller.onStageFailure = { failures.append(($0, $1, $2)) }
            controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
            try await waitUntil { controller.state == .listening }
            controller.stop()
            try await waitUntil { controller.state == .idle }
            XCTAssertEqual(failures.count, 1)
            XCTAssertEqual(failures.first?.0, stage)
            XCTAssertEqual(failures.first?.2, true)
            XCTAssertGreaterThanOrEqual(failures.first?.1 ?? .zero, .milliseconds(30))
        }
    }

    private func assertSlowStopSucceeds(freeze: Duration, readable: Duration) async throws {
        let capture = Capture(freeze: freeze, readable: readable)
        let inserter = FakeInserter()
        let controller = DictationController(capture: capture,
            transcribe: { _ in ASRResult(text: "complete take", audioDuration: 298, processingDuration: 0.01) },
            inserter: inserter, overlay: FakeOverlay(), sounds: FakeSounds())
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil { controller.state == .listening }
        controller.stop()
        try await waitUntil { controller.state == .idle }
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, ["Complete take"])
        XCTAssertFalse(notices.contains { $0.kind == .failure }, "healthy finalization must not be a failure")
    }

    func testCancelSkipsQueuedSegmentsAndDiscardsLateResult() async throws {
        let engine = GateEngine()
        let capture = Capture(segments: 3)
        let inserter = FakeInserter()
        let controller = DictationController(capture: capture,
            transcribe: { _ in XCTFail("cancelled recording must not fall back"); throw CancellationError() },
            transcribeSamples: { _ in await engine.run() },
            inserter: inserter, overlay: FakeOverlay(), sounds: FakeSounds())
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil {
            let calls = await engine.calls
            return controller.state == .listening && calls == 1
        }
        controller.cancel()
        try await waitUntil { controller.state == .idle }
        await engine.open()
        try await Task.sleep(for: .milliseconds(150))
        let calls = await engine.calls
        let inserted = await inserter.insertedTexts
        XCTAssertEqual(calls, 1, "Escape must not leave the old segment queue running")
        XCTAssertTrue(inserted.isEmpty)
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        try await waitUntil { controller.state == .listening }
        controller.stop()
        try await waitUntil { controller.state == .idle }
        let nextInserted = await inserter.insertedTexts
        XCTAssertEqual(nextInserted.count, 1, "the next dictation still completes")
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        let satisfied = await predicate()
        XCTAssertTrue(satisfied)
    }

    private actor GateEngine {
        var calls = 0
        private var gate: CheckedContinuation<Void, Never>?
        func run() async -> ASRResult {
            calls += 1
            if calls == 1 { await withCheckedContinuation { gate = $0 } }
            return ASRResult(text: "words", audioDuration: 4, processingDuration: 0.01)
        }
        func open() { gate?.resume(); gate = nil }
    }

    private actor Capture: AudioCapturing {
        let url = FileManager.default.temporaryDirectory.appending(path: "long-stop-\(UUID()).wav")
        let freeze: Duration
        let readable: Duration
        let segments: Int
        var sink: (@Sendable ([Float]) -> Void)?
        init(freeze: Duration = .zero, readable: Duration = .zero, segments: Int = 0) {
            self.freeze = freeze; self.readable = readable; self.segments = segments
        }
        func startRecording() async throws -> URL {
            try Data("test recording".utf8).write(to: url)
            for _ in 0..<segments { sink?([Float](repeating: 0.1, count: 4 * 16_000)) }
            return url
        }
        func setSegmentSink(_ sink: (@Sendable ([Float]) -> Void)?) { self.sink = sink }
        func stopRecording() async throws -> (url: URL, duration: TimeInterval) { (url, 298) }
        func freezeRecording() async throws -> CapturedRecording {
            try await Task.sleep(for: freeze)
            let url = url, delay = readable
            let ready = Task { try await Task.sleep(for: delay); return url }
            return CapturedRecording(url: url, duration: segments > 0 ? 16 : 298,
                samples: segments > 0 ? [Float](repeating: 0.1, count: 16 * 16_000) : nil,
                readableTask: ready, durableTask: ready, consumedSampleCount: segments * 4 * 16_000)
        }
        func abortRecording() async { try? FileManager.default.removeItem(at: url) }
    }
}

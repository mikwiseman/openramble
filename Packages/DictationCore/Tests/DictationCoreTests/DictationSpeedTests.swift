import XCTest
@testable import DictationCore

/// Speed ​​report: three marks from releasing the key.
@MainActor
final class DictationSpeedTests: XCTestCase {
    /// Inserter with mark script - you can't catch them from the outside.
    private actor MarkingInserter: TextInserting {
        private var marks: InsertionMarks
        private(set) var insertedTexts: [String] = []
        private var error: Error?

        init(marks: InsertionMarks) { self.marks = marks }

        func setError(_ error: Error) { self.error = error }

        func insert(_ text: String, into target: TargetApplication?) async throws {
            _ = try await insertReportingMarks(text, into: target)
        }

        func insertReportingMarks(
            _ text: String,
            into target: TargetApplication?
        ) async throws -> InsertionMarks {
            if let error { throw error }
            insertedTexts.append(text)
            return marks
        }

        func pressReturn() async throws {}
        nonisolated func frontmostApplication() -> TargetApplication? { nil }
    }

    /// Capture with scripted microphone warm-up.
    private actor TimedCapture: AudioCapturing {
        private let latency: Duration?
        private var url: URL?

        init(latency: Duration?) { self.latency = latency }

        func startRecording() async throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "speed-\(UUID().uuidString).wav")
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            self.url = url
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            guard let url else { throw AudioCaptureError.notRecording }
            return (url, 2)
        }

        func abortRecording() async {}
        func startupLatency() async -> Duration? { latency }
    }

    private actor DeferredStartCapture: AudioCapturing {
        private let gate: Gate
        private let url = FileManager.default.temporaryDirectory
            .appending(path: "deferred-speed-\(UUID().uuidString).wav")

        init(gate: Gate) { self.gate = gate }

        func startRecording() async throws -> URL {
            await gate.pass()
            FileManager.default.createFile(atPath: url.path, contents: Data([0]))
            return url
        }

        func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
            (url, 2)
        }

        func abortRecording() async {}
    }

    private func settle(_ iterations: Int = 20) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A clock that produces known moments in turn.
    private final class ScriptedClock: @unchecked Sendable {
        private let origin = ContinuousClock.now
        private var offsets: [Duration]
        private var index = 0
        private let lock = NSLock()

        init(offsets: [Duration]) { self.offsets = offsets }

        func next() -> ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            let offset = index < offsets.count ? offsets[index] : offsets.last ?? .zero
            index += 1
            return origin.advanced(by: offset)
        }

        func instant(at offset: Duration) -> ContinuousClock.Instant {
            origin.advanced(by: offset)
        }
    }

    func testSpeedIsMeasuredFromTheKeyRelease() async throws {
        // t0 = 0 ms (release), t1 = 120 ms (engine returned text).
        let clock = ScriptedClock(offsets: [.milliseconds(0), .milliseconds(120)])
        let inserter = MarkingInserter(
            marks: InsertionMarks(
                pasteDispatchedAt: clock.instant(at: .milliseconds(150)),
                clipboardRestoredAt: clock.instant(at: .milliseconds(1150))
            )
        )
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: .milliseconds(130)),
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let speed = try XCTUnwrap(report)
        XCTAssertEqual(speed.toRecognizedText, .milliseconds(120))
        XCTAssertEqual(speed.toPasteDispatched, .milliseconds(150))
        XCTAssertEqual(speed.toClipboardRestored, .milliseconds(1150))
        XCTAssertEqual(speed.microphoneStartup, .milliseconds(130))
    }

    func testReleaseDuringPreparingIsIncludedInStopToTextMetric() async throws {
        let gate = Gate()
        let inserter = MarkingInserter(marks: InsertionMarks())
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: DeferredStartCapture(gate: gate),
            transcribe: { _ in
                ASRResult(text: "measured", audioDuration: 2, processingDuration: 0)
            },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle(2)
        controller.stop()
        try await Task.sleep(for: .milliseconds(80))
        await gate.open()
        await settle(30)

        let speed = try XCTUnwrap(report)
        XCTAssertGreaterThanOrEqual(
            speed.toRecognizedText,
            .milliseconds(70),
            "a cold/blocked capture start after key release must not be hidden from telemetry"
        )
    }

    /// The marks are in order: text → insertion → buffer restoration.
    func testMarksAreOrdered() async throws {
        let clock = ScriptedClock(offsets: [.milliseconds(0), .milliseconds(120)])
        let inserter = MarkingInserter(
            marks: InsertionMarks(
                pasteDispatchedAt: clock.instant(at: .milliseconds(150)),
                clipboardRestoredAt: clock.instant(at: .milliseconds(1150))
            )
        )
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let speed = try XCTUnwrap(report)
        let paste = try XCTUnwrap(speed.toPasteDispatched)
        let restored = try XCTUnwrap(speed.toClipboardRestored)
        XCTAssertLessThanOrEqual(speed.toRecognizedText, paste)
        XCTAssertLessThanOrEqual(paste, restored)
    }

    /// Wall clocks do not affect the report at all.
    ///
    /// For this reason, separate monotonous clocks are set up: sleep, daylight savings
    /// time or NTP input in the middle of dictation would otherwise give a negative
    /// “stop → text”, that is, just a lie.
    func testReportIgnoresWallClockJumps() async throws {
        let clock = ScriptedClock(offsets: [.milliseconds(0), .milliseconds(120)])
        let wall = WallClockBox()
        let inserter = MarkingInserter(marks: InsertionMarks())
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in
                // While recognition is in progress, the “clock has been set” back an hour.
                wall.rewindAnHour()
                return ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            now: { wall.current },
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(try XCTUnwrap(report).toRecognizedText, .milliseconds(120))
    }

    /// The insertion failed - there is no honest number, no report.
    func testFailedInsertionProducesNoReport() async throws {
        let inserter = MarkingInserter(marks: InsertionMarks())
        await inserter.setError(TextInsertionError.secureInputActive)
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertNil(report)
    }

    /// An edge without dimension returns `nil`, not zero: it is not instantaneous.
    func testUnmeasuredEdgesReportNilNotZero() async throws {
        let inserter = MarkingInserter(marks: InsertionMarks())
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: TimedCapture(latency: nil),
            transcribe: { _ in ASRResult(text: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let speed = try XCTUnwrap(report)
        XCTAssertNil(speed.toPasteDispatched)
        XCTAssertNil(speed.toClipboardRestored)
        XCTAssertNil(speed.microphoneStartup)
    }

    /// The default implementation doesn't pretend to measure and inserts exactly once.
    func testDefaultInsertReportingMarksCallsInsertExactlyOnce() async throws {
        let plain = PlainInserter()
        let marks = try await plain.insertReportingMarks("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", into: nil)
        XCTAssertNil(marks.pasteDispatchedAt)
        XCTAssertNil(marks.clipboardRestoredAt)
        let count = await plain.insertCount
        XCTAssertEqual(count, 1, "\u{043D}\u{0438} \u{0440}\u{0435}\u{043A}\u{0443}\u{0440}\u{0441}\u{0438}\u{0438}, \u{043D}\u{0438} \u{0434}\u{0432}\u{043E}\u{0439}\u{043D}\u{043E}\u{0439} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0438}")
    }

    private actor PlainInserter: TextInserting {
        private(set) var insertCount = 0
        func insert(_ text: String, into target: TargetApplication?) async throws { insertCount += 1 }
        func pressReturn() async throws {}
        nonisolated func frontmostApplication() -> TargetApplication? { nil }
    }

    private final class WallClockBox: @unchecked Sendable {
        private var value = Date()
        private let lock = NSLock()
        var current: Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func rewindAnHour() {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(-3600)
        }
    }
}

// MARK: - Phase breakdown

/// One "stop → text" number cannot say which stage owned the wait, and the
/// three stages fail for entirely different reasons. These tests pin the
/// attribution, because a diagnosis built on a mislabelled stage is worse
/// than no diagnosis.
@MainActor
final class DictationPhaseBreakdownTests: XCTestCase {
    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private final class ScriptedClock: @unchecked Sendable {
        private let origin = ContinuousClock.now
        private let offsets: [Duration]
        private var index = 0
        private let lock = NSLock()

        init(offsets: [Duration]) { self.offsets = offsets }

        func next() -> ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            let offset = index < offsets.count ? offsets[index] : offsets.last ?? .zero
            index += 1
            return origin.advanced(by: offset)
        }
    }

    /// A cold engine is not a slow engine. The stage that waited for the model
    /// must carry the seconds, and recognition must keep only its own.
    func testPreparationWaitIsAttributedToPreparationNotToRecognition() async throws {
        // stop = 0 ms, capture frozen = 40 ms, model ready = 8040 ms,
        // text returned = 8100 ms.
        let clock = ScriptedClock(offsets: [
            .milliseconds(0), .milliseconds(40), .milliseconds(8040), .milliseconds(8100),
        ])
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in
                ASRResult(text: "words", audioDuration: 2, processingDuration: 0.05)
            },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            monotonicNow: { clock.next() },
            prepareForTranscription: {}
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let phases = try XCTUnwrap(try XCTUnwrap(report).phases)
        XCTAssertEqual(phases.captureFreeze, .milliseconds(40))
        XCTAssertEqual(phases.enginePreparation, .milliseconds(8000))
        XCTAssertEqual(phases.recognition, .milliseconds(60))
        XCTAssertEqual(phases.engineProcessing, .milliseconds(50))
        XCTAssertEqual(phases.audioDuration, .seconds(2))
    }

    /// Without a preparation hook there is no preparation stage to report, and
    /// recognition owns everything after the freeze. Absent, never zero: a zero
    /// would claim a stage ran instantly.
    func testNoPreparationHookLeavesTheStageAbsentAndRecognitionWhole() async throws {
        let clock = ScriptedClock(offsets: [
            .milliseconds(0), .milliseconds(30), .milliseconds(230),
        ])
        var report: DictationSpeedReport?
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in
                ASRResult(text: "words", audioDuration: 1, processingDuration: 0.2)
            },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            monotonicNow: { clock.next() }
        )
        controller.onSpeed = { report = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let phases = try XCTUnwrap(try XCTUnwrap(report).phases)
        XCTAssertNil(phases.enginePreparation)
        XCTAssertEqual(phases.captureFreeze, .milliseconds(30))
        XCTAssertEqual(phases.recognition, .milliseconds(200))
    }

    /// A finished engine must not hide time spent waiting to return to the
    /// main actor. The fake returns only after the main actor has synchronously
    /// entered a bounded hold, so this does not rely on task ordering or sleep
    /// long enough and hope.
    func testReturnWaitIsAttributedToMainActorNotTheEngineOrPool() async throws {
        let capture = FakeCapture()
        await capture.setBufferedSamples([0.1, 0.2])
        let engineReached = Gate()
        let mainHoldStarted = SynchronousSignal()
        let hold = Duration.milliseconds(500)
        let reported = expectation(description: "speed reported")
        var report: DictationSpeedReport?

        Task { @MainActor in
            await engineReached.pass()
            mainHoldStarted.signal()
            usleep(500_000)
        }

        let controller = DictationController(
            capture: capture,
            transcribe: { _ in
                XCTFail("the in-memory path must not read the recording file")
                return ASRResult(text: "wrong path", audioDuration: 2, processingDuration: 0)
            },
            transcribeSamples: { _ in
                try? await Task.sleep(for: .milliseconds(200))
                await engineReached.open()
                await mainHoldStarted.wait()
                return ASRResult(text: "words", audioDuration: 2, processingDuration: 0.2)
            },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
        controller.onSpeed = {
            report = $0
            reported.fulfill()
        }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await fulfillment(of: [reported], timeout: 10)

        let phases = try XCTUnwrap(try XCTUnwrap(report).phases)
        XCTAssertNil(phases.recordingReadable, "the test must take the in-memory path")
        let mainReturn = try XCTUnwrap(phases.mainActorReturn)
        let poolReturn = try XCTUnwrap(phases.poolReturn)
        XCTAssertEqual(phases.returnFrameWasMainThread, false)
        XCTAssertGreaterThanOrEqual(mainReturn, hold / 2)
        XCTAssertLessThan(poolReturn, hold / 4)
        XCTAssertLessThan(try XCTUnwrap(phases.executorHandover), hold / 4)
        XCTAssertEqual(phases.engineProcessing, .milliseconds(200))
    }
}

// MARK: - Waiting for the model

/// The panel is the only feedback channel during dictation. A stop-time model
/// load spends its whole length in the transcribing state, so the controller
/// has to say which of the two is happening — but only when the distinction is
/// visible to a person, never as a flicker on the warm path.
@MainActor
final class EnginePreparationWaitTests: XCTestCase {
    private func settle(_ rounds: Int = 60) async {
        for _ in 0..<rounds {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A load long enough to be noticed is announced, and retracted once the
    /// model is there.
    func testALongModelWaitIsAnnouncedAndThenRetracted() async throws {
        let announcements = Box<[Bool]>([])
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in ASRResult(text: "words", audioDuration: 1, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            prepareForTranscription: { try await Task.sleep(for: .milliseconds(220)) },
            enginePreparationNoticeDelay: .milliseconds(20)
        )
        controller.onEnginePreparationWait = { announcements.value.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(announcements.value, [true, false])
    }

    /// A resident engine answers immediately. Flipping the panel for every take
    /// would be a flicker on the path almost every dictation takes.
    func testAWarmEngineNeverMentionsWaiting() async throws {
        let announcements = Box<[Bool]>([])
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in ASRResult(text: "words", audioDuration: 1, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            prepareForTranscription: {},
            enginePreparationNoticeDelay: .milliseconds(400)
        )
        controller.onEnginePreparationWait = { announcements.value.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertTrue(announcements.value.isEmpty)
    }

    /// A load that fails still has to take its message back. Leaving "Waking
    /// the model…" on screen would outlive the take that owns it.
    func testAFailedPreparationRetractsItsAnnouncement() async throws {
        struct PreparationFailed: Error {}
        let announcements = Box<[Bool]>([])
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in ASRResult(text: "words", audioDuration: 1, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            prepareForTranscription: {
                try await Task.sleep(for: .milliseconds(60))
                throw PreparationFailed()
            },
            enginePreparationNoticeDelay: .milliseconds(10)
        )
        controller.onEnginePreparationWait = { announcements.value.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertEqual(announcements.value.last, false, "the panel never keeps a stale wait")
        XCTAssertEqual(announcements.value.filter { $0 }.count, 1)
    }
}

/// A reference box so a `@Sendable` callback can record what it saw.
private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// A cross-executor signal whose `signal()` never suspends its caller.
///
/// The main-actor attribution test needs the actor to remain continuously
/// occupied from the signal until the hold ends. An actor-based gate would
/// yield at `open()` and make the test prove the opposite schedule.
private final class SynchronousSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        fired = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

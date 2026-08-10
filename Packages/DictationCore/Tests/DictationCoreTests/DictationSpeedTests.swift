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

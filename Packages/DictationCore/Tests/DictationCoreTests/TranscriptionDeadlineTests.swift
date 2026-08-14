import XCTest
@testable import DictationCore

/// The deadline that turns a wedged engine into a bounded, recoverable
/// failure instead of an eternal "Transcribing…".
final class TranscriptionDeadlineTests: XCTestCase {
    // MARK: - Policy

    /// Short dictations are bounded tightly; long recordings still scale with
    /// their measured window count rather than with real time.
    func testDeadlineScalesWithAudioButNeverDropsBelowFloor() {
        XCTAssertEqual(TranscriptionDeadline.deadline(forAudioDuration: 0), .seconds(3))
        XCTAssertEqual(TranscriptionDeadline.deadline(forAudioDuration: 3), .seconds(3))
        XCTAssertEqual(TranscriptionDeadline.deadline(forAudioDuration: 30), .seconds(3))
        XCTAssertEqual(TranscriptionDeadline.deadline(forAudioDuration: 90), .seconds(3))
        XCTAssertEqual(TranscriptionDeadline.deadline(forAudioDuration: 180), .seconds(6))
        XCTAssertEqual(TranscriptionDeadline.deadline(forAudioDuration: 1800), .seconds(60))
    }

    // MARK: - Race

    func testFastOperationWinsUntouched() async throws {
        let value = try await withTranscriptionDeadline(.seconds(5)) { "done" }
        XCTAssertEqual(value, "done")
    }

    func testOperationErrorPropagatesAsItself() async {
        struct Boom: Error, Equatable {}
        do {
            _ = try await withTranscriptionDeadline(.seconds(5)) { () -> Int in
                throw Boom()
            }
            XCTFail("expected the operation's own error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    /// The premise of the whole mechanism: an operation that ignores
    /// cancellation and never returns must not hold the caller hostage.
    func testWedgedOperationTimesOutPromptly() async {
        let started = ContinuousClock.now
        do {
            // Deliberately shrugs off cancellation, like a stuck CoreML call.
            _ = try await withTranscriptionDeadline(.milliseconds(80)) { () -> Int in
                try await suspendForever()
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue(error is TranscriptionTimeout, "got \(error)")
        }
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(5), "the caller must be free at the deadline, not at the operation's mercy")
    }

    /// Escape keeps its meaning: caller cancellation resolves the wait as
    /// cancellation, not as a timeout.
    func testCallerCancellationResolvesAsCancellation() async {
        let task = Task { () -> Int in
            try await withTranscriptionDeadline(.seconds(30)) { () -> Int in
                try await suspendForever()
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected cancellation")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    /// A race entered by an already-cancelled task must not spawn an
    /// uncancellable copy of the operation.
    func testAlreadyCancelledCallerNeverStartsTheOperation() async {
        let ran = UncheckedBox(false)
        let task = Task { () -> Int in
            try Task.checkCancellation()
            return try await withTranscriptionDeadline(.seconds(30)) { () -> Int in
                ran.value = true
                return 1
            }
        }
        task.cancel()
        _ = await task.result
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(ran.value)
    }
}

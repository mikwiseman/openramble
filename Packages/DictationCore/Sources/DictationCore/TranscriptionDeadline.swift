import Foundation

/// How long recognition may run before the session declares it wedged.
///
/// The engine normally runs many times faster than real time, but it sits on
/// system services that can die under it — a CoreML/ANE prediction stuck on a
/// restarted daemon blocks its `await` forever, and the person stares at
/// "Transcribing…" with no way out but Escape, which throws their words away.
/// The deadline converts that infinite hang into a bounded failure that keeps
/// the recording.
public enum TranscriptionDeadline {
    /// This is a backstop against a dead system service, not a performance
    /// budget — and the difference is the whole point.
    ///
    /// It used to be three seconds, derived from a warm recognizer running
    /// over 100x real time. That reasoning measured the best case and then
    /// spent it: a take that ran slowly for an ordinary reason — the machine
    /// paging the model back in, another application holding the accelerator,
    /// a Mac with 8 GB of memory — blew a budget calibrated on the good day,
    /// and the words were withheld from someone whose engine was working
    /// perfectly. Worse, the failure destroyed the loaded model, so the next
    /// take started cold and was even more likely to miss the same bound. A
    /// slow machine got a spiral instead of a slow result.
    ///
    /// Wedge detection belongs to the watchdog that can see whether the
    /// recognizer is burning CPU; time alone cannot tell a slow Mac from a
    /// broken one. What remains here is a far ceiling, generous enough that no
    /// healthy machine can reach it and small enough that a truly dead call
    /// still ends in a recoverable failure rather than an eternal panel.
    public static func deadline(forAudioDuration duration: TimeInterval) -> Duration {
        .seconds(max(120, duration * 2))
    }
}

/// Recognition exceeded its deadline. The engine is presumed wedged.
public struct TranscriptionTimeout: Error, Equatable, Sendable {
    public let deadline: Duration

    public init(deadline: Duration) {
        self.deadline = deadline
    }
}

/// First-to-finish claim between the operation and its watchdog.
private final class ResumeClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Thread-safe ownership of the two unstructured tasks in the race.
///
/// Cancellation can arrive between constructing the tasks and publishing
/// their handles. Remembering that cancellation under the same lock ensures
/// late publication cancels them immediately instead of leaving a detached,
/// cancellation-deaf CoreML call behind due to a data race.
private final class DeadlineTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var work: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var cancellationRequested = false

    func install(work: Task<Void, Never>, watchdog: Task<Void, Never>) {
        lock.lock()
        self.work = work
        self.watchdog = watchdog
        let cancelImmediately = cancellationRequested
        lock.unlock()

        if cancelImmediately {
            work.cancel()
            watchdog.cancel()
        }
    }

    func cancelWork() {
        lock.lock()
        let task = work
        lock.unlock()
        task?.cancel()
    }

    func cancelAll() {
        lock.lock()
        cancellationRequested = true
        let work = work
        let watchdog = watchdog
        lock.unlock()
        work?.cancel()
        watchdog?.cancel()
    }
}

/// Race an operation against a deadline without inheriting its fate.
///
/// A structured race (`withThrowingTaskGroup`) waits for every child before
/// returning — exactly what must not happen when the child is a CoreML call
/// stuck on a dead service and ignoring cancellation. The loser here is
/// cancelled best-effort and abandoned: it finishes into the void whenever
/// the system lets it.
///
/// Caller cancellation keeps its meaning: Escape resolves the wait promptly
/// with `CancellationError`, exactly as it did without the deadline.
public func withTranscriptionDeadline<T: Sendable>(
    _ deadline: Duration,
    clock: ContinuousClock = ContinuousClock(),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // A caller cancelled before the race starts must not spawn an
    // uncancellable copy of the operation.
    try Task.checkCancellation()

    let claim = ResumeClaim()
    let tasks = DeadlineTasks()

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let watchdog = Task {
                try? await clock.sleep(for: deadline)
                guard claim.claim() else { return }
                tasks.cancelWork()
                if Task.isCancelled {
                    // Woken by the caller's cancellation, not the deadline.
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: TranscriptionTimeout(deadline: deadline))
                }
            }
            let work = Task {
                do {
                    let value = try await operation()
                    guard claim.claim() else { return }
                    watchdog.cancel()
                    continuation.resume(returning: value)
                } catch {
                    guard claim.claim() else { return }
                    watchdog.cancel()
                    continuation.resume(throwing: error)
                }
            }
            tasks.install(work: work, watchdog: watchdog)
        }
    } onCancel: {
        tasks.cancelAll()
    }
}

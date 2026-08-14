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
    /// A warm recognizer is over 100x real time on long audio and finishes a
    /// short dictation in well under a second. Three seconds leaves ample p99
    /// headroom for recordings up to ninety seconds while turning the old
    /// twenty-second apparent freeze into a bounded recovery. Longer takes get
    /// one second per thirty seconds of audio.
    public static func deadline(forAudioDuration duration: TimeInterval) -> Duration {
        .seconds(max(3, duration / 30))
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

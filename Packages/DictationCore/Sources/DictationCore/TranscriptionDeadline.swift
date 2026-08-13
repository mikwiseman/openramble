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
    /// Twice real time, never below twenty seconds: generous enough that no
    /// healthy transcription ever meets it, proportional so an hour-long
    /// recording gets an hour-scale budget.
    public static func deadline(forAudioDuration duration: TimeInterval) -> Duration {
        .seconds(max(20, duration * 2))
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
    let tasks = UncheckedBox<(work: Task<Void, Never>?, watchdog: Task<Void, Never>?)>((nil, nil))

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let watchdog = Task {
                try? await clock.sleep(for: deadline)
                guard claim.claim() else { return }
                tasks.value.work?.cancel()
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
            tasks.value = (work, watchdog)
        }
    } onCancel: {
        tasks.value.watchdog?.cancel()
        tasks.value.work?.cancel()
    }
}

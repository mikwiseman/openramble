import Foundation

public enum BackgroundSchedulerError: Error, Equatable, Sendable {
    case queueFull(maximum: Int)
    case preemptedByInteractiveWork
    case shuttingDown
}

/// A synchronously visible reservation. Dictation raises it in the same turn
/// that changes state to `.preparing`, before capture starts asynchronously.
public final class InteractiveReservation: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved = false

    public init() {}

    public var isReserved: Bool {
        lock.withLock { reserved }
    }

    public func begin() {
        lock.withLock { reserved = true }
    }

    public func end() {
        lock.withLock { reserved = false }
    }
}

/// Serializes background inference while live dictation bypasses this queue.
/// A running Core ML prediction may ignore cancellation; it remains the only
/// background job until it drains, while interactive work proceeds directly.
public actor BackgroundScheduler<Output: Sendable> {
    public typealias Operation = @Sendable () async throws -> Output

    private struct Pending: Sendable {
        let id: UUID
        let enqueuedAt: ContinuousClock.Instant
        let operation: Operation
        let continuation: CheckedContinuation<(Output, Duration), Error>
    }

    private enum CancellationReason {
        case client
        case interactive
    }

    private let maximumQueued: Int
    private let reservation: InteractiveReservation
    private var pending: [Pending] = []
    private var active: Pending?
    private var activeTask: Task<Output, Error>?
    private var activeQueueWait: Duration?
    private var activeCancellation: CancellationReason?
    private var isShuttingDown = false

    public init(maximumQueued: Int, reservation: InteractiveReservation) {
        precondition(maximumQueued > 0)
        self.maximumQueued = maximumQueued
        self.reservation = reservation
    }

    public var queuedCount: Int { pending.count }
    public var isBusy: Bool { active != nil || !pending.isEmpty }
    public nonisolated var isInteractiveReserved: Bool { reservation.isReserved }

    public func submit(
        id: UUID = UUID(),
        operation: @escaping Operation
    ) async throws -> (output: Output, queueWait: Duration) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    Pending(
                        id: id,
                        enqueuedAt: .now,
                        operation: operation,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    public nonisolated func beginInteractiveWork() {
        reservation.begin()
        Task { await self.preemptActiveForInteractiveWork() }
    }

    public nonisolated func endInteractiveWork() {
        reservation.end()
        Task { await self.startNextIfPossible() }
    }

    /// Wait until the cancelled background operation has actually released
    /// the recognizer. Some Core ML calls observe cancellation only after the
    /// current prediction returns; letting live dictation enter before then
    /// would make the two requests contend for the same engine.
    public func waitUntilInteractiveReady() async throws {
        try Task.checkCancellation()
        if let activeTask {
            _ = await activeTask.result
        }
        try Task.checkCancellation()
    }

    public func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        activeTask?.cancel()
        for job in pending {
            job.continuation.resume(throwing: BackgroundSchedulerError.shuttingDown)
        }
        pending.removeAll()
    }

    private func enqueue(_ job: Pending) {
        guard !isShuttingDown else {
            job.continuation.resume(throwing: BackgroundSchedulerError.shuttingDown)
            return
        }
        guard pending.count < maximumQueued else {
            job.continuation.resume(
                throwing: BackgroundSchedulerError.queueFull(maximum: maximumQueued)
            )
            return
        }
        pending.append(job)
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard active == nil, !pending.isEmpty, !reservation.isReserved, !isShuttingDown else {
            return
        }
        let job = pending.removeFirst()
        active = job
        activeQueueWait = job.enqueuedAt.duration(to: .now)
        activeCancellation = nil
        let task = Task { try await job.operation() }
        activeTask = task
        Task {
            let result = await task.result
            finish(job: job, result: result)
        }
    }

    private func finish(job: Pending, result: Result<Output, Error>) {
        guard active?.id == job.id else { return }
        let reason = activeCancellation
        let queueWait = activeQueueWait ?? .zero
        active = nil
        activeTask = nil
        activeQueueWait = nil
        activeCancellation = nil

        switch reason {
        case .client:
            job.continuation.resume(throwing: CancellationError())
        case .interactive:
            job.continuation.resume(
                throwing: BackgroundSchedulerError.preemptedByInteractiveWork
            )
        case nil:
            job.continuation.resume(
                with: result.map { ($0, queueWait) }
            )
        }
        startNextIfPossible()
    }

    private func cancel(id: UUID) {
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let job = pending.remove(at: index)
            job.continuation.resume(throwing: CancellationError())
            return
        }
        guard active?.id == id else { return }
        activeCancellation = .client
        activeTask?.cancel()
    }

    private func preemptActiveForInteractiveWork() {
        guard active != nil else { return }
        if activeCancellation == nil { activeCancellation = .interactive }
        activeTask?.cancel()
    }
}

import AVFoundation
import DictationCore
import Foundation
import os

struct FrozenPCM: Sendable {
    let samples: [Float]?
    let totalSamples: Int
    let firstFrameAt: ContinuousClock.Instant?
    /// `true` means foreground cancellation won before the one and only PCM
    /// snapshot was handed off. A bounded recovery task must claim it later.
    /// A normal (even empty or disk-only) freeze is already the sole snapshot
    /// owner and must never ask the buffer for a second, empty snapshot.
    fileprivate let recoverySnapshotPending: Bool

    init(
        samples: [Float]?,
        totalSamples: Int,
        firstFrameAt: ContinuousClock.Instant?,
        recoverySnapshotPending: Bool = false
    ) {
        self.samples = samples
        self.totalSamples = totalSamples
        self.firstFrameAt = firstFrameAt
        self.recoverySnapshotPending = recoverySnapshotPending
    }
}

/// A frame gets its ordering identity before conversion starts. `sampleTime`
/// is comparable only with other valid timestamps produced by the same tap;
/// `ingressSequence` remains the total-order fallback for the whole session.
struct RecordingPCMFrame: Sendable {
    fileprivate let ingressSequence: UInt64
    fileprivate let sampleTime: AVAudioFramePosition?
}

/// Retains the converter-owned array without copying any previously captured
/// audio. Nodes are immutable after construction, so a detached freeze
/// snapshot can be flattened without holding the callback lock.
private final class RecordingPCMChunk: @unchecked Sendable {
    let frame: RecordingPCMFrame
    let samples: [Float]
    let next: RecordingPCMChunk?
    private let onRelease: (@Sendable () -> Void)?

    init(
        frame: RecordingPCMFrame,
        samples: [Float],
        next: RecordingPCMChunk?,
        onRelease: (@Sendable () -> Void)? = nil
    ) {
        self.frame = frame
        self.samples = samples
        self.next = next
        self.onRelease = onRelease
    }

    deinit { onRelease?() }
}

private struct RecordingPCMStorageSnapshot: Sendable {
    let head: RecordingPCMChunk?
    /// Keeps an overflowed/discarded chain alive until this off-callback
    /// snapshot is released. Dropping thousands of nodes from `append` would
    /// otherwise turn the cap transition into an O(n) real-time operation.
    let deferredReleaseHead: RecordingPCMChunk?
    let retainedSampleCount: Int
    let totalSamples: Int
    let firstFrameAt: ContinuousClock.Instant?
    let onFlatten: (@Sendable () -> Void)?

    /// Runs only from `freeze()` after the real-time callback barrier has
    /// resumed. This is the sole allocation/copy of the full recognition PCM.
    func flatten() -> FrozenPCM {
        guard let head, retainedSampleCount > 0 else {
            return FrozenPCM(
                samples: nil,
                totalSamples: totalSamples,
                firstFrameAt: firstFrameAt
            )
        }
        onFlatten?()

        var chunks: [RecordingPCMChunk] = []
        var cursor: RecordingPCMChunk? = head
        while let chunk = cursor {
            chunks.append(chunk)
            cursor = chunk.next
        }

        chunks.sort {
            $0.frame.ingressSequence < $1.frame.ingressSequence
        }
        // Timestamps are usable only if every callback belongs to one valid,
        // monotonic tap timeline. If AVFAudio ever presents an incomparable or
        // reset timeline, ingress is also the order used by the lossless WAV
        // commit, so PCM and recovery bytes remain identical.
        let sampleTimes = chunks.compactMap(\.frame.sampleTime)
        let timestampsAreComparable = sampleTimes.count == chunks.count
            && zip(sampleTimes, sampleTimes.dropFirst()).allSatisfy { $0 <= $1 }
        if timestampsAreComparable {
            chunks.sort { left, right in
                guard let leftTime = left.frame.sampleTime,
                      let rightTime = right.frame.sampleTime,
                      leftTime != rightTime else {
                    return left.frame.ingressSequence < right.frame.ingressSequence
                }
                return leftTime < rightTime
            }
        }

        var samples: [Float] = []
        samples.reserveCapacity(retainedSampleCount)
        for chunk in chunks {
            samples.append(contentsOf: chunk.samples)
        }
        precondition(samples.count == retainedSampleCount)
        return FrozenPCM(
            samples: samples,
            totalSamples: totalSamples,
            firstFrameAt: firstFrameAt
        )
    }
}

/// Strong references detached by destructive abort. Keeping this value alive
/// until a utility worker receives it prevents ARC from recursively releasing
/// thousands of immutable chunks on the capture actor.
private struct RecordingPCMDiscardedStorage: Sendable {
    let chunkHead: RecordingPCMChunk?
    let deferredReleaseHead: RecordingPCMChunk?
    let recoverySnapshot: RecordingPCMStorageSnapshot?

    var isEmpty: Bool {
        chunkHead == nil && deferredReleaseHead == nil && recoverySnapshot == nil
    }
}

/// Exactly one process-wide utility task releases destructively abandoned PCM
/// chains. New aborts coalesce into its pending batch instead of spawning one
/// task per Escape. The worker performs no I/O or external callbacks, so it
/// cannot inherit the permanently executing AVFAudio callback that retained
/// the old `RecordingPCMBuffer`.
final class RecordingPCMDiscardReleaseContainment: @unchecked Sendable {
    static let shared = RecordingPCMDiscardReleaseContainment()

    private let lock = NSLock()
    private var pending: [RecordingPCMDiscardedStorage] = []
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeDrainCount = 0
    private var maximumObservedDrainCount = 0

    fileprivate func submit(_ storage: RecordingPCMDiscardedStorage) {
        guard !storage.isEmpty else { return }
        let shouldLaunch: Bool = lock.withLock {
            pending.append(storage)
            guard !isDraining else { return false }
            isDraining = true
            activeDrainCount += 1
            maximumObservedDrainCount = max(maximumObservedDrainCount, activeDrainCount)
            return true
        }
        if shouldLaunch {
            Task.detached(priority: .utility) { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            let batch: [RecordingPCMDiscardedStorage] = lock.withLock {
                guard !pending.isEmpty else { return [] }
                let batch = pending
                pending.removeAll(keepingCapacity: true)
                return batch
            }
            guard !batch.isEmpty else {
                let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                    // `submit` cannot observe false between this transition and
                    // its own lock acquisition, so no storage can be stranded.
                    isDraining = false
                    activeDrainCount -= 1
                    precondition(activeDrainCount == 0)
                    let waiters = idleWaiters
                    idleWaiters.removeAll(keepingCapacity: false)
                    return waiters
                }
                for waiter in waiters { waiter.resume() }
                return
            }
            // Merely reaching the end of this scope drops the batch and every
            // historical chunk on this utility executor, never on capture/RT.
            withExtendedLifetime(batch) {}
        }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !isDraining, pending.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    var maximumConcurrentDrains: Int {
        lock.withLock { maximumObservedDrainCount }
    }
}

/// AVAudioNode documents that tap callbacks may run off-main, but does not
/// promise that a stateful `AVAudioConverter` is never entered concurrently.
/// Tokens are issued before conversion, then this zero-queue sequencer admits
/// exactly one conversion-and-lossless-commit turn at a time in session order.
/// Waiting occurs only when AVFAudio has already overlapped callbacks; the
/// common path is uncontended and never allocates or copies historical audio.
final class RecordingTapConversionSequencer: @unchecked Sendable {
    private let condition = NSCondition()
    private var nextSequence: UInt64 = 0
    private var isConverting = false
    private var isCancelled = false

    func perform<T>(
        frame: RecordingPCMFrame,
        _ conversion: () throws -> T
    ) throws -> T {
        condition.lock()
        while !isCancelled,
              (isConverting || frame.ingressSequence != nextSequence) {
            condition.wait()
        }
        guard !isCancelled else {
            condition.unlock()
            throw CancellationError()
        }
        isConverting = true
        condition.unlock()

        defer {
            condition.lock()
            isConverting = false
            nextSequence &+= 1
            condition.broadcast()
            condition.unlock()
        }
        return try conversion()
    }

    /// Releases callbacks waiting behind a converter that belongs to an
    /// abandoned session. The currently executing AVAudioConverter call is not
    /// force-cancelled; its later commit remains fenced to old session state.
    func cancelPending() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }
}

/// The UI notification is actor-hopped and may arrive after a stop has already
/// detached this session. Record conversion corruption synchronously in the
/// callback so the freeze barrier can never publish partial PCM as success.
final class RecordingCaptureFailureLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: AudioCaptureError?

    /// Returns true only for the first fatal error in this session.
    @discardableResult
    func record(_ error: AudioCaptureError) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return false }
        failure = error
        return true
    }

    var recordedFailure: AudioCaptureError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

struct RecordingWriterCloseReservation: Sendable, Hashable {
    fileprivate let id: UUID
}

/// Globally bounds every production writer descriptor across live, fsync, and
/// close/abandon states. One close may execute and one N+1 writer may remain
/// live or pending; once both slots are occupied capture stays memory-only.
final class RecordingWriterCloseContainment: @unchecked Sendable {
    typealias Operation = @Sendable () -> Void

    private struct Job: Sendable {
        let reservation: RecordingWriterCloseReservation
        let operation: Operation
    }

    static let shared = RecordingWriterCloseContainment()

    private let lock = NSLock()
    private let maximumOutstanding: Int
    private var reservations: Set<RecordingWriterCloseReservation> = []
    private var inlineOperations: Set<RecordingWriterCloseReservation> = []
    private var active: Job?
    private var pending: Job?

    init(maximumOutstanding: Int = 2) {
        precondition(maximumOutstanding >= 1)
        self.maximumOutstanding = maximumOutstanding
    }

    func reserve() -> RecordingWriterCloseReservation? {
        lock.withLock {
            guard occupiedCountLocked < maximumOutstanding else { return nil }
            let reservation = RecordingWriterCloseReservation(id: UUID())
            reservations.insert(reservation)
            return reservation
        }
    }

    func release(_ reservation: RecordingWriterCloseReservation) {
        lock.withLock {
            precondition(reservations.remove(reservation) != nil)
        }
    }

    func submit(
        reservation: RecordingWriterCloseReservation,
        operation: @escaping Operation
    ) {
        let job = Job(reservation: reservation, operation: operation)
        let shouldLaunch: Bool = lock.withLock {
            precondition(reservations.remove(reservation) != nil)
            if active == nil {
                active = job
                return true
            }
            precondition(pending == nil, "writer close containment reservation exceeded")
            pending = job
            return false
        }
        if shouldLaunch { launch(job) }
    }

    func perform<T>(
        reservation: RecordingWriterCloseReservation,
        _ operation: () throws -> T
    ) rethrows -> T {
        lock.withLock {
            precondition(reservations.remove(reservation) != nil)
            precondition(inlineOperations.insert(reservation).inserted)
        }
        defer {
            lock.withLock {
                precondition(inlineOperations.remove(reservation) != nil)
            }
        }
        return try operation()
    }

    private var occupiedCountLocked: Int {
        reservations.count
            + inlineOperations.count
            + (active == nil ? 0 : 1)
            + (pending == nil ? 0 : 1)
    }

    private func launch(_ job: Job) {
        Task.detached(priority: .utility) { [self] in
            job.operation()
            finished(job)
        }
    }

    private func finished(_ job: Job) {
        let next: Job? = lock.withLock {
            guard active?.reservation == job.reservation else { return nil }
            let next = pending
            active = next
            pending = nil
            return next
        }
        if let next { launch(next) }
    }
}

/// Exactly-once ownership for an opened production WAV descriptor. Every exit
/// path either synchronizes inline under its global reservation or hands one
/// bounded abandon job to the close containment.
final class ManagedRecordingWriter: @unchecked Sendable {
    let writer: WAVWriter

    private let lock = NSLock()
    private let containment: RecordingWriterCloseContainment
    private var reservation: RecordingWriterCloseReservation?

    init(
        writer: WAVWriter,
        reservation: RecordingWriterCloseReservation,
        containment: RecordingWriterCloseContainment = .shared
    ) {
        self.writer = writer
        self.reservation = reservation
        self.containment = containment
    }

    func scheduleAbandon(deleteURL: URL? = nil) {
        if let deleteURL { RecordingFileDisposer.shared.submit(deleteURL) }
        guard let reservation = claimReservation() else { return }
        let writer = writer
        containment.submit(reservation: reservation) {
            writer.abandonForRecovery()
        }
    }

    func synchronizeAndClose() throws {
        guard let reservation = claimReservation() else {
            throw WAVWriter.Failure.notOpen
        }
        try containment.perform(reservation: reservation) {
            try writer.synchronizeAndClose()
        }
    }

    private func claimReservation() -> RecordingWriterCloseReservation? {
        lock.withLock {
            defer { reservation = nil }
            return reservation
        }
    }
}

enum RecordingWriterOpenResult: Sendable {
    case opened(ManagedRecordingWriter)
    case failed(AudioCaptureError)
    case cancelled
}

struct RecordingFreezeRecoveryReservation: Sendable, Hashable {
    fileprivate let id: UUID
}

/// Bounds PCM snapshots whose final callback outlived the foreground freeze
/// deadline. A stuck callback may retain one old generation while N+1 remains
/// available; N+2 fails start instead of accumulating unlimited 20 MB leases
/// and background waiters.
final class RecordingFreezeRecoveryContainment: @unchecked Sendable {
    static let shared = RecordingFreezeRecoveryContainment()

    private let lock = NSLock()
    private let maximumOutstanding: Int
    private var reservations: Set<RecordingFreezeRecoveryReservation> = []

    init(maximumOutstanding: Int = 2) {
        precondition(maximumOutstanding >= 1)
        self.maximumOutstanding = maximumOutstanding
    }

    func reserve() -> RecordingFreezeRecoveryReservation? {
        lock.withLock {
            guard reservations.count < maximumOutstanding else { return nil }
            let reservation = RecordingFreezeRecoveryReservation(id: UUID())
            reservations.insert(reservation)
            return reservation
        }
    }

    func release(_ reservation: RecordingFreezeRecoveryReservation) {
        lock.withLock {
            precondition(reservations.remove(reservation) != nil)
        }
    }
}

/// Exact-once ownership for one live/cancelled-freeze PCM generation.
final class RecordingFreezeRecoveryLease: @unchecked Sendable {
    private let lock = NSLock()
    private let containment: RecordingFreezeRecoveryContainment
    private var reservation: RecordingFreezeRecoveryReservation?

    init(
        reservation: RecordingFreezeRecoveryReservation,
        containment: RecordingFreezeRecoveryContainment = .shared
    ) {
        self.reservation = reservation
        self.containment = containment
    }

    func release() {
        let claimed: RecordingFreezeRecoveryReservation? = lock.withLock {
            defer { reservation = nil }
            return reservation
        }
        if let claimed { containment.release(claimed) }
    }
}

/// At most one synchronous `WAVWriter.open()` may be in the kernel at once.
/// Capture never awaits it: a permanently wedged volume consumes one bounded
/// worker while this and every later short take continue through in-memory PCM.
/// A late result is fenced to its exact session and never adopted by N+1.
final class RecordingWriterOpenCoordinator: @unchecked Sendable {
    typealias Open = @Sendable (WAVWriter) throws -> Void
    typealias Dispose = @Sendable (WAVWriter) -> Void
    typealias Completion = @Sendable (RecordingWriterOpenResult) -> Void

    private struct Operation: Sendable {
        let id: UUID
        let session: DictationSessionID
        let disposition: RecordingDisposition?
        let managedWriter: ManagedRecordingWriter
        var completion: Completion?
        var isCancelled = false
    }

    static let shared = RecordingWriterOpenCoordinator()

    private let lock = NSLock()
    private let open: Open
    private let dispose: Dispose
    private var active: Operation?

    init(
        open: @escaping Open = { try $0.open() },
        dispose: @escaping Dispose = {
            RecordingFileDisposer.shared.submit($0.fileURL)
        }
    ) {
        self.open = open
        self.dispose = dispose
    }

    /// Returns false immediately when an older kernel open is still in flight.
    /// No task or descriptor is created for a rejected request.
    @discardableResult
    func begin(
        writer: WAVWriter,
        session: DictationSessionID,
        disposition: RecordingDisposition? = nil,
        completion: @escaping Completion
    ) -> Bool {
        guard let closeReservation = RecordingWriterCloseContainment.shared.reserve() else {
            dispose(writer)
            return false
        }
        let managedWriter = ManagedRecordingWriter(
            writer: writer,
            reservation: closeReservation
        )
        let operation = Operation(
            id: UUID(),
            session: session,
            disposition: disposition,
            managedWriter: managedWriter,
            completion: completion
        )
        let accepted = lock.withLock {
            guard active == nil else { return false }
            active = operation
            return true
        }
        guard accepted else {
            RecordingWriterCloseContainment.shared.release(closeReservation)
            dispose(writer)
            return false
        }

        let open = open
        Task.detached(priority: .userInitiated) { [self] in
            let result: Result<Void, AudioCaptureError>
            do {
                try open(writer)
                // The actor may be stuck in AVAudioEngine.prepare/start while
                // Escape changes the disposition. Recheck immediately after
                // the non-cancellable open creates the path so deletion never
                // depends on entering that actor again.
                if disposition?.state == .deleteRequested {
                    result = .failure(.writeFailed("recording was cancelled"))
                } else {
                    result = .success(())
                }
            } catch {
                result = .failure(.writeFailed(String(describing: error)))
            }
            finish(operationID: operation.id, result: result)
        }
        return true
    }

    func cancel(session: DictationSessionID) {
        let completion: Completion? = lock.withLock {
            guard var operation = active,
                  operation.session == session,
                  !operation.isCancelled else { return nil }
            operation.isCancelled = true
            let completion = operation.completion
            operation.completion = nil
            active = operation
            return completion
        }
        completion?(.cancelled)
    }

    private func finish(
        operationID: UUID,
        result: Result<Void, AudioCaptureError>
    ) {
        let finished: Operation? = lock.withLock {
            guard active?.id == operationID else { return nil }
            defer { active = nil }
            return active
        }
        guard let finished else { return }

        if finished.isCancelled || finished.disposition?.state == .deleteRequested {
            dispose(finished.managedWriter.writer)
            finished.managedWriter.scheduleAbandon()
            if !finished.isCancelled { finished.completion?(.cancelled) }
            return
        }
        switch result {
        case .success:
            finished.completion?(.opened(finished.managedWriter))
        case let .failure(error):
            dispose(finished.managedWriter.writer)
            finished.managedWriter.scheduleAbandon()
            if finished.disposition?.state == .deleteRequested {
                finished.completion?(.cancelled)
            } else {
                finished.completion?(.failed(error))
            }
        }
    }
}

/// The audio callback cannot enter an actor. This small lock-protected ledger
/// freezes every callback that began before the tap was removed, including the
/// last word, without putting disk I/O on the real-time audio thread.
final class RecordingPCMBuffer: @unchecked Sendable {
    private enum FreezeOutcome {
        case snapshot(RecordingPCMStorageSnapshot)
        case cancelled
    }

    struct AppendResult {
        /// The frame belonged to a generation already sealed/discarded by a
        /// bounded recovery deadline. Its samples must not reach disk, meter,
        /// first-frame state, or any other old-session side channel.
        let wasRejected: Bool
        let isFirstFrame: Bool
        let didOverflowMemory: Bool
        let didReachHardLimit: Bool
        /// Exact current-frame prefix committed to PCM. At the hard cap this
        /// may be shorter than the converter output and is also what the disk
        /// sink must receive to keep both artifacts byte-order equivalent.
        let committedSamples: [Float]?
    }

    private let lock = NSLock()
    private let maximumSamples: Int
    private let onFlatten: (@Sendable () -> Void)?
    private let onChunkRelease: (@Sendable () -> Void)?
    private let discardReleaseContainment: RecordingPCMDiscardReleaseContainment
    private var chunkHead: RecordingPCMChunk?
    private var deferredReleaseHead: RecordingPCMChunk?
    private var retainedSampleCount = 0
    private var memoryAvailable = true
    private var totalSamples = 0
    private var firstFrameAt: ContinuousClock.Instant?
    private var firstFrameSequence: UInt64?
    private var nextIngressSequence: UInt64 = 0
    private var acceptingFrames = true
    private var discarded = false
    private var freezeWasCancelled = false
    private var callbacksInFlight = 0
    private var freezeWaiter: CheckedContinuation<FreezeOutcome, Never>?
    private var cancelledRecoveryWaiter:
        CheckedContinuation<RecordingPCMStorageSnapshot, Never>?
    private var cancelledRecoverySnapshot: RecordingPCMStorageSnapshot?
    private var cancelledRecoveryDidProduceSnapshot = false
    private var cancelledRecoveryWasSealed = false

    init(
        maximumSamples: Int,
        onFlatten: (@Sendable () -> Void)? = nil,
        onChunkRelease: (@Sendable () -> Void)? = nil,
        discardReleaseContainment: RecordingPCMDiscardReleaseContainment = .shared
    ) {
        precondition(maximumSamples >= 0)
        self.maximumSamples = maximumSamples
        self.onFlatten = onFlatten
        self.onChunkRelease = onChunkRelease
        self.discardReleaseContainment = discardReleaseContainment
    }

    func beginFrame(sampleTime: AVAudioFramePosition? = nil) -> RecordingPCMFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingFrames, !discarded else { return nil }
        precondition(nextIngressSequence < UInt64.max, "one recording exhausted its frame sequence")
        let frame = RecordingPCMFrame(
            ingressSequence: nextIngressSequence,
            sampleTime: sampleTime
        )
        nextIngressSequence += 1
        callbacksInFlight += 1
        return frame
    }

    /// Closes the real-time admission gate without waiting for callbacks that
    /// already own a frame. Freeze/abort call this before touching AVFAudio so
    /// a blocking `stop()` can never admit more work behind the barrier.
    func closeAdmission() {
        lock.lock()
        acceptingFrames = false
        lock.unlock()
    }

    func append(
        _ samples: [Float],
        frame: RecordingPCMFrame,
        at instant: ContinuousClock.Instant,
        preserveAtLimit: Bool = false
    ) -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded, !cancelledRecoveryWasSealed, !samples.isEmpty else {
            return AppendResult(
                wasRejected: true,
                isFirstFrame: false,
                didOverflowMemory: false,
                didReachHardLimit: false,
                committedSamples: nil
            )
        }

        let remaining = maximumSamples - retainedSampleCount
        if preserveAtLimit, memoryAvailable, samples.count > remaining {
            // A live disk pipeline is not complete until stop drains and seals
            // it. Keep exactly the prefix that fills the bounded PCM cap and
            // stop admission. Copying at most one current tap frame is bounded;
            // no historical audio is reallocated on the real-time callback.
            let committed = remaining > 0
                ? Array(samples.prefix(remaining))
                : []
            let wasFirst = totalSamples == 0 && !committed.isEmpty
            if wasFirst {
                firstFrameSequence = frame.ingressSequence
                firstFrameAt = instant
            }
            if !committed.isEmpty {
                chunkHead = RecordingPCMChunk(
                    frame: frame,
                    samples: committed,
                    next: chunkHead,
                    onRelease: onChunkRelease
                )
                retainedSampleCount += committed.count
                totalSamples += committed.count
            }
            acceptingFrames = false
            return AppendResult(
                wasRejected: false,
                isFirstFrame: wasFirst,
                didOverflowMemory: false,
                didReachHardLimit: true,
                committedSamples: committed.isEmpty ? nil : committed
            )
        }

        let wasFirst = totalSamples == 0
        if firstFrameSequence.map({ frame.ingressSequence < $0 }) ?? true {
            firstFrameSequence = frame.ingressSequence
            firstFrameAt = instant
        }
        let (newTotal, totalOverflowed) = totalSamples.addingReportingOverflow(samples.count)
        totalSamples = totalOverflowed ? Int.max : newTotal

        var didOverflowMemory = false
        if memoryAvailable {
            if samples.count <= remaining {
                chunkHead = RecordingPCMChunk(
                    frame: frame,
                    samples: samples,
                    next: chunkHead,
                    onRelease: onChunkRelease
                )
                retainedSampleCount += samples.count
            } else {
                // The disk pipeline owns the complete long take. Drop every
                // retained chunk at once rather than keeping an unusable prefix.
                // Keep the chain alive until freeze so ARC cannot recursively
                // destroy historical audio on this real-time callback.
                deferredReleaseHead = chunkHead
                chunkHead = nil
                retainedSampleCount = 0
                memoryAvailable = false
                didOverflowMemory = true
            }
        }
        return AppendResult(
            wasRejected: false,
            isFirstFrame: wasFirst,
            didOverflowMemory: didOverflowMemory,
            didReachHardLimit: false,
            committedSamples: samples
        )
    }

    func endFrame() {
        var freezeCompletion: (CheckedContinuation<FreezeOutcome, Never>, FreezeOutcome)?
        var recoveryCompletion: (
            CheckedContinuation<RecordingPCMStorageSnapshot, Never>,
            RecordingPCMStorageSnapshot
        )?
        lock.lock()
        callbacksInFlight -= 1
        precondition(callbacksInFlight >= 0)
        if callbacksInFlight == 0, let waiter = freezeWaiter {
            freezeWaiter = nil
            freezeCompletion = (waiter, .snapshot(takeSnapshotLocked()))
        } else if callbacksInFlight == 0,
                  freezeWasCancelled,
                  !cancelledRecoveryDidProduceSnapshot {
            let snapshot = takeSnapshotLocked()
            cancelledRecoveryDidProduceSnapshot = true
            if let waiter = cancelledRecoveryWaiter {
                cancelledRecoveryWaiter = nil
                recoveryCompletion = (waiter, snapshot)
            } else {
                cancelledRecoverySnapshot = snapshot
            }
        }
        lock.unlock()
        if let (waiter, outcome) = freezeCompletion {
            waiter.resume(returning: outcome)
        }
        if let (waiter, snapshot) = recoveryCompletion {
            waiter.resume(returning: snapshot)
        }
    }

    func freeze(
        retainSamples: @Sendable () -> Bool = { true }
    ) async -> FrozenPCM {
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<FreezeOutcome, Never>) in
                lock.lock()
                acceptingFrames = false
                if freezeWasCancelled {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                } else if callbacksInFlight == 0 {
                    let snapshot = takeSnapshotLocked()
                    lock.unlock()
                    continuation.resume(returning: .snapshot(snapshot))
                } else {
                    precondition(freezeWaiter == nil, "PCM can only be frozen once")
                    freezeWaiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelFreezeWait()
        }

        switch outcome {
        case .cancelled:
            return FrozenPCM(
                samples: nil,
                totalSamples: 0,
                firstFrameAt: nil,
                recoverySnapshotPending: true
            )
        case let .snapshot(snapshot):
            if Task.isCancelled {
                storeCancelledRecoverySnapshot(snapshot)
                return FrozenPCM(
                    samples: nil,
                    totalSamples: snapshot.totalSamples,
                    firstFrameAt: snapshot.firstFrameAt,
                    recoverySnapshotPending: true
                )
            }
            guard retainSamples() else {
                return FrozenPCM(
                    samples: nil,
                    totalSamples: snapshot.totalSamples,
                    firstFrameAt: snapshot.firstFrameAt
                )
            }
            return snapshot.flatten()
        }
    }

    /// Completes only for a foreground freeze that was cancelled. Historical
    /// chunks and any callback already admitted before stop remain owned here;
    /// flattening happens on the bounded recovery task, never the audio thread.
    func recoverAfterCancelledFreeze(
        prefrozen: FrozenPCM? = nil,
        callbackGrace: Duration = .milliseconds(50),
        retainSamples: @Sendable () -> Bool = { true }
    ) async -> FrozenPCM {
        if let prefrozen, !prefrozen.recoverySnapshotPending {
            guard retainSamples() else {
                return FrozenPCM(
                    samples: nil,
                    totalSamples: prefrozen.totalSamples,
                    firstFrameAt: prefrozen.firstFrameAt
                )
            }
            return prefrozen
        }

        lock.withLock {
            acceptingFrames = false
            freezeWasCancelled = true
        }

        // AVFAudio normally finishes an admitted converter callback within a
        // few milliseconds. Give it a short chance to preserve the final
        // frame, then atomically seal the already committed prefix. A callback
        // wedged forever can therefore retain at most one bounded lease; its
        // eventual append is fenced and cannot mutate the recovered artifact.
        let watchdog = Task.detached(priority: .utility) { [self] in
            do {
                try await Task.sleep(for: callbackGrace)
            } catch {
                return
            }
            sealCancelledRecoveryPrefix()
        }
        let snapshot = await awaitCancelledRecoverySnapshot()
        watchdog.cancel()
        guard retainSamples() else {
            return FrozenPCM(
                samples: nil,
                totalSamples: snapshot.totalSamples,
                firstFrameAt: snapshot.firstFrameAt
            )
        }
        return snapshot.flatten()
    }

    private func awaitCancelledRecoverySnapshot() async -> RecordingPCMStorageSnapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let ready = cancelledRecoverySnapshot {
                cancelledRecoverySnapshot = nil
                lock.unlock()
                continuation.resume(returning: ready)
            } else if !cancelledRecoveryDidProduceSnapshot,
                      (discarded || callbacksInFlight == 0) {
                let ready = takeSnapshotLocked()
                cancelledRecoveryDidProduceSnapshot = true
                lock.unlock()
                continuation.resume(returning: ready)
            } else {
                precondition(
                    cancelledRecoveryWaiter == nil
                        && !cancelledRecoveryDidProduceSnapshot,
                    "cancelled PCM recovery can only be claimed once"
                )
                cancelledRecoveryWaiter = continuation
                lock.unlock()
            }
        }
    }

    private func sealCancelledRecoveryPrefix() {
        var recoveryCompletion: (
            CheckedContinuation<RecordingPCMStorageSnapshot, Never>,
            RecordingPCMStorageSnapshot
        )?
        lock.lock()
        acceptingFrames = false
        freezeWasCancelled = true
        cancelledRecoveryWasSealed = true
        if !cancelledRecoveryDidProduceSnapshot {
            let snapshot = takeSnapshotLocked()
            cancelledRecoveryDidProduceSnapshot = true
            if let waiter = cancelledRecoveryWaiter {
                cancelledRecoveryWaiter = nil
                recoveryCompletion = (waiter, snapshot)
            } else {
                cancelledRecoverySnapshot = snapshot
            }
        }
        lock.unlock()
        if let (waiter, snapshot) = recoveryCompletion {
            waiter.resume(returning: snapshot)
        }
    }

    func discard() {
        var freezeCompletion: CheckedContinuation<FreezeOutcome, Never>?
        var recoveryCompletion: (
            CheckedContinuation<RecordingPCMStorageSnapshot, Never>,
            RecordingPCMStorageSnapshot
        )?
        lock.lock()
        acceptingFrames = false
        discarded = true
        freezeWasCancelled = true
        cancelledRecoveryWasSealed = true
        let discardedStorage = RecordingPCMDiscardedStorage(
            chunkHead: chunkHead,
            deferredReleaseHead: deferredReleaseHead,
            recoverySnapshot: cancelledRecoverySnapshot
        )
        chunkHead = nil
        deferredReleaseHead = nil
        cancelledRecoverySnapshot = nil
        retainedSampleCount = 0
        memoryAvailable = false
        if let waiter = freezeWaiter {
            freezeWaiter = nil
            freezeCompletion = waiter
        }
        let emptySnapshot = makeEmptySnapshotLocked()
        if let waiter = cancelledRecoveryWaiter {
            cancelledRecoveryWaiter = nil
            cancelledRecoveryDidProduceSnapshot = true
            recoveryCompletion = (waiter, emptySnapshot)
        } else if !cancelledRecoveryDidProduceSnapshot
                    || discardedStorage.recoverySnapshot != nil {
            // A foreground freeze may schedule its recovery just after this
            // destructive abort returns. Give that claimant an explicit empty
            // terminal snapshot rather than waiting for the stuck callback.
            cancelledRecoveryDidProduceSnapshot = true
            cancelledRecoverySnapshot = emptySnapshot
        }
        lock.unlock()
        discardReleaseContainment.submit(discardedStorage)
        freezeCompletion?.resume(returning: .cancelled)
        if let (waiter, snapshot) = recoveryCompletion {
            waiter.resume(returning: snapshot)
        }
    }

    private func cancelFreezeWait() {
        var freezeCompletion: CheckedContinuation<FreezeOutcome, Never>?
        lock.lock()
        acceptingFrames = false
        freezeWasCancelled = true
        if let waiter = freezeWaiter {
            freezeWaiter = nil
            freezeCompletion = waiter
        }
        lock.unlock()
        freezeCompletion?.resume(returning: .cancelled)
    }

    private func storeCancelledRecoverySnapshot(_ snapshot: RecordingPCMStorageSnapshot) {
        lock.lock()
        precondition(
            cancelledRecoverySnapshot == nil
                && !cancelledRecoveryDidProduceSnapshot
        )
        cancelledRecoverySnapshot = snapshot
        cancelledRecoveryDidProduceSnapshot = true
        freezeWasCancelled = true
        lock.unlock()
    }

    private func takeSnapshotLocked() -> RecordingPCMStorageSnapshot {
        let snapshot = RecordingPCMStorageSnapshot(
            head: memoryAvailable ? chunkHead : nil,
            deferredReleaseHead: deferredReleaseHead,
            retainedSampleCount: memoryAvailable ? retainedSampleCount : 0,
            totalSamples: totalSamples,
            firstFrameAt: firstFrameAt,
            onFlatten: onFlatten
        )
        chunkHead = nil
        deferredReleaseHead = nil
        retainedSampleCount = 0
        memoryAvailable = false
        return snapshot
    }

    private func makeEmptySnapshotLocked() -> RecordingPCMStorageSnapshot {
        RecordingPCMStorageSnapshot(
            head: nil,
            deferredReleaseHead: nil,
            retainedSampleCount: 0,
            totalSamples: totalSamples,
            firstFrameAt: firstFrameAt,
            onFlatten: onFlatten
        )
    }
}

/// Disk health is independent from recognizer-ready PCM. A full or stalled
/// disk is fatal only after the bounded memory copy is unavailable too.
private final class RecordingDiskWriteGate: @unchecked Sendable {
    static let shared = RecordingDiskWriteGate()

    private let lock = NSLock()
    private var isOccupied = false

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOccupied else { return false }
        isOccupied = true
        return true
    }

    func release() {
        lock.lock()
        precondition(isOccupied)
        isOccupied = false
        lock.unlock()
    }
}

final class RecordingDiskState: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: WAVWriter
    private let onUnrecoverableFailure: @Sendable (AudioCaptureError) -> Void
    private var failure: AudioCaptureError?
    private var memoryAvailable = true
    private var didNotify = false

    init(
        writer: WAVWriter,
        onUnrecoverableFailure: @escaping @Sendable (AudioCaptureError) -> Void
    ) {
        self.writer = writer
        self.onUnrecoverableFailure = onUnrecoverableFailure
    }

    func append(_ samples: [Float]) {
        lock.lock()
        let canWrite = failure == nil
        lock.unlock()
        guard canWrite else { return }

        guard RecordingDiskWriteGate.shared.tryAcquire() else {
            markFailed(.writeFailed("another audio disk write is still in progress"))
            return
        }
        defer { RecordingDiskWriteGate.shared.release() }

        do {
            try writer.append(samples)
        } catch {
            markFailed(.writeFailed(String(describing: error)))
        }
    }

    func queueOverflowed() {
        markFailed(.writeFailed("the audio disk queue couldn't keep up"))
    }

    func memoryDidOverflow() {
        var notification: AudioCaptureError?
        lock.lock()
        memoryAvailable = false
        if let failure, !didNotify {
            didNotify = true
            notification = failure
        }
        lock.unlock()
        if let notification { onUnrecoverableFailure(notification) }
    }

    var recordedFailure: AudioCaptureError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    private func markFailed(_ error: AudioCaptureError) {
        var notification: AudioCaptureError?
        lock.lock()
        if failure == nil { failure = error }
        if !memoryAvailable, !didNotify {
            didNotify = true
            notification = failure
        }
        lock.unlock()
        if let notification { onUnrecoverableFailure(notification) }
    }
}

final class RecordingDiskPipeline: @unchecked Sendable {
    let writer: WAVWriter
    let managedWriter: ManagedRecordingWriter?
    let disk: RecordingDiskState
    let sink: FrameSink
    let enqueue: @Sendable ([Float]) -> Void

    init(
        writer: WAVWriter,
        disk: RecordingDiskState,
        sink: FrameSink,
        enqueue: @escaping @Sendable ([Float]) -> Void
    ) {
        self.writer = writer
        managedWriter = nil
        self.disk = disk
        self.sink = sink
        self.enqueue = enqueue
    }

    init(
        managedWriter: ManagedRecordingWriter,
        disk: RecordingDiskState,
        sink: FrameSink,
        enqueue: @escaping @Sendable ([Float]) -> Void
    ) {
        writer = managedWriter.writer
        self.managedWriter = managedWriter
        self.disk = disk
        self.sink = sink
        self.enqueue = enqueue
    }
}

/// The disk copy is opportunistic. If the first lossless PCM commit wins the
/// race against `WAVWriter.open()`, the whole take remains memory-only rather
/// than publishing a WAV with a missing prefix. This state transition and
/// writer attachment share one short lock, so there is no ambiguous winner.
final class RecordingDiskAttachment: @unchecked Sendable {
    private enum State {
        case opening
        case attached(RecordingDiskPipeline)
        case unavailable
    }

    private let lock = NSLock()
    private let cancelOpen: @Sendable () -> Void
    private var state: State = .opening

    init(cancelOpen: @escaping @Sendable () -> Void) {
        self.cancelOpen = cancelOpen
    }

    /// Transfers ownership of an opened writer only if no PCM frame has yet
    /// committed. The caller disposes a rejected pipeline off the capture actor.
    func attach(_ pipeline: RecordingDiskPipeline) -> Bool {
        lock.withLock {
            guard case .opening = state else { return false }
            state = .attached(pipeline)
            return true
        }
    }

    func openFailed() {
        lock.withLock {
            guard case .opening = state else { return }
            state = .unavailable
        }
    }

    /// Called inside the sequenced lossless commit. The first frame either
    /// reaches an already attached sink or permanently selects memory-only;
    /// a late writer can therefore never masquerade as a complete take.
    func submit(_ samples: [Float]) {
        var enqueue: (@Sendable ([Float]) -> Void)?
        var shouldCancelOpen = false
        lock.withLock {
            switch state {
            case .opening:
                state = .unavailable
                shouldCancelOpen = true
            case let .attached(pipeline):
                enqueue = pipeline.enqueue
            case .unavailable:
                break
            }
        }
        if shouldCancelOpen { cancelOpen() }
        enqueue?(samples)
    }

    /// Stops a still-opening writer after the memory-only hard cap. If attach
    /// won the preceding lock race, retain that pipeline: it contains exactly
    /// the same committed prefix because the overflowing frame is not sent.
    func closeForMemoryLimit() {
        var shouldCancelOpen = false
        lock.withLock {
            if case .opening = state {
                state = .unavailable
                shouldCancelOpen = true
            }
        }
        if shouldCancelOpen { cancelOpen() }
    }

    /// Returns whether a complete disk copy exists beyond the bounded PCM cap.
    func memoryDidOverflow() -> Bool {
        let disk: RecordingDiskState? = lock.withLock {
            guard case let .attached(pipeline) = state else { return nil }
            return pipeline.disk
        }
        disk?.memoryDidOverflow()
        return disk != nil
    }

    /// Closes attachment and transfers a complete pipeline to finalization.
    /// An outstanding open is cancelled but remains contained by the global
    /// one-flight coordinator until its kernel call eventually returns.
    func takePipeline() -> RecordingDiskPipeline? {
        var pipeline: RecordingDiskPipeline?
        var shouldCancelOpen = false
        lock.withLock {
            switch state {
            case .opening:
                shouldCancelOpen = true
            case let .attached(attached):
                pipeline = attached
            case .unavailable:
                break
            }
            state = .unavailable
        }
        if shouldCancelOpen { cancelOpen() }
        return pipeline
    }
}

struct RecordingEngineStartReservation: Sendable, Hashable {
    fileprivate let id: UUID
}

enum RecordingEngineStartOutcome: Sendable, Equatable {
    case started
    case failed(AudioCaptureError)
    case cancelled
}

/// Executes cancellation-deaf AVFAudio startup outside `MicrophoneCapture`'s
/// reusable actor. Logical cancellation resumes the exact generation waiter
/// immediately, while the native call and its engine remain charged to this
/// process-wide bound until they really return.
///
/// Two slots are deliberate: one permanently executing generation may exist
/// while N+1 gets an independent attempt and controller deadline. A second
/// permanent fault rejects N+2 before another engine or detached task exists.
final class RecordingEngineStartContainment: @unchecked Sendable {
    typealias Operation = @Sendable () -> Result<Void, AudioCaptureError>
    typealias Abandon = @Sendable () -> Void

    private enum Phase {
        case reserved
        case running
    }

    private struct Entry {
        var phase: Phase = .reserved
        var isCancelled = false
        var continuation: CheckedContinuation<RecordingEngineStartOutcome, Never>?
        var onAbandon: Abandon?
    }

    static let shared = RecordingEngineStartContainment()

    private let lock = NSLock()
    private let maximumOutstanding: Int
    private let queue: DispatchQueue
    private var entries: [RecordingEngineStartReservation: Entry] = [:]

    init(maximumOutstanding: Int = 2) {
        precondition(maximumOutstanding >= 1)
        self.maximumOutstanding = maximumOutstanding
        queue = DispatchQueue(
            label: "is.waiwai.dictation.capture-start",
            qos: .userInteractive,
            attributes: .concurrent
        )
    }

    func reserve() -> RecordingEngineStartReservation? {
        lock.withLock {
            guard entries.count < maximumOutstanding else { return nil }
            let reservation = RecordingEngineStartReservation(id: UUID())
            entries[reservation] = Entry()
            return reservation
        }
    }

    /// Releases setup capacity before a native start operation was submitted.
    func release(_ reservation: RecordingEngineStartReservation) {
        lock.withLock {
            guard let entry = entries[reservation] else {
                preconditionFailure("unknown engine start reservation")
            }
            precondition(entry.phase == .reserved && entry.continuation == nil)
            entries[reservation] = nil
        }
    }

    func start(
        reservation: RecordingEngineStartReservation,
        operation: @escaping Operation,
        onAbandon: @escaping Abandon
    ) async -> RecordingEngineStartOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var shouldLaunch = false
                var wasAlreadyCancelled = false

                lock.lock()
                guard var entry = entries[reservation] else {
                    lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                precondition(entry.phase == .reserved && entry.continuation == nil)
                if entry.isCancelled {
                    entries[reservation] = nil
                    wasAlreadyCancelled = true
                } else {
                    entry.phase = .running
                    entry.continuation = continuation
                    entry.onAbandon = onAbandon
                    entries[reservation] = entry
                    shouldLaunch = true
                }
                lock.unlock()

                if wasAlreadyCancelled {
                    onAbandon()
                    continuation.resume(returning: .cancelled)
                } else if shouldLaunch {
                    // A cancellation-deaf native call must not occupy a Swift
                    // cooperative executor thread. The admission table above
                    // bounds this blocking GCD lane to two live generations.
                    queue.async { [self] in
                        let outcome: RecordingEngineStartOutcome
                        switch operation() {
                        case .success:
                            outcome = .started
                        case let .failure(error):
                            outcome = .failed(error)
                        }
                        finish(reservation: reservation, outcome: outcome)
                    }
                }
            }
        } onCancel: {
            self.cancel(reservation: reservation)
        }
    }

    /// Cancels only the logical waiter. A running native call keeps its slot,
    /// engine, and eventual exact-generation cleanup closure until completion.
    func cancel(reservation: RecordingEngineStartReservation) {
        let continuation: CheckedContinuation<RecordingEngineStartOutcome, Never>? =
            lock.withLock {
                guard var entry = entries[reservation], !entry.isCancelled else {
                    return nil
                }
                entry.isCancelled = true
                let continuation = entry.continuation
                entry.continuation = nil
                entries[reservation] = entry
                return continuation
            }
        continuation?.resume(returning: .cancelled)
    }

    private func finish(
        reservation: RecordingEngineStartReservation,
        outcome: RecordingEngineStartOutcome
    ) {
        let completion: (
            CheckedContinuation<RecordingEngineStartOutcome, Never>?,
            Abandon?
        ) = lock.withLock {
            guard let entry = entries.removeValue(forKey: reservation) else {
                return (nil, nil)
            }
            precondition(entry.phase == .running)
            if entry.isCancelled {
                return (nil, entry.onAbandon)
            }
            return (entry.continuation, nil)
        }
        completion.1?()
        completion.0?.resume(returning: outcome)
    }
}

struct RecordingEngineShutdownReservation: Sendable, Hashable {
    fileprivate let id: UUID
}

/// A stop/removeTap call belongs to an abandoned AVFAudio generation. It may
/// block inside the framework, so it runs outside the capture actor. Capacity
/// is globally bounded to one executing shutdown plus one live/pending N+1;
/// a second wedged join fails a later start instead of leaking tasks forever.
final class RecordingEngineShutdownContainment: @unchecked Sendable {
    typealias Operation = @Sendable () -> Void

    private struct Job: Sendable {
        let reservation: RecordingEngineShutdownReservation
        let operation: Operation
    }

    static let shared = RecordingEngineShutdownContainment()

    private let lock = NSLock()
    private var reservations: Set<RecordingEngineShutdownReservation> = []
    private var active: Job?
    private var pending: Job?

    /// Reserve containment before constructing a live generation. With one
    /// old shutdown wedged, exactly N+1 can still start and later wait pending.
    func reserve() -> RecordingEngineShutdownReservation? {
        lock.withLock {
            let occupied = reservations.count + (active == nil ? 0 : 1) + (pending == nil ? 0 : 1)
            guard occupied < 2 else { return nil }
            let reservation = RecordingEngineShutdownReservation(id: UUID())
            reservations.insert(reservation)
            return reservation
        }
    }

    func release(_ reservation: RecordingEngineShutdownReservation) {
        lock.withLock {
            precondition(reservations.remove(reservation) != nil)
        }
    }

    func submit(
        reservation: RecordingEngineShutdownReservation,
        engine: AVAudioEngine,
        input: AVAudioInputNode
    ) {
        let job = RecordingEngineShutdownJob(engine: engine, input: input)
        submit(reservation: reservation) { job.run() }
    }

    func submit(
        reservation: RecordingEngineShutdownReservation,
        operation: @escaping Operation
    ) {
        let job = Job(reservation: reservation, operation: operation)
        let shouldLaunch: Bool = lock.withLock {
            precondition(reservations.remove(reservation) != nil)
            if active == nil {
                active = job
                return true
            }
            precondition(pending == nil, "shutdown containment reservation exceeded")
            pending = job
            return false
        }
        if shouldLaunch { launch(job) }
    }

    /// The one thread in this package allowed to block.
    ///
    /// `job.operation()` is `engine.stop()` + `input.removeTap(onBus:)`, and
    /// the comment above this class says what those do: they may block inside
    /// AVFAudio. This used to run in `Task.detached`, which puts it on Swift's
    /// cooperative pool — the pool that has one thread per core and that Swift
    /// documents you must never block, because a blocked thread is not yielded,
    /// it is simply gone.
    ///
    /// It ran there on the ordinary stop path, at the end of every dictation.
    /// The recognition that follows is suspended on that same pool, so a
    /// teardown that parked inside the framework held the result behind it —
    /// which is what the field logs show: recognition seconds long around an
    /// inference call that never exceeded 1.07 s, with the main thread awake
    /// the whole time and only the pool asleep.
    ///
    /// A dedicated queue costs one OS thread that spends its life idle. That
    /// is the correct price for a call that is allowed to block.
    static let teardownQueueLabel = "is.waiwai.dictation.audio-teardown"

    private static let teardownQueue = DispatchQueue(
        label: teardownQueueLabel,
        qos: .userInitiated
    )

    private func launch(_ job: Job) {
        Self.teardownQueue.async { [self] in
            job.operation()
            finished(job)
        }
    }

    private func finished(_ job: Job) {
        let next: Job? = lock.withLock {
            guard active?.reservation == job.reservation else { return nil }
            let next = pending
            active = next
            pending = nil
            return next
        }
        if let next { launch(next) }
    }
}

private final class RecordingEngineShutdownJob: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let input: AVAudioInputNode

    init(engine: AVAudioEngine, input: AVAudioInputNode) {
        self.engine = engine
        self.input = input
    }

    func run() {
        engine.stop()
        input.removeTap(onBus: 0)
    }
}

/// AVAudioEngine is not declared Sendable, but this wrapper has one strict
/// owner: the detached start operation. No stop/removeTap call is permitted
/// until `run()` returns and the exact shutdown lease is claimed.
private final class RecordingEngineStartJob: @unchecked Sendable {
    private let engine: AVAudioEngine

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func run() -> Result<Void, AudioCaptureError> {
        do {
            engine.prepare()
            try engine.start()
            return .success(())
        } catch {
            return .failure(.engineUnavailable(error.localizedDescription))
        }
    }
}

/// Exact-once shutdown ownership shared by the start lane and capture actor.
/// A cancelled start keeps this lease with its native operation; an adopted
/// start transfers the same lease into normal freeze/abort teardown.
private final class RecordingEngineShutdownLease: @unchecked Sendable {
    private let lock = NSLock()
    private let engine: AVAudioEngine
    private let input: AVAudioInputNode
    private let containment: RecordingEngineShutdownContainment
    private var reservation: RecordingEngineShutdownReservation?

    init(
        reservation: RecordingEngineShutdownReservation,
        engine: AVAudioEngine,
        input: AVAudioInputNode,
        containment: RecordingEngineShutdownContainment = .shared
    ) {
        self.reservation = reservation
        self.engine = engine
        self.input = input
        self.containment = containment
    }

    func schedule() {
        let claimed: RecordingEngineShutdownReservation? = lock.withLock {
            defer { reservation = nil }
            return reservation
        }
        guard let claimed else { return }
        containment.submit(reservation: claimed, engine: engine, input: input)
    }
}

/// Controller-issued IDs are process-monotonic. Remembering the greatest
/// cancellation is a bounded tombstone: if abort enters this actor before its
/// matching start, that late (or any older) request can never resurrect audio.
struct RecordingSessionTombstones {
    private var cancelledThrough: DictationSessionID?

    mutating func recordCancellation(_ session: DictationSessionID) {
        if cancelledThrough.map({ $0 < session }) ?? true {
            cancelledThrough = session
        }
    }

    func contains(_ session: DictationSessionID) -> Bool {
        cancelledThrough.map { session <= $0 } ?? false
    }
}

/// External failure handling may touch UI/controller state and is not trusted
/// to return promptly. Delivery is off the capture actor with one active call
/// and one coalesced pending error, so it cannot hold microphone lifecycle or
/// create an unbounded task backlog.
final class CoalescingCaptureFailureObserver: @unchecked Sendable {
    private struct Event: Sendable {
        let session: DictationSessionID
        let error: AudioCaptureError
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "is.waiwai.dictation.capture-failure",
        qos: .userInteractive
    )
    private let consume: @Sendable (DictationSessionID, AudioCaptureError) -> Void
    private var pending: Event?
    private var isDraining = false

    init(
        consume: @escaping @Sendable (DictationSessionID, AudioCaptureError) -> Void
    ) {
        self.consume = consume
    }

    func submit(session: DictationSessionID, error: AudioCaptureError) {
        lock.lock()
        pending = Event(session: session, error: error)
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let event = pending else {
                isDraining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            consume(event.session, event.error)
        }
    }
}

/// Reaching the memory-only capture cap is a graceful stop request, not a
/// corruption failure. The callback runs off both the real-time thread and the
/// capture actor, with a process-local one-active/one-pending bound.
final class CoalescingCaptureLimitObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "is.waiwai.dictation.capture-memory-limit",
        qos: .userInteractive
    )
    private let consume: @Sendable (DictationSessionID) -> Void
    private var pending: DictationSessionID?
    private var isDraining = false

    init(consume: @escaping @Sendable (DictationSessionID) -> Void) {
        self.consume = consume
    }

    func submit(session: DictationSessionID) {
        lock.lock()
        pending = session
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let session = pending else {
                isDraining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            consume(session)
        }
    }
}

/// Best-effort live metering must never become part of the recording's
/// durability or recognition milestone.
///
/// There is one serial consumer for the lifetime of `MicrophoneCapture` and
/// at most one pending frame. If a UI callback ever wedges, future frames are
/// coalesced into that single slot instead of leaking one drain task and WAV
/// descriptor per dictation. The audio callback only takes a lock briefly.
final class CoalescingSampleObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "is.waiwai.dictation.capture-meter",
        qos: .userInteractive
    )
    private let consume: @Sendable ([Float]) -> Void
    private var pending: [Float]?
    private var isDraining = false

    init(consume: @escaping @Sendable ([Float]) -> Void) {
        self.consume = consume
    }

    func submit(_ samples: [Float]) {
        lock.lock()
        pending = samples
        guard !isDraining else {
            lock.unlock()
            return
        }
        isDraining = true
        lock.unlock()

        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let samples = pending else {
                isDraining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            consume(samples)
        }
    }
}

/// Lazy, single-flight reconstruction of a failed disk pipeline from the
/// complete bounded PCM copy. Header publication and physical durability use
/// the same process-wide gates as live recording, so one wedged filesystem
/// call can retain at most one task and descriptor of each kind.
final class MemoryRecoveryWAV: @unchecked Sendable {
    typealias WriterFactory = @Sendable (URL, Int) -> WAVWriter
    typealias Disposer = @Sendable (URL) -> Void

    private let lock = NSLock()
    private let finalURL: URL
    private let partialURL: URL
    private let samples: [Float]
    private let sampleRate: Int
    private let disposition: RecordingDisposition?
    private let writerFactory: WriterFactory
    private let disposer: Disposer
    private var task: Task<URL, Error>?

    init(
        originalURL: URL,
        samples: [Float],
        sampleRate: Int,
        disposition: RecordingDisposition? = nil,
        writerFactory: @escaping WriterFactory = {
            WAVWriter(url: $0, sampleRate: $1, channels: 1)
        },
        disposer: @escaping Disposer = { RecordingFileDisposer.shared.submit($0) }
    ) {
        let finalURL = originalURL.deletingLastPathComponent().appending(
            path: "memory-recovery-\(UUID().uuidString).wav",
            directoryHint: .notDirectory
        )
        self.finalURL = finalURL
        partialURL = finalURL.appendingPathExtension("partial")
        // Register both possible names before `materialize()` can suspend or
        // touch storage. Escape/success deletion therefore owns late files too.
        disposition?.register([partialURL, finalURL])
        self.samples = samples
        self.sampleRate = sampleRate
        self.disposition = disposition
        self.writerFactory = writerFactory
        self.disposer = disposer
    }

    func materialize() async throws -> URL {
        let work: Task<URL, Error> = lock.withLock {
            if let task { return task }
            let finalURL = finalURL
            let partialURL = partialURL
            let samples = samples
            let sampleRate = sampleRate
            let disposition = disposition
            let writerFactory = writerFactory
            let disposer = disposer
            let created = Task.detached(priority: .utility) {
                guard disposition?.state != .deleteRequested else {
                    throw CancellationError()
                }
                guard RecordingDiskWriteGate.shared.tryAcquire() else {
                    throw AudioCaptureError.writeFailed(
                        "another audio disk write is still in progress"
                    )
                }
                guard let closeReservation = RecordingWriterCloseContainment.shared.reserve() else {
                    RecordingDiskWriteGate.shared.release()
                    throw AudioCaptureError.writeFailed(
                        "recording writer cleanup is still in progress"
                    )
                }

                let writer = writerFactory(partialURL, sampleRate)
                let managedWriter = ManagedRecordingWriter(
                    writer: writer,
                    reservation: closeReservation
                )
                do {
                    try writer.open()
                    // `open()` is a non-cancellable syscall and may create the
                    // path after Escape's first disposal pass. Recheck before
                    // copying a potentially five-minute buffer; the catch path
                    // closes the descriptor and removes the registered partial.
                    guard disposition?.state != .deleteRequested else {
                        throw CancellationError()
                    }
                    try writer.append(samples)
                    _ = try writer.sealForReading()
                    guard disposition?.state != .deleteRequested else {
                        throw CancellationError()
                    }
                    // Same-directory rename is the publication boundary. A
                    // crash or fault before this line leaves only `.partial`,
                    // which launch recovery deliberately ignores.
                    try FileManager.default.moveItem(at: partialURL, to: finalURL)
                } catch {
                    RecordingDiskWriteGate.shared.release()
                    disposer(partialURL)
                    managedWriter.scheduleAbandon()
                    throw error
                }
                RecordingDiskWriteGate.shared.release()
                guard disposition?.state != .deleteRequested else {
                    managedWriter.scheduleAbandon(deleteURL: finalURL)
                    throw CancellationError()
                }

                guard RecordingDurabilityGate.shared.tryAcquire() else {
                    // The header and payload are already readable. Do not
                    // launch a second non-cancellable fsync behind a stalled
                    // one; close this descriptor and return the recovery copy.
                    managedWriter.scheduleAbandon()
                    return finalURL
                }
                defer { RecordingDurabilityGate.shared.release() }
                do {
                    try managedWriter.synchronizeAndClose()
                    if disposition?.state == .deleteRequested {
                        RecordingFileDisposer.shared.submit(finalURL)
                        throw CancellationError()
                    }
                    return finalURL
                } catch {
                    // The atomic publication is already complete and readable.
                    // WAVWriter releases its descriptor even when fsync/close
                    // reports an error; retain the final as recovery evidence
                    // and surface durability only as a diagnostic failure.
                    throw error
                }
            }
            task = created
            return created
        }
        return try await work.value
    }
}

private final class RecordingContext: @unchecked Sendable {
    let id: UUID
    let session: DictationSessionID
    let disposition: RecordingDisposition
    let url: URL
    let pcm: RecordingPCMBuffer
    let conversionSequencer: RecordingTapConversionSequencer
    let captureFailure: RecordingCaptureFailureLedger
    let diskAttachment: RecordingDiskAttachment
    let shutdownLease: RecordingEngineShutdownLease
    let freezeRecoveryLease: RecordingFreezeRecoveryLease
    let startedAt: ContinuousClock.Instant

    init(
        id: UUID,
        session: DictationSessionID,
        disposition: RecordingDisposition,
        url: URL,
        pcm: RecordingPCMBuffer,
        conversionSequencer: RecordingTapConversionSequencer,
        captureFailure: RecordingCaptureFailureLedger,
        diskAttachment: RecordingDiskAttachment,
        shutdownLease: RecordingEngineShutdownLease,
        freezeRecoveryLease: RecordingFreezeRecoveryLease,
        startedAt: ContinuousClock.Instant
    ) {
        self.id = id
        self.session = session
        self.disposition = disposition
        self.url = url
        self.pcm = pcm
        self.conversionSequencer = conversionSequencer
        self.captureFailure = captureFailure
        self.diskAttachment = diskAttachment
        self.shutdownLease = shutdownLease
        self.freezeRecoveryLease = freezeRecoveryLease
        self.startedAt = startedAt
    }
}

private struct RecordingPendingStart {
    let reservation: RecordingEngineStartReservation
    let context: RecordingContext
    let engine: AVAudioEngine
}

/// Pure identity predicate shared with the concurrency regression test. URL
/// alone is not enough: an old delayed callback must match the exact internal
/// session token before it may reach live failure UI.
func isCurrentRecordingSession(
    activeID: UUID?,
    activeURL: URL?,
    reportedID: UUID,
    reportedURL: URL
) -> Bool {
    activeID == reportedID && activeURL == reportedURL
}

func captureRequestMatches(
    activeSession: DictationSessionID,
    activeURL: URL,
    expectedSession: DictationSessionID?,
    expectedURL: URL?
) -> Bool {
    let sessionMatches = expectedSession.map { activeSession == $0 } ?? true
    let urlMatches = expectedURL.map { activeURL == $0 } ?? true
    return sessionMatches && urlMatches
}

func recordingStartMayAdopt(
    pendingID: UUID?,
    pendingSession: DictationSessionID?,
    pendingURL: URL?,
    completedID: UUID,
    completedSession: DictationSessionID,
    completedURL: URL,
    disposition: RecordingDisposition.State,
    isTombstoned: Bool
) -> Bool {
    !isTombstoned
        && disposition == .active
        && pendingID == completedID
        && pendingSession == completedSession
        && pendingURL == completedURL
}

enum RecordingAdmissionDecision: Equatable {
    case accept
    case reject
    case supersedeDestructively
    case supersedeTechnically
}

/// Controller state may publish idle before its asynchronous contain/abort
/// message enters the capture actor. The disposition is the synchronous causal
/// handoff: only a strictly newer token may reclaim an old context, and only
/// after the old owner has irrevocably selected delete or background recovery.
func recordingAdmissionDecision(
    activeSession: DictationSessionID?,
    activeDisposition: RecordingDisposition.State?,
    requestedSession: DictationSessionID
) -> RecordingAdmissionDecision {
    guard let activeSession, let activeDisposition else { return .accept }
    guard activeSession < requestedSession else { return .reject }
    switch activeDisposition {
    case .deleteRequested:
        return .supersedeDestructively
    case .keepInBackground:
        return .supersedeTechnically
    case .active, .published:
        return .reject
    }
}

/// Capture actors only detach ownership. Filesystem unlink and descriptor
/// closure happen elsewhere so a wedged volume cannot hold microphone state.
private func scheduleRecordingDisposal(url: URL, writer: WAVWriter) {
    abandonRecordingWriter(writer, managedWriter: nil, deleteURL: url)
}

private func abandonRecordingWriter(
    _ writer: WAVWriter,
    managedWriter: ManagedRecordingWriter?,
    deleteURL: URL? = nil
) {
    if let managedWriter {
        managedWriter.scheduleAbandon(deleteURL: deleteURL)
        return
    }
    if let deleteURL { RecordingFileDisposer.shared.submit(deleteURL) }
    // Compatibility-only writers in unit tests predate production lifecycle
    // reservations. Every production open carries `ManagedRecordingWriter`.
    Task.detached(priority: .utility) { writer.abandonForRecovery() }
}

/// At most one non-cancellable kernel fsync may be outstanding process-wide.
/// If storage wedges, later recordings close their already-readable WAVs
/// instead of accumulating one stuck task and descriptor per dictation.
private final class RecordingDurabilityGate: @unchecked Sendable {
    static let shared = RecordingDurabilityGate()

    private let lock = NSLock()
    private var isOccupied = false

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOccupied else { return false }
        isOccupied = true
        return true
    }

    func release() {
        lock.lock()
        precondition(isOccupied)
        isOccupied = false
        lock.unlock()
    }
}

/// Detach disk finalization from the live capture actor. The readable task
/// drains and seals; the durable task performs the potentially slow fsync.
/// Neither task owns microphone state, so an old completion cannot touch a
/// later session.
func finalizeCapturedRecording(
    url: URL,
    writer: WAVWriter,
    managedWriter: ManagedRecordingWriter? = nil,
    disk: RecordingDiskState,
    sink: FrameSink,
    frozen: FrozenPCM,
    sampleRate: Double,
    startupLatency: Duration? = nil,
    disposition: RecordingDisposition = RecordingDisposition()
) -> CapturedRecording {
    let drain = sink.seal()
    let readable = Task.detached(priority: .utility) {
        await drain.value
        if let failure = disk.recordedFailure {
            abandonRecordingWriter(writer, managedWriter: managedWriter)
            throw failure
        }
        guard RecordingDiskWriteGate.shared.tryAcquire() else {
            abandonRecordingWriter(writer, managedWriter: managedWriter)
            throw AudioCaptureError.writeFailed("another audio disk write is still in progress")
        }
        defer { RecordingDiskWriteGate.shared.release() }
        do {
            return try writer.sealForReading()
        } catch {
            // `WAVWriter` releases its FileHandle on a seal fault, but the
            // production lifecycle reservation is separate ownership. Hand it
            // through the exact-once bounded abandon path or two header faults
            // would permanently force every later take into memory-only mode.
            abandonRecordingWriter(writer, managedWriter: managedWriter)
            throw error
        }
    }
    let durable = Task.detached(priority: .utility) {
        let finishedURL = try await readable.value
        guard RecordingDurabilityGate.shared.tryAcquire() else {
            // The final header is already readable. Close promptly, retain the
            // recovery file, and report that physical durability was not
            // proven instead of starting an unbounded fsync backlog.
            abandonRecordingWriter(writer, managedWriter: managedWriter)
            throw AudioCaptureError.writeFailed("recording durability is busy")
        }
        defer { RecordingDurabilityGate.shared.release() }
        if let managedWriter {
            try managedWriter.synchronizeAndClose()
        } else {
            try writer.synchronizeAndClose()
        }
        return finishedURL
    }
    let recovery = frozen.samples.map {
        MemoryRecoveryWAV(
            originalURL: url,
            samples: $0,
            sampleRate: Int(sampleRate),
            disposition: disposition
        )
    }
    let materializeRecovery: (@Sendable () async throws -> URL)?
    if let recovery {
        materializeRecovery = { try await recovery.materialize() }
    } else {
        materializeRecovery = nil
    }

    return CapturedRecording(
        url: url,
        duration: Double(frozen.totalSamples) / sampleRate,
        samples: frozen.samples,
        startupLatency: startupLatency,
        disposition: disposition,
        readableTask: readable,
        durableTask: durable,
        materializeRecovery: materializeRecovery
    )
}

/// A filesystem open is never a prerequisite for local dictation. When the
/// one-flight writer slot is busy or loses the race to the first PCM frame,
/// recognition receives the complete bounded samples immediately. A WAV is
/// materialized lazily only if failure recovery actually needs one.
func finalizeMemoryOnlyCapturedRecording(
    url: URL,
    frozen: FrozenPCM,
    sampleRate: Double,
    startupLatency: Duration? = nil,
    disposition: RecordingDisposition = RecordingDisposition()
) -> CapturedRecording {
    let unavailable = Task.detached(priority: .utility) { () throws -> URL in
        throw AudioCaptureError.writeFailed("the opportunistic recording file is unavailable")
    }
    let recovery = frozen.samples.map {
        MemoryRecoveryWAV(
            originalURL: url,
            samples: $0,
            sampleRate: Int(sampleRate),
            disposition: disposition
        )
    }
    let materializeRecovery: (@Sendable () async throws -> URL)?
    if let recovery {
        materializeRecovery = { try await recovery.materialize() }
    } else {
        materializeRecovery = nil
    }
    return CapturedRecording(
        url: url,
        duration: Double(frozen.totalSamples) / sampleRate,
        samples: frozen.samples,
        startupLatency: startupLatency,
        disposition: disposition,
        readableTask: unavailable,
        durableTask: unavailable,
        materializeRecovery: materializeRecovery
    )
}

private func finalizeRecordingContext(
    _ context: RecordingContext,
    pipeline: RecordingDiskPipeline?,
    frozen: FrozenPCM,
    sampleRate: Double
) -> CapturedRecording {
    let startupLatency = frozen.firstFrameAt.map {
        context.startedAt.duration(to: $0)
    }
    if let pipeline {
        return finalizeCapturedRecording(
            url: context.url,
            writer: pipeline.writer,
            managedWriter: pipeline.managedWriter,
            disk: pipeline.disk,
            sink: pipeline.sink,
            frozen: frozen,
            sampleRate: sampleRate,
            startupLatency: startupLatency,
            disposition: context.disposition
        )
    }
    return finalizeMemoryOnlyCapturedRecording(
        url: context.url,
        frozen: frozen,
        sampleRate: sampleRate,
        startupLatency: startupLatency,
        disposition: context.disposition
    )
}

private func preserveTechnicalRecording(_ recording: CapturedRecording) async {
    do {
        _ = try await recording.readableURL()
        _ = try? await recording.durableURL()
    } catch {
        // A failed/absent raw pipeline still has the bounded valid PCM prefix.
        // Materialization is atomic, single-flight, disposition-aware, and
        // globally storage-gated.
        _ = try? await recording.materializedRecoveryURL()
    }
}

/// Technical capture failures own at most two recovery leases. Serialize their
/// storage work as one active plus one pending job so simultaneous memory-only
/// containments do not race the process-wide WAV write gate and discard one
/// otherwise complete prefix.
final class RecordingTechnicalPreservationContainment: @unchecked Sendable {
    typealias Operation = @Sendable () async -> Void

    private struct Job: Sendable {
        let id = UUID()
        let operation: Operation
        let releaseCapacity: @Sendable () -> Void
    }

    static let shared = RecordingTechnicalPreservationContainment()

    private let lock = NSLock()
    private var active: Job?
    private var pending: Job?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func submit(
        _ operation: @escaping Operation,
        releaseCapacity: @escaping @Sendable () -> Void = {}
    ) {
        let job = Job(operation: operation, releaseCapacity: releaseCapacity)
        let shouldLaunch: Bool = lock.withLock {
            if active == nil {
                active = job
                return true
            }
            precondition(pending == nil, "technical recovery lease bound exceeded")
            pending = job
            return false
        }
        if shouldLaunch { launch(job) }
    }

    private func launch(_ job: Job) {
        Task.detached(priority: .utility) { [self] in
            await job.operation()
            finished(job)
        }
    }

    private func finished(_ job: Job) {
        let result: (Job?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard active?.id == job.id else { return (nil, []) }
            if let next = pending {
                active = next
                pending = nil
                // Publish the free recovery lease only after this lane has a
                // slot for the newly admitted generation. Otherwise N+2 can
                // reserve in the tiny operation→finished gap and hit a full
                // active+pending queue.
                job.releaseCapacity()
                return (next, [])
            }
            active = nil
            job.releaseCapacity()
            let waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: false)
            return (nil, waiters)
        }
        if let next = result.0 { launch(next) }
        for waiter in result.1 { waiter.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if active == nil, pending == nil {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

func scheduleTechnicalRecordingPreservation(
    _ recording: CapturedRecording,
    lease: RecordingFreezeRecoveryLease,
    containment: RecordingTechnicalPreservationContainment = .shared,
    storageDeadline: Duration = .milliseconds(500)
) {
    containment.submit({
        do {
            try await withTranscriptionDeadline(storageDeadline) {
                await preserveTechnicalRecording(recording)
            }
        } catch {
            // The underlying descriptor/write lanes are independently bounded.
            // This deadline owns only the recovery lease and availability of
            // future captures; a cancellation-deaf syscall may finish later.
        }
    }, releaseCapacity: {
        lease.release()
    })
}

private func scheduleCancelledFreezePreservation(
    context: RecordingContext,
    pipeline: RecordingDiskPipeline?,
    prefrozen: FrozenPCM,
    sampleRate: Double
) {
    Task.detached(priority: .utility) {
        let frozen = await context.pcm.recoverAfterCancelledFreeze(
            prefrozen: prefrozen
        ) {
            context.disposition.state != .deleteRequested
        }
        guard context.disposition.state != .deleteRequested else {
            if let pipeline {
                pipeline.sink.cancel()
                abandonRecordingWriter(
                    pipeline.writer,
                    managedWriter: pipeline.managedWriter,
                    deleteURL: context.url
                )
            }
            context.freezeRecoveryLease.release()
            return
        }
        let recording = finalizeRecordingContext(
            context,
            pipeline: pipeline,
            frozen: frozen,
            sampleRate: sampleRate
        )
        scheduleTechnicalRecordingPreservation(
            recording,
            lease: context.freezeRecoveryLease
        )
    }
}

/// Record from a microphone to a file.
///
/// The engine rises at the moment the key is pressed and turns off immediately after recording:
/// the promise “the recording indicator is off while we are not listening” depends on this.
/// The price for this is a delay in the cold start, so the start is done as much as possible
/// short, and the confirmation sound plays only after the first frame arrived.
public actor MicrophoneCapture: AudioCapturing {
    public typealias ConverterFactory = @Sendable (AVAudioFormat, AVAudioFormat) -> AVAudioConverter?
    private let logger = Logger(subsystem: "is.waiwai.dictation", category: "capture")

    /// Where to put the records.
    private let directory: URL
    private let sampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var activeContext: RecordingContext?
    /// A generation whose synchronous AVFAudio start call is executing on the
    /// bounded external lane. The actor owns only its logical token/context,
    /// so contain/abort and N+1 admission remain runnable during a native wedge.
    private var pendingStart: RecordingPendingStart?
    private var sessionTombstones = RecordingSessionTombstones()
    /// Compatibility storage for callers using the old two-call
    /// `stopRecording()` / `takeBufferedSamples()` API. Production receives
    /// PCM atomically in `CapturedRecording` and never touches this slot.
    private var legacyBufferedSamples: [Float]?

    /// Exact key/start-call acceptance → first committed 16 kHz frame SLO.
    /// This includes AVAudio format/engine setup, but never waits for the
    /// opportunistic disk writer. The snapshot is copied into the recording.
    private var timingSessionID: UUID?
    private var firstBufferAt: ContinuousClock.Instant?
    private var startedAt: ContinuousClock.Instant?

    /// Waiting for the first frame - `waitForFirstFrame()` answers them.
    ///
    /// Everyone awakens exactly once: either by an incoming frame or by the end
    /// records. There is no second source of awakening on purpose - forgotten here
    /// the continuation would freeze the start of the dictation.
    private var firstFrameWaiters: [CheckedContinuation<Bool, Never>] = []

    /// The recording broke right during the speech.
    ///
    /// You can’t remain silent until it stops: the disk space has run out, otherwise
    /// will be discovered after five minutes of speaking - and there will be no more text.
    private let failureObserver: CoalescingCaptureFailureObserver
    /// Graceful capacity notification for a memory-only take. This is distinct
    /// from a user stop/interrupt: the controller freezes and transcribes the
    /// complete retained prefix under its normal stop SLO.
    private let memoryLimitObserver: CoalescingCaptureLimitObserver
    /// Best-effort samples listener for disposable UI metering only.
    ///
    /// Frames are 16 kHz mono but may be coalesced or dropped under load and do
    /// not carry a session identity. Streaming ASR, VAD, persistence, and any
    /// content-sensitive consumer must use a separate lossless/session-scoped
    /// path. The only production call site reduces these samples to a waveform
    /// peak; recognition uses `CapturedRecording.samples` instead.
    private let sampleObserver: CoalescingSampleObserver
    private let converterFactory: ConverterFactory

    /// Which microphone to record through, or `nil` for whatever the system
    /// calls default.
    private let preferredInputDeviceID: AudioDeviceID?

    /// Ask the engine's input unit to use one particular device.
    ///
    /// Refuses loudly rather than recording from the wrong microphone. Someone
    /// who chose a headset and silently got the laptop lid instead would only
    /// find out from the transcript, which is far too late.
    private func selectInputDevice(_ id: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else {
            throw AudioCaptureError.engineUnavailable("no input unit to choose a microphone on")
        }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.engineUnavailable(
                "the chosen microphone didn't accept the recording (\(status))"
            )
        }
    }

    public init(
        directory: URL,
        onFailure: @escaping @Sendable (DictationSessionID, AudioCaptureError) -> Void = { _, _ in },
        onSamples: @escaping @Sendable ([Float]) -> Void = { _ in },
        onMemoryLimitReached: @escaping @Sendable (DictationSessionID) -> Void = { _ in },
        converterFactory: @escaping ConverterFactory = { AVAudioConverter(from: $0, to: $1) },
        preferredInputDeviceID: AudioDeviceID? = nil
    ) {
        self.preferredInputDeviceID = preferredInputDeviceID
        self.directory = directory
        failureObserver = CoalescingCaptureFailureObserver(consume: onFailure)
        memoryLimitObserver = CoalescingCaptureLimitObserver(consume: onMemoryLimitReached)
        sampleObserver = CoalescingSampleObserver(consume: onSamples)
        self.converterFactory = converterFactory
    }

    /// How long from actor acceptance of `startRecording` to the first
    /// nonempty 16 kHz frame committed to the lossless PCM session.
    ///
    /// `stopRecording` does not reset these marks; only a newer accepted start
    /// does, so reading after stopping is legal.
    public func startupLatency() async -> Duration? {
        guard let startedAt, let firstBufferAt else { return nil }
        return startedAt.duration(to: firstBufferAt)
    }

    /// The first frame has already arrived - or it won’t happen.
    ///
    /// It's safe to wait: the continuation is registered and the actor is released, so
    /// stopping and interrupting the recording goes through and wakes up those waiting.
    public func waitForFirstFrame() async -> Bool {
        if firstBufferAt != nil { return true }
        guard engine != nil || pendingStart != nil else { return false }
        return await withCheckedContinuation { continuation in
            firstFrameWaiters.append(continuation)
        }
    }

    private func wakeFirstFrameWaiters(arrived: Bool) {
        guard !firstFrameWaiters.isEmpty else { return }
        let waiting = firstFrameWaiters
        firstFrameWaiters = []
        for waiter in waiting { waiter.resume(returning: arrived) }
    }

    public func startRecording() async throws -> URL {
        try await startActiveRecording(
            session: DictationSessionID(),
            disposition: RecordingDisposition()
        )
    }

    /// The controller owns this monotonic identity before it asks AVFAudio to
    /// start. It therefore fences cancellation even while `startRecording`
    /// has not returned a URL yet.
    public func startRecording(session: DictationSessionID) async throws -> URL {
        try await startActiveRecording(
            session: session,
            disposition: RecordingDisposition()
        )
    }

    public func startRecording(
        session: DictationSessionID,
        disposition: RecordingDisposition
    ) async throws -> URL {
        try await startActiveRecording(session: session, disposition: disposition)
    }

    private func startActiveRecording(
        session: DictationSessionID,
        disposition: RecordingDisposition
    ) async throws -> URL {
        guard !sessionTombstones.contains(session),
              disposition.state == .active else {
            throw CancellationError()
        }
        if engine != nil || activeContext != nil || pendingStart != nil {
            guard detachSupersededRecordingForAdmission(requestedSession: session) else {
                throw AudioCaptureError.engineUnavailable("recording is already in progress")
            }
        }
        guard engine == nil, activeContext == nil, pendingStart == nil else {
            throw AudioCaptureError.engineUnavailable("recording is already in progress")
        }
        guard let startReservation = RecordingEngineStartContainment.shared.reserve() else {
            throw AudioCaptureError.engineUnavailable(
                "previous microphone starts are still in progress"
            )
        }
        var startWasSubmitted = false
        defer {
            if !startWasSubmitted {
                RecordingEngineStartContainment.shared.release(startReservation)
            }
        }

        // Those waiting for the last entry (if there are any left) will no longer wait for it
        // frame: their recording has ended.
        wakeFirstFrameWaiters(arrived: false)
        timingSessionID = nil
        let acceptedAt = ContinuousClock.now
        startedAt = acceptedAt
        firstBufferAt = nil
        legacyBufferedSamples = nil

        let url = directory.appending(
            path: "take-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).wav",
            directoryHint: .notDirectory
        )
        disposition.register([url])

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Point the engine at the chosen microphone before anything reads a
        // format from it. After that the node has already negotiated with a
        // device and changing it is ignored.
        if let preferredInputDeviceID {
            try selectInputDevice(preferredInputDeviceID, on: input)
        }
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.engineUnavailable("microphone unavailable")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.engineUnavailable("couldn't create the recording format")
        }

        // Resampling is almost always needed: the built-in microphone outputs 44.1 or 48 kHz,
        // and recognition waits for 16 kHz.
        let converter: AVAudioConverter?
        do {
            converter = try Self.converter(
                from: inputFormat,
                to: targetFormat,
                factory: converterFactory
            )
        } catch {
            throw error
        }
        guard let shutdownReservation = RecordingEngineShutdownContainment.shared.reserve() else {
            throw AudioCaptureError.engineUnavailable(
                "previous microphone shutdowns are still in progress"
            )
        }
        guard let freezeRecoveryReservation = RecordingFreezeRecoveryContainment.shared.reserve()
        else {
            RecordingEngineShutdownContainment.shared.release(shutdownReservation)
            throw AudioCaptureError.engineUnavailable(
                "previous recording recovery callbacks are still in progress"
            )
        }
        let freezeRecoveryLease = RecordingFreezeRecoveryLease(
            reservation: freezeRecoveryReservation
        )
        let shutdownLease = RecordingEngineShutdownLease(
            reservation: shutdownReservation,
            engine: engine,
            input: input
        )

        let sessionID = UUID()
        let pcm = RecordingPCMBuffer(maximumSamples: 5 * 60 * Int(sampleRate))
        let conversionSequencer = RecordingTapConversionSequencer()
        let captureFailure = RecordingCaptureFailureLedger()
        let diskAttachment = RecordingDiskAttachment {
            RecordingWriterOpenCoordinator.shared.cancel(session: session)
        }
        let context = RecordingContext(
            id: sessionID,
            session: session,
            disposition: disposition,
            url: url,
            pcm: pcm,
            conversionSequencer: conversionSequencer,
            captureFailure: captureFailure,
            diskAttachment: diskAttachment,
            shutdownLease: shutdownLease,
            freezeRecoveryLease: freezeRecoveryLease,
            startedAt: acceptedAt
        )
        pendingStart = RecordingPendingStart(
            reservation: startReservation,
            context: context,
            engine: engine
        )
        timingSessionID = context.id
        self.converter = converter

        let sampleObserver = sampleObserver
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, when in
            let sampleTime = when.isSampleTimeValid ? when.sampleTime : nil
            guard let frame = pcm.beginFrame(sampleTime: sampleTime) else { return }
            defer { pcm.endFrame() }

            do {
                let samples = try conversionSequencer.perform(frame: frame) {
                    let samples = try Self.extractSamples(
                        from: buffer,
                        using: converter,
                        target: targetFormat
                    )
                    guard !samples.isEmpty else { return samples }
                    let at = ContinuousClock.now
                    let append = pcm.append(
                        samples,
                        frame: frame,
                        at: at,
                        // A queued/unsealed WAV can fail after any health
                        // snapshot. The five-minute boundary therefore always
                        // retains PCM and gracefully stops; only stop+drain may
                        // establish a complete disk artifact.
                        preserveAtLimit: true
                    )
                    guard !append.wasRejected else {
                        // Cancelled-freeze recovery already sealed this old
                        // generation. The late converter result must not reach
                        // its WAV, metering, or first-frame observer.
                        return []
                    }
                    if append.isFirstFrame {
                        Task { [weak self] in
                            await self?.markFirstFrame(sessionID: sessionID, at: at)
                        }
                    }
                    if append.didReachHardLimit {
                        if let committed = append.committedSamples {
                            diskAttachment.submit(committed)
                        }
                        // Preserve the complete bounded prefix and prevent
                        // already-overlapped callbacks from committing behind
                        // it. This is a graceful controller stop, never a fatal
                        // ledger entry that would discard recognizer-ready PCM.
                        conversionSequencer.cancelPending()
                        diskAttachment.closeForMemoryLimit()
                        Task { [weak self] in
                            await self?.reportMemoryLimitReached(
                                sessionID: sessionID,
                                url: url
                            )
                        }
                        return []
                    }
                    // Disk is best-effort and may still be opening. The first
                    // commit atomically chooses either a complete WAV or no
                    // WAV, never an apparently valid file missing its prefix.
                    diskAttachment.submit(samples)
                    if append.didOverflowMemory,
                       !diskAttachment.memoryDidOverflow() {
                        let failure = AudioCaptureError.writeFailed(
                            "the in-memory recording limit was reached without a complete disk copy"
                        )
                        conversionSequencer.cancelPending()
                        if captureFailure.record(failure) {
                            Task { [weak self] in
                                await self?.reportLiveFailure(
                                    failure,
                                    sessionID: sessionID,
                                    url: url
                                )
                            }
                        }
                    }
                    // The turn covers the full lossless commit, not just the
                    // stateful converter. Otherwise overlapped callbacks could
                    // reorder the WAV after the five-minute PCM fallback.
                    return samples
                }
                guard !samples.isEmpty else { return }
                // Metering is deliberately outside the ordered/lossless turn:
                // it coalesces frames and cannot affect captured content.
                sampleObserver.submit(samples)
            } catch is CancellationError {
                // Normal for callbacks waiting behind a session that was
                // cancelled. The old session owns no live failure UI anymore.
            } catch {
                let failure = AudioCaptureError.unsupportedAudioFormat(
                    "audio conversion failed: \(error.localizedDescription)"
                )
                conversionSequencer.cancelPending()
                if captureFailure.record(failure) {
                    Task { [weak self] in
                        await self?.reportLiveFailure(
                            failure,
                            sessionID: sessionID,
                            url: url
                        )
                    }
                }
            }
        }

        let reportDiskFailure: @Sendable (AudioCaptureError) -> Void = { [weak self] error in
            Task { [weak self] in
                await self?.reportLiveFailure(
                    error,
                    sessionID: sessionID,
                    url: url
                )
            }
        }
        let writer = WAVWriter(url: url, sampleRate: Int(sampleRate), channels: 1)
        let writerWasSubmitted = RecordingWriterOpenCoordinator.shared.begin(
            writer: writer,
            session: session,
            disposition: disposition
        ) { result in
            switch result {
            case let .opened(managedWriter):
                let disk = RecordingDiskState(
                    writer: managedWriter.writer,
                    onUnrecoverableFailure: reportDiskFailure
                )
                let sink = FrameSink()
                let enqueue = sink.start(
                    onOverflow: { disk.queueOverflowed() },
                    consume: { disk.append($0) }
                )
                let pipeline = RecordingDiskPipeline(
                    managedWriter: managedWriter,
                    disk: disk,
                    sink: sink,
                    enqueue: enqueue
                )
                guard diskAttachment.attach(pipeline) else {
                    sink.cancel()
                    managedWriter.scheduleAbandon(deleteURL: url)
                    return
                }
            case .failed, .cancelled:
                diskAttachment.openFailed()
            }
        }
        if !writerWasSubmitted {
            diskAttachment.openFailed()
        }

        let startJob = RecordingEngineStartJob(engine: engine)
        startWasSubmitted = true
        let startOutcome = await RecordingEngineStartContainment.shared.start(
            reservation: startReservation,
            operation: { startJob.run() },
            onAbandon: {
                // Cancellation may return to the actor/controller long before
                // AVFAudio does. Only the native owner may shut this generation
                // down after its start call finally leaves the framework.
                shutdownLease.schedule()
            }
        )

        switch startOutcome {
        case .started:
            let mayAdopt = recordingStartMayAdopt(
                pendingID: pendingStart?.context.id,
                pendingSession: pendingStart?.context.session,
                pendingURL: pendingStart?.context.url,
                completedID: context.id,
                completedSession: session,
                completedURL: url,
                disposition: disposition.state,
                isTombstoned: sessionTombstones.contains(session) || Task.isCancelled
            )
            guard mayAdopt else {
                if pendingStart?.context.id == context.id {
                    let decision: RecordingAdmissionDecision =
                        disposition.state == .keepInBackground
                        ? .supersedeTechnically
                        : .supersedeDestructively
                    _ = detachPendingStart(
                        matching: context.id,
                        decision: decision,
                        cancelNativeStart: false
                    )
                }
                shutdownLease.schedule()
                throw CancellationError()
            }
            pendingStart = nil
            activeContext = context
            self.engine = engine
            return url

        case let .failed(error):
            if pendingStart?.context.id == context.id {
                _ = disposition.requestDelete()
                _ = detachPendingStart(
                    matching: context.id,
                    decision: .supersedeDestructively,
                    cancelNativeStart: false
                )
            }
            shutdownLease.schedule()
            throw error

        case .cancelled:
            // Normal contain/abort already detached this context. Direct task
            // cancellation has no separate owner, so perform the same bounded
            // destructive logical teardown here. Native shutdown stays with
            // `onAbandon` and cannot race the executing start call.
            if pendingStart?.context.id == context.id {
                _ = disposition.requestDelete()
                _ = detachPendingStart(
                    matching: context.id,
                    decision: .supersedeDestructively,
                    cancelNativeStart: true
                )
            }
            throw CancellationError()
        }
    }

    /// Logical teardown is synchronous with N+1 admission. AVFAudio shutdown,
    /// PCM recovery, writer closure, and deletion remain on their bounded
    /// lanes, so a delayed cleanup message for N can only observe N+1 later and
    /// fail its exact session fence.
    @discardableResult
    private func detachPendingStart(
        matching contextID: UUID,
        decision: RecordingAdmissionDecision,
        cancelNativeStart: Bool
    ) -> Bool {
        guard let pendingStart, pendingStart.context.id == contextID else {
            return false
        }
        precondition(
            decision == .supersedeDestructively
                || decision == .supersedeTechnically
        )

        let context = pendingStart.context
        wakeFirstFrameWaiters(arrived: false)
        context.pcm.closeAdmission()
        context.conversionSequencer.cancelPending()
        self.pendingStart = nil
        converter = nil
        legacyBufferedSamples = nil
        if cancelNativeStart {
            RecordingEngineStartContainment.shared.cancel(
                reservation: pendingStart.reservation
            )
        }
        let pipeline = context.diskAttachment.takePipeline()

        switch decision {
        case .supersedeDestructively:
            context.pcm.discard()
            context.freezeRecoveryLease.release()
            if let pipeline {
                pipeline.sink.cancel()
                abandonRecordingWriter(
                    pipeline.writer,
                    managedWriter: pipeline.managedWriter,
                    deleteURL: context.url
                )
            }
        case .supersedeTechnically:
            scheduleCancelledFreezePreservation(
                context: context,
                pipeline: pipeline,
                prefrozen: FrozenPCM(
                    samples: nil,
                    totalSamples: 0,
                    firstFrameAt: nil,
                    recoverySnapshotPending: true
                ),
                sampleRate: sampleRate
            )
        case .accept, .reject:
            preconditionFailure("invalid pending-start detach decision")
        }
        return true
    }

    private func detachSupersededRecordingForAdmission(
        requestedSession: DictationSessionID
    ) -> Bool {
        if let pendingStart {
            let decision = recordingAdmissionDecision(
                activeSession: pendingStart.context.session,
                activeDisposition: pendingStart.context.disposition.state,
                requestedSession: requestedSession
            )
            guard decision == .supersedeDestructively
                    || decision == .supersedeTechnically else {
                return false
            }
            return detachPendingStart(
                matching: pendingStart.context.id,
                decision: decision,
                cancelNativeStart: true
            )
        }

        guard let oldEngine = engine, let context = activeContext else { return false }
        let decision = recordingAdmissionDecision(
            activeSession: context.session,
            activeDisposition: context.disposition.state,
            requestedSession: requestedSession
        )
        guard decision == .supersedeDestructively
                || decision == .supersedeTechnically else {
            return false
        }

        wakeFirstFrameWaiters(arrived: false)
        context.pcm.closeAdmission()
        context.conversionSequencer.cancelPending()
        engine = nil
        converter = nil
        activeContext = nil
        legacyBufferedSamples = nil
        let pipeline = context.diskAttachment.takePipeline()
        _ = oldEngine // Context's lease retains the exact adopted generation.
        context.shutdownLease.schedule()

        switch decision {
        case .supersedeDestructively:
            context.pcm.discard()
            context.freezeRecoveryLease.release()
            if let pipeline {
                pipeline.sink.cancel()
                abandonRecordingWriter(
                    pipeline.writer,
                    managedWriter: pipeline.managedWriter,
                    deleteURL: context.url
                )
            }
        case .supersedeTechnically:
            scheduleCancelledFreezePreservation(
                context: context,
                pipeline: pipeline,
                prefrozen: FrozenPCM(
                    samples: nil,
                    totalSamples: 0,
                    firstFrameAt: nil,
                    recoverySnapshotPending: true
                ),
                sampleRate: sampleRate
            )
        case .accept, .reject:
            preconditionFailure("admission decision changed after detach")
        }
        return true
    }

    /// Storage and converter callbacks can finish after their tap was removed.
    /// Route them through the actor and fence by both session identity and URL
    /// so a stale old failure can never interrupt a newer dictation.
    private func currentContext(sessionID: UUID, url: URL) -> RecordingContext? {
        for context in [activeContext, pendingStart?.context].compactMap({ $0 }) {
            if isCurrentRecordingSession(
                activeID: context.id,
                activeURL: context.url,
                reportedID: sessionID,
                reportedURL: url
            ) {
                return context
            }
        }
        return nil
    }

    private func reportLiveFailure(
        _ error: AudioCaptureError,
        sessionID: UUID,
        url: URL
    ) {
        guard let context = currentContext(sessionID: sessionID, url: url) else { return }
        logger.error("Recording interrupted: \(String(describing: error), privacy: .public)")
        failureObserver.submit(session: context.session, error: error)
    }

    private func reportMemoryLimitReached(sessionID: UUID, url: URL) {
        guard let context = currentContext(sessionID: sessionID, url: url) else { return }
        memoryLimitObserver.submit(session: context.session)
    }

    private func markFirstFrame(sessionID: UUID, at instant: ContinuousClock.Instant) {
        guard activeContext?.id == sessionID || pendingStart?.context.id == sessionID else {
            return
        }
        if firstBufferAt == nil {
            firstBufferAt = instant
            // Only now the microphone actually hears: before this line the sound
            // confirmation would fool the person by a tenth of a second, and
            // the first word would disappear into silence.
            wakeFirstFrameWaiters(arrived: true)
        }
    }

    public func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        let recording = try await freezeRecording()
        do {
            _ = try await recording.durableURL()
        } catch {
            legacyBufferedSamples = nil
            throw AudioCaptureError.writeFailed(String(describing: error))
        }
        legacyBufferedSamples = recording.samples
        return (recording.url, recording.duration)
    }

    public func freezeRecording() async throws -> CapturedRecording {
        try await freezeActiveRecording(expectedSession: nil, expectedURL: nil)
    }

    /// Production stop is fenced by the URL returned from `startRecording`.
    /// A stale controller finalizer therefore cannot detach a newer session.
    public func freezeRecording(expectedURL: URL) async throws -> CapturedRecording {
        try await freezeActiveRecording(expectedSession: nil, expectedURL: expectedURL)
    }

    /// Both identities are checked while isolated to this actor and before the
    /// engine/context is detached. A late stop from N can never freeze N+1.
    public func freezeRecording(
        session: DictationSessionID,
        expectedURL: URL
    ) async throws -> CapturedRecording {
        try await freezeActiveRecording(
            expectedSession: session,
            expectedURL: expectedURL
        )
    }

    private func freezeActiveRecording(
        expectedSession: DictationSessionID?,
        expectedURL: URL?
    ) async throws -> CapturedRecording {
        guard engine != nil, let context = activeContext else {
            throw AudioCaptureError.notRecording
        }
        guard captureRequestMatches(
            activeSession: context.session,
            activeURL: context.url,
            expectedSession: expectedSession,
            expectedURL: expectedURL
        ) else {
            throw AudioCaptureError.notRecording
        }
        // You can no longer wait for the frame: the recording ends. Otherwise, start the session,
        // hanging on a silent device, would never let go.
        wakeFirstFrameWaiters(arrived: false)

        // Logical ownership and callback admission close before any AVFAudio
        // join. `stop()`/`removeTap()` occasionally block inside the framework;
        // that abandoned generation is contained off-actor so N+1 can start.
        context.pcm.closeAdmission()
        context.conversionSequencer.cancelPending()
        self.engine = nil
        self.converter = nil
        activeContext = nil
        context.shutdownLease.schedule()

        // A callback that entered before admission closed still owns one frame.
        // Freeze waits only for that CPU conversion, never for disk or fsync.
        let frozen = await context.pcm.freeze()
        if timingSessionID == context.id, firstBufferAt == nil {
            firstBufferAt = frozen.firstFrameAt
        }
        let pipeline = context.diskAttachment.takePipeline()

        if Task.isCancelled {
            // A deadline/cancel can fire while a converter callback is stuck.
            // The foreground waiter returns promptly, but its bounded recovery
            // lease keeps all committed chunks and the in-flight last callback
            // discoverable outside this actor.
            _ = context.disposition.keepInBackground()
            scheduleCancelledFreezePreservation(
                context: context,
                pipeline: pipeline,
                prefrozen: frozen,
                sampleRate: sampleRate
            )
            throw CancellationError()
        }

        let recording = finalizeRecordingContext(
            context,
            pipeline: pipeline,
            frozen: frozen,
            sampleRate: sampleRate
        )
        if let fatalCaptureFailure = context.captureFailure.recordedFailure {
            // The callback barrier above guarantees the final callback either
            // committed a whole frame or synchronously recorded this failure.
            // Never return the prefix to ASR as success, but do preserve it as
            // technical recovery. The original conversion error remains the
            // foreground result.
            _ = context.disposition.keepInBackground()
            scheduleTechnicalRecordingPreservation(
                recording,
                lease: context.freezeRecoveryLease
            )
            throw fatalCaptureFailure
        }

        context.freezeRecoveryLease.release()
        return recording
    }

    public func takeBufferedSamples() async -> [Float]? {
        guard let samples = legacyBufferedSamples, !samples.isEmpty else { return nil }
        legacyBufferedSamples = nil
        return samples
    }

    /// Technical containment is deliberately different from user abort. It
    /// fences the exact session and detaches AVFAudio promptly, but preserves
    /// any complete raw WAV or bounded PCM prefix for launch-time recovery.
    /// An absent/stale context is a no-op: in particular `expectedURL` is never
    /// unlinked here because a late finalizer may already own that file.
    public func containRecording(
        session: DictationSessionID,
        expectedURL: URL?
    ) async {
        sessionTombstones.recordCancellation(session)
        RecordingWriterOpenCoordinator.shared.cancel(session: session)

        if let pendingStart,
           captureRequestMatches(
               activeSession: pendingStart.context.session,
               activeURL: pendingStart.context.url,
               expectedSession: session,
               expectedURL: expectedURL
           ) {
            _ = pendingStart.context.disposition.keepInBackground()
            _ = detachPendingStart(
                matching: pendingStart.context.id,
                decision: .supersedeTechnically,
                cancelNativeStart: true
            )
            return
        }

        guard engine != nil, let context = activeContext,
              captureRequestMatches(
                  activeSession: context.session,
                  activeURL: context.url,
                  expectedSession: session,
                  expectedURL: expectedURL
              ) else {
            return
        }

        // Technical recovery owns every late path unless Escape already won.
        _ = context.disposition.keepInBackground()
        wakeFirstFrameWaiters(arrived: false)
        context.pcm.closeAdmission()
        context.conversionSequencer.cancelPending()
        self.engine = nil
        self.converter = nil
        activeContext = nil
        legacyBufferedSamples = nil
        context.shutdownLease.schedule()

        // A healthy admitted callback gets a very short grace period. A
        // permanent converter wedge is then fenced and the already committed
        // prefix is snapshotted, so technical containment itself has a hard
        // callback bound and cannot exhaust every recovery lease.
        let frozen = await context.pcm.recoverAfterCancelledFreeze()
        let pipeline = context.diskAttachment.takePipeline()
        let recording = finalizeRecordingContext(
            context,
            pipeline: pipeline,
            frozen: frozen,
            sampleRate: sampleRate
        )
        // Storage milestones are also detached from this lifecycle call. The
        // exact recovery lease remains owned until preservation completes.
        scheduleTechnicalRecordingPreservation(
            recording,
            lease: context.freezeRecoveryLease
        )
    }

    public func abortRecording() async {
        await abortActiveRecording(expectedSession: nil, expectedURL: nil)
    }

    public func abortRecording(expectedURL: URL?) async {
        await abortActiveRecording(expectedSession: nil, expectedURL: expectedURL)
    }

    /// Session identity is mandatory on the production path. A nil URL while
    /// the start call is still preparing is scoped to this session, not a
    /// wildcard capable of stopping whichever recording becomes active next.
    public func abortRecording(session: DictationSessionID, expectedURL: URL?) async {
        await abortActiveRecording(expectedSession: session, expectedURL: expectedURL)
    }

    private func abortActiveRecording(
        expectedSession: DictationSessionID?,
        expectedURL: URL?
    ) async {
        if let expectedSession {
            // This also covers abort-before-start: actor mailbox order may let
            // cancel arrive first, and the later start must not resurrect it.
            sessionTombstones.recordCancellation(expectedSession)
            RecordingWriterOpenCoordinator.shared.cancel(session: expectedSession)
        }
        if let pendingStart {
            guard captureRequestMatches(
                activeSession: pendingStart.context.session,
                activeURL: pendingStart.context.url,
                expectedSession: expectedSession,
                expectedURL: expectedURL
            ) else {
                if let expectedURL, expectedURL != pendingStart.context.url {
                    RecordingFileDisposer.shared.submit(expectedURL)
                }
                return
            }
            _ = pendingStart.context.disposition.requestDelete()
            _ = detachPendingStart(
                matching: pendingStart.context.id,
                decision: .supersedeDestructively,
                cancelNativeStart: true
            )
            return
        }
        if let activeContext,
           !captureRequestMatches(
               activeSession: activeContext.session,
               activeURL: activeContext.url,
               expectedSession: expectedSession,
               expectedURL: expectedURL
           ) {
            // The requested session has already frozen (or a newer one owns
            // the microphone). Removing its known path is safe; touching the
            // active engine would cancel somebody else's dictation.
            if let expectedURL, expectedURL != activeContext.url {
                RecordingFileDisposer.shared.submit(expectedURL)
            }
            return
        }
        if activeContext == nil {
            if let expectedURL { RecordingFileDisposer.shared.submit(expectedURL) }
            return
        }

        wakeFirstFrameWaiters(arrived: false)
        let context = activeContext
        context?.pcm.closeAdmission()
        context?.conversionSequencer.cancelPending()
        activeContext = nil
        engine = nil
        converter = nil
        context?.pcm.discard()
        context?.freezeRecoveryLease.release()
        legacyBufferedSamples = nil

        if let pipeline = context?.diskAttachment.takePipeline() {
            pipeline.sink.cancel()
            abandonRecordingWriter(
                pipeline.writer,
                managedWriter: pipeline.managedWriter,
                deleteURL: pipeline.writer.fileURL
            )
        }
        context?.shutdownLease.schedule()
    }

    /// Convert the incoming frame to 16 kHz mono.
    nonisolated static func extractSamples(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        target: AVAudioFormat
    ) throws -> [Float] {
        guard let converter else {
            guard let channel = buffer.floatChannelData?[0] else {
                throw AudioCaptureError.unsupportedAudioFormat("the microphone didn't provide Float32 PCM")
            }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioCaptureError.unsupportedAudioFormat("couldn't create a 16 kHz mono buffer")
        }

        // Boxes explain to the compiler what is factually true: closure
        // executed synchronously here, and not in another thread.
        let supplied = UncheckedBox(false)
        let input = UncheckedBox(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .noDataNow
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return input.value
        }

        if let error {
            throw AudioCaptureError.unsupportedAudioFormat(error.localizedDescription)
        }
        guard status != .error else {
            throw AudioCaptureError.unsupportedAudioFormat("the converter rejected an audio frame")
        }
        guard let channel = output.floatChannelData?[0] else {
            throw AudioCaptureError.unsupportedAudioFormat("the converter didn't return Float32 PCM")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Pure seam to check critical fork: `nil` is only allowed
    /// when no conversion is really needed.
    nonisolated static func converter(
        from source: AVAudioFormat,
        to target: AVAudioFormat,
        factory: ConverterFactory
    ) throws -> AVAudioConverter? {
        guard !formatsMatch(source, target) else { return nil }
        guard let converter = factory(source, target) else {
            throw AudioCaptureError.unsupportedAudioFormat(
                "couldn't convert \(Int(source.sampleRate)) Hz / \(source.channelCount) ch to 16 kHz mono"
            )
        }
        return converter
    }

    /// Rate/channel equality alone is not a safe zero-copy fast path. Int16,
    /// interleaved Float32, and a different channel layout all require an
    /// `AVAudioConverter` before `floatChannelData[0]` can be read correctly.
    nonisolated static func formatsMatch(
        _ source: AVAudioFormat,
        _ target: AVAudioFormat
    ) -> Bool {
        guard source.sampleRate == target.sampleRate,
              source.channelCount == target.channelCount,
              source.commonFormat == target.commonFormat,
              source.isInterleaved == target.isInterleaved else {
            return false
        }
        switch (source.channelLayout, target.channelLayout) {
        case (nil, nil):
            return true
        case let (sourceLayout?, targetLayout?):
            return sourceLayout.isEqual(targetLayout)
        default:
            return false
        }
    }
}

import Foundation

public enum ASRWorkerPrefixSessionLifecycle: Equatable, Sendable {
    case collecting
    case stopping
    case cancelled
}

public enum ASRWorkerPrefixSessionStateError: Error, Equatable, Sendable {
    case sessionMismatch
    case workerGenerationMismatch
    case configurationMismatch
    case invalidSampleRate
    case invalidSampleCount
    case invalidPayload(expectedBytes: Int, actualBytes: Int)
    case nonContiguousSegment(expectedOffset: Int, actualOffset: Int)
    case sampleLimitExceeded
    case segmentLimitExceeded
    case noLongerCollecting
    case notStopping
    case duplicateClosedWindow(Int)
    case invalidPlanningWatermark
}

/// Pure worker-side ownership ledger for one incremental recording.
///
/// Payload bytes are retained as immutable `Data` segments. No missing range
/// is synthesized, and no overlap/retry is silently accepted. A production
/// worker can therefore materialize the final Float32 array exactly once at
/// foreground stop while keeping capture uploads incremental.
public struct ASRWorkerPrefixSessionState: Sendable {
    public let session: ASRWorkerPrefixSession
    public let workerGeneration: UInt64
    public let sampleRate: Int
    public private(set) var lifecycle: ASRWorkerPrefixSessionLifecycle = .collecting
    public private(set) var contiguousSampleCount = 0
    public private(set) var cachedClosedWindowIndices: Set<Int> = []

    private var segments: [Data] = []

    public init(
        _ request: ASRWorkerBeginPrefixSession,
        workerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) throws {
        guard request.sampleRate == ASRWorkerProtocol.sampleRate else {
            throw ASRWorkerPrefixSessionStateError.invalidSampleRate
        }
        guard request.session.configuration == currentConfiguration else {
            throw ASRWorkerPrefixSessionStateError.configurationMismatch
        }
        session = request.session
        self.workerGeneration = workerGeneration
        sampleRate = request.sampleRate
    }

    public mutating func append(
        _ request: ASRWorkerAppendPrefixSamples,
        payload: Data,
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) throws {
        try validateFence(
            request.session,
            currentWorkerGeneration: currentWorkerGeneration,
            currentConfiguration: currentConfiguration
        )
        guard lifecycle == .collecting else {
            throw ASRWorkerPrefixSessionStateError.noLongerCollecting
        }
        guard request.sampleCount > 0,
            request.sampleCount <= ASRWorkerProtocol.maximumPrefixAppendSamples,
            request.sampleCount <= Int.max / MemoryLayout<Float>.size
        else {
            throw ASRWorkerPrefixSessionStateError.invalidSampleCount
        }
        guard request.offsetSamples == contiguousSampleCount else {
            throw ASRWorkerPrefixSessionStateError.nonContiguousSegment(
                expectedOffset: contiguousSampleCount,
                actualOffset: request.offsetSamples
            )
        }
        let expectedBytes = request.sampleCount * MemoryLayout<Float>.size
        guard payload.count == expectedBytes else {
            throw ASRWorkerPrefixSessionStateError.invalidPayload(
                expectedBytes: expectedBytes,
                actualBytes: payload.count
            )
        }
        guard contiguousSampleCount <= ASRWorkerProtocol.maximumSamples - request.sampleCount else {
            throw ASRWorkerPrefixSessionStateError.sampleLimitExceeded
        }
        guard segments.count < ASRWorkerProtocol.maximumPrefixSegments else {
            throw ASRWorkerPrefixSessionStateError.segmentLimitExceeded
        }

        segments.append(payload)
        contiguousSampleCount += request.sampleCount
    }

    public mutating func markClosedWindowCached(
        index: Int,
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) throws {
        try validateFence(
            session,
            currentWorkerGeneration: currentWorkerGeneration,
            currentConfiguration: currentConfiguration
        )
        guard lifecycle != .cancelled, index >= 0 else {
            throw ASRWorkerPrefixSessionStateError.noLongerCollecting
        }
        guard cachedClosedWindowIndices.insert(index).inserted else {
            throw ASRWorkerPrefixSessionStateError.duplicateClosedWindow(index)
        }
    }

    public mutating func stop(
        _ request: ASRWorkerTranscribePrefixSession,
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) throws {
        try validateFence(
            request.session,
            currentWorkerGeneration: currentWorkerGeneration,
            currentConfiguration: currentConfiguration
        )
        guard lifecycle == .collecting else {
            throw ASRWorkerPrefixSessionStateError.noLongerCollecting
        }
        guard request.sampleRate == sampleRate else {
            throw ASRWorkerPrefixSessionStateError.invalidSampleRate
        }
        guard request.sampleCount == contiguousSampleCount else {
            throw ASRWorkerPrefixSessionStateError.nonContiguousSegment(
                expectedOffset: contiguousSampleCount,
                actualOffset: request.sampleCount
            )
        }
        lifecycle = .stopping
    }

    public mutating func cancel(
        _ request: ASRWorkerCancelPrefixSession,
        currentWorkerGeneration: UInt64
    ) throws {
        try validateSessionAndGeneration(
            request.session,
            currentWorkerGeneration: currentWorkerGeneration
        )
        retireStorage()
    }

    /// Configuration changes proactively retire old sessions without asking a
    /// stale request to match the newly active configuration. Exact session
    /// cancellation remains separately available for user stop/delete.
    @discardableResult
    public mutating func retireIfConfigurationChanged(
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) -> Bool {
        guard currentWorkerGeneration == workerGeneration,
            currentConfiguration != session.configuration
        else {
            return false
        }
        retireStorage()
        return true
    }

    private mutating func retireStorage() {
        lifecycle = .cancelled
        segments.removeAll(keepingCapacity: false)
        cachedClosedWindowIndices.removeAll(keepingCapacity: false)
        contiguousSampleCount = 0
    }

    /// Materializes the exact native Float32 bit patterns only at an explicit
    /// planner/final boundary. Immutable segment payloads remain the source of
    /// truth; no gap is synthesized and no probabilistic digest is accepted.
    public func materializedSamples(
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration,
        requireStopping: Bool = false
    ) throws -> [Float] {
        try validateFence(
            session,
            currentWorkerGeneration: currentWorkerGeneration,
            currentConfiguration: currentConfiguration
        )
        if requireStopping, lifecycle != .stopping {
            throw ASRWorkerPrefixSessionStateError.notStopping
        }
        guard lifecycle != .cancelled else {
            throw ASRWorkerPrefixSessionStateError.noLongerCollecting
        }

        var samples = [Float](repeating: 0, count: contiguousSampleCount)
        var byteOffset = 0
        samples.withUnsafeMutableBytes { destination in
            for segment in segments {
                segment.withUnsafeBytes { source in
                    guard let destinationBase = destination.baseAddress,
                        let sourceBase = source.baseAddress
                    else { return }
                    destinationBase.advanced(by: byteOffset).copyMemory(
                        from: sourceBase,
                        byteCount: segment.count
                    )
                }
                byteOffset += segment.count
            }
        }
        return samples
    }

    public var retainedSegmentCount: Int { segments.count }

    /// Returns COW values only after an exact stop fence. This does not flatten
    /// or copy the PCM bytes; the inference adapter owns that one final copy.
    public func stoppedSegments(
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) throws -> [Data] {
        try validateFence(
            session,
            currentWorkerGeneration: currentWorkerGeneration,
            currentConfiguration: currentConfiguration
        )
        guard lifecycle == .stopping else {
            throw ASRWorkerPrefixSessionStateError.notStopping
        }
        return segments
    }

    private func validateFence(
        _ requestSession: ASRWorkerPrefixSession,
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) throws {
        guard requestSession == session else {
            throw ASRWorkerPrefixSessionStateError.sessionMismatch
        }
        guard currentWorkerGeneration == workerGeneration else {
            throw ASRWorkerPrefixSessionStateError.workerGenerationMismatch
        }
        guard currentConfiguration == session.configuration else {
            throw ASRWorkerPrefixSessionStateError.configurationMismatch
        }
    }

    private func validateSessionAndGeneration(
        _ requestSession: ASRWorkerPrefixSession,
        currentWorkerGeneration: UInt64
    ) throws {
        guard requestSession == session else {
            throw ASRWorkerPrefixSessionStateError.sessionMismatch
        }
        guard currentWorkerGeneration == workerGeneration else {
            throw ASRWorkerPrefixSessionStateError.workerGenerationMismatch
        }
    }
}

/// Minimal descriptor understood by the worker watermark ledger. The opaque
/// recognizer plan itself remains owned by LocalASR/FluidAudio.
public struct ASRWorkerClosedWindowPlanDescriptor: Equatable, Sendable {
    public let index: Int
    public let earliestSafePrefixSampleCount: Int

    public init(index: Int, earliestSafePrefixSampleCount: Int) {
        self.index = index
        self.earliestSafePrefixSampleCount = earliestSafePrefixSampleCount
    }
}

/// Pure O(number-of-windows) planning gate. Thousands of capture callbacks do
/// not rescan a growing prefix: the recognizer is consulted only when its
/// conservative next exact watermark is crossed, and each index is emitted
/// at most once.
public struct ASRWorkerClosedWindowPlanningState: Sendable {
    public private(set) var nextPlanningWatermark =
        ASRWorkerProtocol.firstClosedWindowPlanningSampleCount
    public private(set) var plannerInvocationCount = 0
    public private(set) var enqueuedWindowIndices: Set<Int> = []
    public private(set) var isExhausted = false

    public init() {}

    public func shouldPlan(at contiguousSampleCount: Int) -> Bool {
        !isExhausted && contiguousSampleCount >= nextPlanningWatermark
    }

    /// Returns only newly exposed descriptors. The next watermark must move
    /// strictly beyond the prefix that was just scanned, otherwise the caller
    /// could spin and grow tasks without receiving more PCM.
    public mutating func recordPlannerResult(
        plans: [ASRWorkerClosedWindowPlanDescriptor],
        nextPlanningSampleCount: Int?,
        observedSampleCount: Int
    ) throws -> [ASRWorkerClosedWindowPlanDescriptor] {
        guard shouldPlan(at: observedSampleCount) else {
            throw ASRWorkerPrefixSessionStateError.invalidPlanningWatermark
        }
        plannerInvocationCount += 1

        let ordered = plans.sorted { lhs, rhs in
            lhs.index == rhs.index
                ? lhs.earliestSafePrefixSampleCount < rhs.earliestSafePrefixSampleCount
                : lhs.index < rhs.index
        }
        var newlyExposed: [ASRWorkerClosedWindowPlanDescriptor] = []
        for plan in ordered {
            guard plan.index >= 0,
                plan.earliestSafePrefixSampleCount > 0,
                plan.earliestSafePrefixSampleCount <= observedSampleCount
            else {
                throw ASRWorkerPrefixSessionStateError.invalidPlanningWatermark
            }
            if enqueuedWindowIndices.insert(plan.index).inserted {
                newlyExposed.append(plan)
            }
        }

        if let nextPlanningSampleCount {
            guard nextPlanningSampleCount > observedSampleCount else {
                throw ASRWorkerPrefixSessionStateError.invalidPlanningWatermark
            }
            nextPlanningWatermark = nextPlanningSampleCount
        } else {
            isExhausted = true
            nextPlanningWatermark = Int.max
        }
        return newlyExposed
    }
}

public struct ASRWorkerWorkFence: Equatable, Hashable, Sendable {
    public let workerGeneration: UInt64
    public let configuration: ASRWorkerRecognitionConfiguration

    public init(workerGeneration: UInt64, configuration: ASRWorkerRecognitionConfiguration) {
        self.workerGeneration = workerGeneration
        self.configuration = configuration
    }
}

public enum ASRWorkerScheduledWorkKind: Equatable, Hashable, Sendable {
    case speculativeClosedWindow(sessionID: UUID, index: Int)
    case foregroundTranscription(sessionID: UUID, requestID: UInt64)
    case foregroundConfiguration(requestID: UInt64)

    var sessionID: UUID? {
        switch self {
        case .speculativeClosedWindow(let sessionID, _),
            .foregroundTranscription(let sessionID, _):
            sessionID
        case .foregroundConfiguration:
            nil
        }
    }

    var isForeground: Bool {
        switch self {
        case .speculativeClosedWindow:
            false
        case .foregroundTranscription, .foregroundConfiguration:
            true
        }
    }
}

public struct ASRWorkerScheduledWork: Equatable, Hashable, Sendable {
    public let sequence: UInt64
    public let kind: ASRWorkerScheduledWorkKind
    public let fence: ASRWorkerWorkFence

    public init(sequence: UInt64, kind: ASRWorkerScheduledWorkKind, fence: ASRWorkerWorkFence) {
        self.sequence = sequence
        self.kind = kind
        self.fence = fence
    }
}

public struct ASRWorkerStoppedSpeculation: Equatable, Sendable {
    public let removedQueuedWork: [ASRWorkerScheduledWork]
    public let hasActiveNonPreemptibleWork: Bool
}

/// Pure single-CoreML-lane scheduler. Foreground work overtakes queued
/// speculation, but an already executing model call is deliberately not
/// described as preemptible. Stop removes queued windows and lets an active,
/// provably closed window finish before the foreground final call begins.
public struct ASRWorkerSingleLaneScheduler: Sendable {
    public private(set) var active: ASRWorkerScheduledWork?
    private var foreground: [ASRWorkerScheduledWork] = []
    private var speculative: [ASRWorkerScheduledWork] = []
    /// At most the one active non-preemptible call needs a tombstone. Queued
    /// ownership is returned immediately to the caller on cancellation.
    private var cancelledActiveSequence: UInt64?

    public init() {}

    @discardableResult
    public mutating func enqueue(_ work: ASRWorkerScheduledWork) -> Bool {
        guard active?.sequence != work.sequence,
            !foreground.contains(where: { $0.sequence == work.sequence }),
            !speculative.contains(where: { $0.sequence == work.sequence })
        else {
            return false
        }
        if work.kind.isForeground {
            foreground.append(work)
        } else {
            speculative.append(work)
        }
        return true
    }

    public mutating func beginNext() -> ASRWorkerScheduledWork? {
        guard active == nil else { return nil }
        let next: ASRWorkerScheduledWork?
        if !foreground.isEmpty {
            next = foreground.removeFirst()
        } else if !speculative.isEmpty {
            next = speculative.removeFirst()
        } else {
            next = nil
        }
        active = next
        return next
    }

    /// Returns queued ownership immediately and reports whether one
    /// non-preemptible speculative call is already active.
    @discardableResult
    public mutating func stopSpeculation(for sessionID: UUID) -> ASRWorkerStoppedSpeculation {
        let removed = speculative.filter { $0.kind.sessionID == sessionID }
        speculative.removeAll { $0.kind.sessionID == sessionID }
        guard let active else {
            return ASRWorkerStoppedSpeculation(
                removedQueuedWork: removed,
                hasActiveNonPreemptibleWork: false
            )
        }
        if case .speculativeClosedWindow(let activeSessionID, _) = active.kind {
            return ASRWorkerStoppedSpeculation(
                removedQueuedWork: removed,
                hasActiveNonPreemptibleWork: activeSessionID == sessionID
            )
        }
        return ASRWorkerStoppedSpeculation(
            removedQueuedWork: removed,
            hasActiveNonPreemptibleWork: false
        )
    }

    @discardableResult
    public mutating func cancel(sessionID: UUID) -> [ASRWorkerScheduledWork] {
        let removed =
            foreground.filter { $0.kind.sessionID == sessionID }
            + speculative.filter { $0.kind.sessionID == sessionID }
        foreground.removeAll { $0.kind.sessionID == sessionID }
        speculative.removeAll { $0.kind.sessionID == sessionID }
        if active?.kind.sessionID == sessionID {
            cancelledActiveSequence = active?.sequence
        }
        return removed
    }

    @discardableResult
    public mutating func invalidateQueuedWork(
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) -> [ASRWorkerScheduledWork] {
        let isStale: (ASRWorkerScheduledWork) -> Bool = {
            $0.fence.workerGeneration != currentWorkerGeneration
                || $0.fence.configuration != currentConfiguration
        }
        let removed = foreground.filter(isStale) + speculative.filter(isStale)
        foreground.removeAll(where: isStale)
        speculative.removeAll(where: isStale)
        return removed
    }

    /// Releases the lane and says whether the result may enter worker state.
    /// A cancelled session or stale generation/configuration always discards
    /// the result, including a late non-preemptible CoreML completion.
    public mutating func complete(
        _ work: ASRWorkerScheduledWork,
        currentWorkerGeneration: UInt64,
        currentConfiguration: ASRWorkerRecognitionConfiguration
    ) -> Bool {
        guard active == work else { return false }
        active = nil
        let wasCancelled = cancelledActiveSequence == work.sequence
        if wasCancelled { cancelledActiveSequence = nil }
        return work.fence.workerGeneration == currentWorkerGeneration
            && work.fence.configuration == currentConfiguration
            && !wasCancelled
    }

    public var queuedForegroundCount: Int { foreground.count }
    public var queuedSpeculativeCount: Int { speculative.count }
}

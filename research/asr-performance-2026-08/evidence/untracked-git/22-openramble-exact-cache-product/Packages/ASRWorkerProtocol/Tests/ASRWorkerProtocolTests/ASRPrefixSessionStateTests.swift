import Foundation
import Testing

@testable import ASRWorkerProtocol

@Suite("ASR prefix session state")
struct ASRPrefixSessionStateTests {
    @Test("v2 metadata round-trips without changing existing message kinds")
    func protocolRoundTrip() throws {
        #expect(ASRWorkerProtocol.version == 2)
        #expect(ASRWireKind.shutdown.rawValue == 11)
        #expect(ASRWireKind.beginPrefixSession.rawValue == 12)
        #expect(ASRWireKind.prefixSessionProgress.rawValue == 16)

        let fixture = makeFixture()
        let request = ASRWorkerAppendPrefixSamples(
            session: fixture.session,
            offsetSamples: 128,
            sampleCount: 64
        )
        let encoded = try ASRWorkerJSON.encode(request)
        #expect(
            try ASRWorkerJSON.decode(ASRWorkerAppendPrefixSamples.self, from: encoded) == request)

        let progress = ASRWorkerPrefixSessionProgress(
            sessionID: fixture.session.id,
            captureStorageID: fixture.session.captureStorageID,
            contiguousSampleCount: 192,
            cachedClosedWindowCount: 1
        )
        let progressData = try ASRWorkerJSON.encode(progress)
        #expect(
            try ASRWorkerJSON.decode(ASRWorkerPrefixSessionProgress.self, from: progressData)
                == progress
        )
    }

    @Test("segments remain bit-exact and must be contiguous")
    func contiguousSegments() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        let first = floatsData([
            Float(bitPattern: 0x8000_0000),
            Float(bitPattern: 0x7fc0_0042),
        ])
        let second = floatsData([0.25, -0.5])

        try state.append(
            ASRWorkerAppendPrefixSamples(
                session: fixture.session,
                offsetSamples: 0,
                sampleCount: 2
            ),
            payload: first,
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        #expect(
            throws: ASRWorkerPrefixSessionStateError.nonContiguousSegment(
                expectedOffset: 2,
                actualOffset: 3
            )
        ) {
            try state.append(
                ASRWorkerAppendPrefixSamples(
                    session: fixture.session,
                    offsetSamples: 3,
                    sampleCount: 2
                ),
                payload: second,
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
        #expect(state.contiguousSampleCount == 2)

        try state.append(
            ASRWorkerAppendPrefixSamples(
                session: fixture.session,
                offsetSamples: 2,
                sampleCount: 2
            ),
            payload: second,
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        try state.stop(
            ASRWorkerTranscribePrefixSession(
                session: fixture.session,
                sampleRate: ASRWorkerProtocol.sampleRate,
                sampleCount: 4
            ),
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )

        let segments = try state.stoppedSegments(
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        #expect(segments == [first, second])
        #expect(segments.reduce(into: Data()) { $0.append($1) } == first + second)
        let materialized = try state.materializedSamples(
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration,
            requireStopping: true
        )
        #expect(materialized.map(\.bitPattern) == [0x8000_0000, 0x7fc0_0042, 0x3e80_0000, 0xbf00_0000])
        #expect(state.retainedSegmentCount == 2)
    }

    @Test("ten thousand append watermarks invoke the planner only once per closed-window interval")
    func planningWatermarksAreBounded() throws {
        var planning = ASRWorkerClosedWindowPlanningState()
        var nextWindowIndex = 0
        let callbackStep = ASRWorkerProtocol.maximumSamples / 10_000
        let planningStep = 207_360 // shipping v3/no-mel 14.96s window minus 2s overlap

        for callback in 1...10_000 {
            let observed = min(ASRWorkerProtocol.maximumSamples, callback * callbackStep)
            guard planning.shouldPlan(at: observed) else { continue }
            let descriptor = ASRWorkerClosedWindowPlanDescriptor(
                index: nextWindowIndex,
                earliestSafePrefixSampleCount: observed
            )
            let newlyExposed = try planning.recordPlannerResult(
                plans: [descriptor],
                nextPlanningSampleCount: observed + planningStep,
                observedSampleCount: observed
            )
            #expect(newlyExposed == [descriptor])
            nextWindowIndex += 1
        }

        #expect(planning.plannerInvocationCount == nextWindowIndex)
        #expect(planning.plannerInvocationCount < 25)
        #expect(planning.enqueuedWindowIndices.count == planning.plannerInvocationCount)
    }

    @Test("planner watermarks must advance and duplicate indices are emitted once")
    func planningWatermarkValidation() throws {
        var planning = ASRWorkerClosedWindowPlanningState()
        let observed = ASRWorkerProtocol.firstClosedWindowPlanningSampleCount
        let descriptor = ASRWorkerClosedWindowPlanDescriptor(
            index: 0,
            earliestSafePrefixSampleCount: observed
        )
        #expect(throws: ASRWorkerPrefixSessionStateError.invalidPlanningWatermark) {
            _ = try planning.recordPlannerResult(
                plans: [descriptor],
                nextPlanningSampleCount: observed,
                observedSampleCount: observed
            )
        }

        var valid = ASRWorkerClosedWindowPlanningState()
        #expect(
            try valid.recordPlannerResult(
                plans: [descriptor],
                nextPlanningSampleCount: observed + 1,
                observedSampleCount: observed
            ) == [descriptor]
        )
        #expect(
            try valid.recordPlannerResult(
                plans: [descriptor],
                nextPlanningSampleCount: observed + 3,
                observedSampleCount: observed + 2
            ).isEmpty
        )
    }

    @Test("payload mismatch is rejected without padding or advancing")
    func payloadMismatch() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        let request = ASRWorkerAppendPrefixSamples(
            session: fixture.session,
            offsetSamples: 0,
            sampleCount: 2
        )

        #expect(
            throws: ASRWorkerPrefixSessionStateError.invalidPayload(
                expectedBytes: 8,
                actualBytes: 4
            )
        ) {
            try state.append(
                request,
                payload: floatsData([1]),
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
        #expect(state.contiguousSampleCount == 0)

        #expect(throws: ASRWorkerPrefixSessionStateError.invalidSampleCount) {
            try state.append(
                ASRWorkerAppendPrefixSamples(
                    session: fixture.session,
                    offsetSamples: 0,
                    sampleCount: ASRWorkerProtocol.maximumPrefixAppendSamples + 1
                ),
                payload: Data(),
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
    }

    @Test("stop fences late appends and mismatched final watermarks")
    func stopAndLateAppend() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        try appendOne(to: &state, fixture: fixture)

        #expect(
            throws: ASRWorkerPrefixSessionStateError.nonContiguousSegment(
                expectedOffset: 1,
                actualOffset: 2
            )
        ) {
            try state.stop(
                ASRWorkerTranscribePrefixSession(
                    session: fixture.session,
                    sampleRate: ASRWorkerProtocol.sampleRate,
                    sampleCount: 2
                ),
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
        try state.stop(
            ASRWorkerTranscribePrefixSession(
                session: fixture.session,
                sampleRate: ASRWorkerProtocol.sampleRate,
                sampleCount: 1
            ),
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        #expect(throws: ASRWorkerPrefixSessionStateError.noLongerCollecting) {
            try state.append(
                ASRWorkerAppendPrefixSamples(
                    session: fixture.session,
                    offsetSamples: 1,
                    sampleCount: 1
                ),
                payload: floatsData([2]),
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
    }

    @Test("stop flushes an authoritative tail before sealing the session")
    func stopFlushesTailSerially() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        try appendOne(to: &state, fixture: fixture)

        #expect(
            throws: ASRWorkerPrefixSessionStateError.nonContiguousSegment(
                expectedOffset: 1,
                actualOffset: 3
            )
        ) {
            try state.stop(
                ASRWorkerTranscribePrefixSession(
                    session: fixture.session,
                    sampleRate: ASRWorkerProtocol.sampleRate,
                    sampleCount: 3
                ),
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
        #expect(state.lifecycle == .collecting)

        // The supervisor must finish the current append and send this exact
        // unsent range; cancelling that upload would kill today's worker.
        try state.append(
            ASRWorkerAppendPrefixSamples(
                session: fixture.session,
                offsetSamples: 1,
                sampleCount: 2
            ),
            payload: floatsData([2, 3]),
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        try state.stop(
            ASRWorkerTranscribePrefixSession(
                session: fixture.session,
                sampleRate: ASRWorkerProtocol.sampleRate,
                sampleCount: 3
            ),
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        #expect(state.lifecycle == .stopping)
    }

    @Test("generation, model, vocabulary, language, and storage identity are exact fences")
    func exactFences() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        let request = ASRWorkerAppendPrefixSamples(
            session: fixture.session,
            offsetSamples: 0,
            sampleCount: 1
        )

        #expect(throws: ASRWorkerPrefixSessionStateError.workerGenerationMismatch) {
            try state.append(
                request,
                payload: floatsData([1]),
                currentWorkerGeneration: fixture.generation + 1,
                currentConfiguration: fixture.configuration
            )
        }
        let changedConfigurations = [
            ASRWorkerRecognitionConfiguration(
                epoch: fixture.configuration.epoch + 1,
                modelIdentifier: fixture.configuration.modelIdentifier,
                vocabularyRevision: fixture.configuration.vocabularyRevision
            ),
            ASRWorkerRecognitionConfiguration(
                epoch: fixture.configuration.epoch,
                modelIdentifier: "parakeet-v3:sha256:different",
                vocabularyRevision: fixture.configuration.vocabularyRevision
            ),
            ASRWorkerRecognitionConfiguration(
                epoch: fixture.configuration.epoch,
                modelIdentifier: fixture.configuration.modelIdentifier,
                vocabularyRevision: 99
            ),
        ]
        for changedConfiguration in changedConfigurations {
            #expect(throws: ASRWorkerPrefixSessionStateError.configurationMismatch) {
                try state.append(
                    request,
                    payload: floatsData([1]),
                    currentWorkerGeneration: fixture.generation,
                    currentConfiguration: changedConfiguration
                )
            }
        }

        let differentSession = ASRWorkerPrefixSession(
            id: fixture.session.id,
            captureStorageID: UUID(),
            languageHint: "ru",
            configuration: fixture.configuration
        )
        #expect(throws: ASRWorkerPrefixSessionStateError.sessionMismatch) {
            try state.append(
                ASRWorkerAppendPrefixSamples(
                    session: differentSession,
                    offsetSamples: 0,
                    sampleCount: 1
                ),
                payload: floatsData([1]),
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
    }

    @Test("cancel releases stale-configuration storage and config change proactively retires sessions")
    func cancellationIgnoresCurrentConfiguration() throws {
        let fixture = makeFixture()
        let changedConfiguration = ASRWorkerRecognitionConfiguration(
            epoch: fixture.configuration.epoch + 1,
            modelIdentifier: "replacement-model",
            vocabularyRevision: nil
        )

        var explicitlyCancelled = try makeState(fixture)
        try appendOne(to: &explicitlyCancelled, fixture: fixture)
        try explicitlyCancelled.markClosedWindowCached(
            index: 0,
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        try explicitlyCancelled.cancel(
            ASRWorkerCancelPrefixSession(session: fixture.session),
            currentWorkerGeneration: fixture.generation
        )
        #expect(explicitlyCancelled.lifecycle == .cancelled)
        #expect(explicitlyCancelled.contiguousSampleCount == 0)
        #expect(explicitlyCancelled.cachedClosedWindowIndices.isEmpty)

        var proactivelyRetired = try makeState(fixture)
        try appendOne(to: &proactivelyRetired, fixture: fixture)
        let didRetire = proactivelyRetired.retireIfConfigurationChanged(
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: changedConfiguration
        )
        #expect(didRetire)
        #expect(proactivelyRetired.lifecycle == .cancelled)
        #expect(proactivelyRetired.contiguousSampleCount == 0)
    }

    @Test("hostile tiny segments hit a bounded ledger instead of growing to 4.8 million entries")
    func segmentCountIsBounded() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        let payload = floatsData([1])
        for offset in 0..<ASRWorkerProtocol.maximumPrefixSegments {
            try state.append(
                ASRWorkerAppendPrefixSamples(
                    session: fixture.session,
                    offsetSamples: offset,
                    sampleCount: 1
                ),
                payload: payload,
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
        #expect(throws: ASRWorkerPrefixSessionStateError.segmentLimitExceeded) {
            try state.append(
                ASRWorkerAppendPrefixSamples(
                    session: fixture.session,
                    offsetSamples: ASRWorkerProtocol.maximumPrefixSegments,
                    sampleCount: 1
                ),
                payload: payload,
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
        #expect(state.contiguousSampleCount == ASRWorkerProtocol.maximumPrefixSegments)
    }

    @Test("duplicate closed-window indices fail closed")
    func duplicateClosedWindow() throws {
        let fixture = makeFixture()
        var state = try makeState(fixture)
        try state.markClosedWindowCached(
            index: 3,
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        #expect(throws: ASRWorkerPrefixSessionStateError.duplicateClosedWindow(3)) {
            try state.markClosedWindowCached(
                index: 3,
                currentWorkerGeneration: fixture.generation,
                currentConfiguration: fixture.configuration
            )
        }
    }

    @Test("foreground overtakes queued speculation without claiming active preemption")
    func foregroundPriorityAndStop() throws {
        let fixture = makeFixture()
        let fence = ASRWorkerWorkFence(
            workerGeneration: fixture.generation,
            configuration: fixture.configuration
        )
        let activeSpeculation = ASRWorkerScheduledWork(
            sequence: 1,
            kind: .speculativeClosedWindow(sessionID: fixture.session.id, index: 0),
            fence: fence
        )
        let queuedSpeculation = ASRWorkerScheduledWork(
            sequence: 2,
            kind: .speculativeClosedWindow(sessionID: fixture.session.id, index: 1),
            fence: fence
        )
        let foreground = ASRWorkerScheduledWork(
            sequence: 3,
            kind: .foregroundTranscription(sessionID: fixture.session.id, requestID: 40),
            fence: fence
        )

        var scheduler = ASRWorkerSingleLaneScheduler()
        let didEnqueueActive = scheduler.enqueue(activeSpeculation)
        let firstWork = scheduler.beginNext()
        let didEnqueueSpeculation = scheduler.enqueue(queuedSpeculation)
        let didEnqueueForeground = scheduler.enqueue(foreground)
        let stopped = scheduler.stopSpeculation(for: fixture.session.id)
        #expect(didEnqueueActive)
        #expect(firstWork == activeSpeculation)
        #expect(didEnqueueSpeculation)
        #expect(didEnqueueForeground)
        #expect(stopped.hasActiveNonPreemptibleWork)
        #expect(stopped.removedQueuedWork == [queuedSpeculation])
        #expect(scheduler.queuedSpeculativeCount == 0)
        #expect(scheduler.active == activeSpeculation)
        let acceptedActiveResult = scheduler.complete(
            activeSpeculation,
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        let nextWork = scheduler.beginNext()
        #expect(acceptedActiveResult)
        #expect(nextWork == foreground)
    }

    @Test("cancel and stale generation/config discard late active results")
    func schedulerCompletionFences() {
        let fixture = makeFixture()
        let fence = ASRWorkerWorkFence(
            workerGeneration: fixture.generation,
            configuration: fixture.configuration
        )
        let work = ASRWorkerScheduledWork(
            sequence: 1,
            kind: .speculativeClosedWindow(sessionID: fixture.session.id, index: 0),
            fence: fence
        )

        var cancelled = ASRWorkerSingleLaneScheduler()
        let didEnqueueCancelled = cancelled.enqueue(work)
        let cancelledActive = cancelled.beginNext()
        let queuedCancelled = ASRWorkerScheduledWork(
            sequence: 2,
            kind: .speculativeClosedWindow(sessionID: fixture.session.id, index: 1),
            fence: fence
        )
        let didEnqueueQueuedCancelled = cancelled.enqueue(queuedCancelled)
        let removed = cancelled.cancel(sessionID: fixture.session.id)
        let acceptedCancelledResult = cancelled.complete(
            work,
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
        #expect(didEnqueueCancelled)
        #expect(didEnqueueQueuedCancelled)
        #expect(cancelledActive == work)
        #expect(removed == [queuedCancelled])
        #expect(!acceptedCancelledResult)
        let replacement = ASRWorkerScheduledWork(
            sequence: 3,
            kind: .speculativeClosedWindow(sessionID: fixture.session.id, index: 2),
            fence: fence
        )
        let acceptedReplacement = cancelled.enqueue(replacement)
        #expect(acceptedReplacement, "active cancellation tombstone must clear exact-on-complete")

        var stale = ASRWorkerSingleLaneScheduler()
        let didEnqueueStale = stale.enqueue(work)
        let staleActive = stale.beginNext()
        let acceptedStaleResult = stale.complete(
            work,
            currentWorkerGeneration: fixture.generation + 1,
            currentConfiguration: fixture.configuration
        )
        #expect(didEnqueueStale)
        #expect(staleActive == work)
        #expect(!acceptedStaleResult)

        var invalidated = ASRWorkerSingleLaneScheduler()
        let didEnqueueInvalidated = invalidated.enqueue(work)
        let nextConfiguration = ASRWorkerRecognitionConfiguration(
            epoch: fixture.configuration.epoch + 1,
            modelIdentifier: fixture.configuration.modelIdentifier,
            vocabularyRevision: fixture.configuration.vocabularyRevision
        )
        let returned = invalidated.invalidateQueuedWork(
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: nextConfiguration
        )
        #expect(didEnqueueInvalidated)
        #expect(returned == [work])
        #expect(invalidated.queuedSpeculativeCount == 0)
    }

    private func makeFixture() -> (
        configuration: ASRWorkerRecognitionConfiguration,
        session: ASRWorkerPrefixSession,
        generation: UInt64
    ) {
        let configuration = ASRWorkerRecognitionConfiguration(
            epoch: 7,
            modelIdentifier: "parakeet-v3:sha256:abc",
            vocabularyRevision: 12
        )
        let session = ASRWorkerPrefixSession(
            id: UUID(),
            captureStorageID: UUID(),
            languageHint: "en",
            configuration: configuration
        )
        return (configuration, session, 4)
    }

    private func makeState(
        _ fixture: (
            configuration: ASRWorkerRecognitionConfiguration,
            session: ASRWorkerPrefixSession,
            generation: UInt64
        )
    ) throws -> ASRWorkerPrefixSessionState {
        try ASRWorkerPrefixSessionState(
            ASRWorkerBeginPrefixSession(
                session: fixture.session,
                sampleRate: ASRWorkerProtocol.sampleRate
            ),
            workerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
    }

    private func appendOne(
        to state: inout ASRWorkerPrefixSessionState,
        fixture: (
            configuration: ASRWorkerRecognitionConfiguration,
            session: ASRWorkerPrefixSession,
            generation: UInt64
        )
    ) throws {
        try state.append(
            ASRWorkerAppendPrefixSamples(
                session: fixture.session,
                offsetSamples: 0,
                sampleCount: 1
            ),
            payload: floatsData([1]),
            currentWorkerGeneration: fixture.generation,
            currentConfiguration: fixture.configuration
        )
    }

    private func floatsData(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

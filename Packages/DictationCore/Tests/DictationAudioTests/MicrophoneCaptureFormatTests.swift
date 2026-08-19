import AVFoundation
import DictationCore
import XCTest
@testable import DictationAudio

final class MicrophoneCaptureFormatTests: XCTestCase {
    private actor OneShotAsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in pending { waiter.resume() }
        }
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func increment() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class LockedSamples: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Float] = []

        func append(_ sample: Float) {
            lock.lock()
            storage.append(sample)
            lock.unlock()
        }

        var values: [Float] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class LockedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        func append(_ url: URL) {
            lock.lock()
            storage.append(url)
            lock.unlock()
        }

        var values: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class BlockingSampleConsumer: @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var received: [[Float]] = []

        func consume(_ samples: [Float]) {
            lock.lock()
            received.append(samples)
            let isFirst = received.count == 1
            lock.unlock()
            if isFirst {
                entered.signal()
                release.wait()
            }
        }

        func waitUntilBlocked() -> Bool {
            entered.wait(timeout: .now() + 1) == .success
        }

        func unblock() { release.signal() }

        var snapshots: [[Float]] {
            lock.lock()
            defer { lock.unlock() }
            return received
        }
    }

    private actor SessionFailureReceiver {
        private var activeID: UUID?
        private var activeURL: URL?
        private var failures = 0

        func activate(id: UUID, url: URL) {
            activeID = id
            activeURL = url
        }

        func report(id: UUID, url: URL) {
            guard isCurrentRecordingSession(
                activeID: activeID,
                activeURL: activeURL,
                reportedID: id,
                reportedURL: url
            ) else { return }
            failures += 1
        }

        var failureCount: Int { failures }
    }

    private actor TokenScopedEventReceiver {
        private var active: DictationSessionID?
        private var accepted: [DictationSessionID] = []

        func activate(_ session: DictationSessionID) {
            active = session
        }

        func report(_ session: DictationSessionID) {
            guard active == session else { return }
            accepted.append(session)
        }

        var acceptedSessions: [DictationSessionID] { accepted }
    }

    private func format(rate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: rate,
                channels: channels,
                interleaved: false
            )
        )
    }

    func testMatchingFormatNeedsNoConverter() throws {
        let target = try format(rate: 16_000, channels: 1)

        let converter = try MicrophoneCapture.converter(
            from: target,
            to: target,
            factory: { _, _ in XCTFail("\u{0424}\u{0430}\u{0431}\u{0440}\u{0438}\u{043A}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0432}\u{044B}\u{0437}\u{044B}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}"); return nil }
        )

        XCTAssertNil(converter)
    }

    func testFailedConverterFor48kStereoIsFatal() throws {
        let source = try format(rate: 48_000, channels: 2)
        let target = try format(rate: 16_000, channels: 1)

        XCTAssertThrowsError(
            try MicrophoneCapture.converter(from: source, to: target, factory: { _, _ in nil })
        ) { error in
            guard case .unsupportedAudioFormat = error as? AudioCaptureError else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} unsupportedAudioFormat, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func test48kStereoGetsARealConverter() throws {
        let source = try format(rate: 48_000, channels: 2)
        let target = try format(rate: 16_000, channels: 1)

        let converter = try MicrophoneCapture.converter(
            from: source,
            to: target,
            factory: { AVAudioConverter(from: $0, to: $1) }
        )

        XCTAssertNotNil(converter)
    }

    func testSameRateMonoInt16StillRequiresConverter() throws {
        let source = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let target = try format(rate: 16_000, channels: 1)
        let factoryCalls = LockedCount()

        let converter = try MicrophoneCapture.converter(
            from: source,
            to: target,
            factory: {
                factoryCalls.increment()
                return AVAudioConverter(from: $0, to: $1)
            }
        )

        XCTAssertNotNil(converter)
        XCTAssertEqual(factoryCalls.value, 1)
    }

    func testSameRateMonoInterleavedFloatStillRequiresConverter() throws {
        let source = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )
        )
        let target = try format(rate: 16_000, channels: 1)
        let factoryCalls = LockedCount()

        let converter = try MicrophoneCapture.converter(
            from: source,
            to: target,
            factory: {
                factoryCalls.increment()
                return AVAudioConverter(from: $0, to: $1)
            }
        )

        XCTAssertNotNil(converter)
        XCTAssertEqual(factoryCalls.value, 1)
    }

    func testRuntimeConversionFailureIsNotSilentlyDropped() throws {
        let expectedSource = try format(rate: 48_000, channels: 2)
        let unexpectedSource = try format(rate: 44_100, channels: 1)
        let target = try format(rate: 16_000, channels: 1)
        let converter = try XCTUnwrap(AVAudioConverter(from: expectedSource, to: target))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: unexpectedSource, frameCapacity: 256)
        )
        buffer.frameLength = 256

        XCTAssertThrowsError(
            try MicrophoneCapture.extractSamples(from: buffer, using: converter, target: target)
        ) { error in
            guard case .unsupportedAudioFormat = error as? AudioCaptureError else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{0432}\u{0438}\u{0434}\u{0438}\u{043C}\u{0430}\u{044F} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0444}\u{043E}\u{0440}\u{043C}\u{0430}\u{0442}\u{0430}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
        }
    }

    func testPCMChunksFlattenInSessionOrder() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 4)
        let first = try XCTUnwrap(buffer.beginFrame(sampleTime: 0))
        _ = buffer.append([0.1, 0.2], frame: first, at: .now)
        buffer.endFrame()
        let second = try XCTUnwrap(buffer.beginFrame(sampleTime: 2))
        _ = buffer.append([0.3, 0.4], frame: second, at: .now)
        buffer.endFrame()

        let frozen = await buffer.freeze()
        XCTAssertEqual(frozen.samples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(frozen.totalSamples, 4)
    }

    func testPCMChunksFallBackToDiskAfterMemoryCap() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 3)
        let first = try XCTUnwrap(buffer.beginFrame())
        _ = buffer.append([0.1, 0.2], frame: first, at: .now)
        buffer.endFrame()
        let second = try XCTUnwrap(buffer.beginFrame())
        let overflow = buffer.append([0.3, 0.4], frame: second, at: .now)
        buffer.endFrame()
        let third = try XCTUnwrap(buffer.beginFrame())
        _ = buffer.append([0.5], frame: third, at: .now)
        buffer.endFrame()

        let frozen = await buffer.freeze()
        XCTAssertTrue(overflow.didOverflowMemory)
        XCTAssertNil(frozen.samples, "overflow must disable memory for the whole take")
        XCTAssertEqual(frozen.totalSamples, 5)
    }

    func testMemoryOnlyHardCapRetainsCompletePrefixAndClosesAdmission() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 3)
        let first = try XCTUnwrap(buffer.beginFrame())
        let firstAppend = buffer.append(
            [0.1, 0.2],
            frame: first,
            at: .now,
            preserveAtLimit: true
        )
        buffer.endFrame()
        XCTAssertFalse(firstAppend.didReachHardLimit)

        let overflowing = try XCTUnwrap(buffer.beginFrame())
        let limit = buffer.append(
            [0.3, 0.4],
            frame: overflowing,
            at: .now,
            preserveAtLimit: true
        )
        buffer.endFrame()

        XCTAssertTrue(limit.didReachHardLimit)
        XCTAssertFalse(limit.didOverflowMemory)
        XCTAssertNil(buffer.beginFrame(), "hard cap must immediately close RT admission")
        let frozen = await buffer.freeze()
        XCTAssertEqual(
            frozen.samples,
            [0.1, 0.2, 0.3],
            "memory-only capture must retain a complete ordered prefix for ASR"
        )
        XCTAssertEqual(
            frozen.totalSamples,
            3,
            "duration must describe the retained/transcribed prefix, not a rejected frame"
        )
        XCTAssertEqual(limit.committedSamples, [0.3])
    }

    func testMemoryLimitObserverRunsOffCallerAndCoalescesBoundedBacklog() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let deliveries = LockedCount()
        var released = false
        defer {
            if !released { release.signal() }
        }
        let session = DictationSessionID()
        let observer = CoalescingCaptureLimitObserver { _ in
            deliveries.increment()
            if deliveries.value == 1 {
                entered.signal()
                release.wait()
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        observer.submit(session: session)
        XCTAssertLessThan(
            start.duration(to: clock.now),
            .milliseconds(50),
            "capacity handling must never execute on the tap/capture caller"
        )
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        for _ in 0..<100 { observer.submit(session: session) }
        XCTAssertEqual(deliveries.value, 1)

        release.signal()
        released = true
        for _ in 0..<200 where deliveries.value < 2 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(deliveries.value, 2, "only one pending capacity notification is retained")
    }

    func testBlockedLiveSampleObserverKeepsOnlyTheNewestPendingFrame() async throws {
        let consumer = BlockingSampleConsumer()
        let observer = CoalescingSampleObserver(consume: consumer.consume)
        observer.submit([0])
        XCTAssertTrue(consumer.waitUntilBlocked())

        for value in 1...200 {
            observer.submit([Float(value)])
        }
        XCTAssertEqual(consumer.snapshots, [[0]], "a blocked meter must have only one active callback")

        consumer.unblock()
        for _ in 0..<200 where consumer.snapshots.count < 2 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(
            consumer.snapshots,
            [[0], [200]],
            "intermediate waveform frames are disposable; only the newest one may remain queued"
        )
    }

    func testBlockedExternalFailureHandlerNeverHoldsCaptureCallerOrLeaksTasks() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let deliveries = LockedCount()
        var released = false
        defer {
            if !released { release.signal() }
        }
        let session = DictationSessionID()
        let observer = CoalescingCaptureFailureObserver { _, _ in
            deliveries.increment()
            if deliveries.value == 1 {
                entered.signal()
                release.wait()
            }
        }

        observer.submit(session: session, error: .writeFailed("first"))
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<100 {
            observer.submit(session: session, error: .writeFailed("pending-\(index)"))
        }
        XCTAssertLessThan(
            started.duration(to: clock.now),
            .milliseconds(50),
            "external UI/controller handling must never execute on the capture actor"
        )
        XCTAssertEqual(deliveries.value, 1, "only one external call may be active")

        release.signal()
        released = true
        for _ in 0..<200 where deliveries.value < 2 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(deliveries.value, 2, "failures coalesce into one bounded pending slot")
    }

    func testDelayedFailureDeliveryCarriesOldTokenAndCannotInterruptNPlusOne() async throws {
        let old = DictationSessionID()
        let next = DictationSessionID()
        let receiver = TokenScopedEventReceiver()
        await receiver.activate(old)
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseOld.signal() }
        }
        let observer = CoalescingCaptureFailureObserver { session, _ in
            if session == old {
                oldEntered.signal()
                releaseOld.wait()
            }
            Task {
                await receiver.report(session)
                delivered.signal()
            }
        }

        observer.submit(session: old, error: .writeFailed("old"))
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)
        await receiver.activate(next)
        observer.submit(session: next, error: .writeFailed("next"))
        releaseOld.signal()
        released = true
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)

        let accepted = await receiver.acceptedSessions
        XCTAssertEqual(
            accepted,
            [next],
            "the observer must preserve N's token until the controller rejects stale delivery"
        )
    }

    func testDelayedMemoryLimitDeliveryCarriesOldTokenAndCannotStopNPlusOne() async throws {
        let old = DictationSessionID()
        let next = DictationSessionID()
        let receiver = TokenScopedEventReceiver()
        await receiver.activate(old)
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseOld.signal() }
        }
        let observer = CoalescingCaptureLimitObserver { session in
            if session == old {
                oldEntered.signal()
                releaseOld.wait()
            }
            Task {
                await receiver.report(session)
                delivered.signal()
            }
        }

        observer.submit(session: old)
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)
        await receiver.activate(next)
        observer.submit(session: next)
        releaseOld.signal()
        released = true
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)

        let accepted = await receiver.acceptedSessions
        XCTAssertEqual(
            accepted,
            [next],
            "capacity stop is session-scoped even when its queue resumes after N+1"
        )
    }

    func testPCMFreezeIncludesAFrameAlreadyInsideTheAudioCallback() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 8)
        let frame = try XCTUnwrap(buffer.beginFrame())

        let freezing = Task { await buffer.freeze() }
        for _ in 0..<10 { await Task.yield() }
        let at = ContinuousClock.now
        _ = buffer.append([0.1, 0.2, 0.3], frame: frame, at: at)
        buffer.endFrame()

        let frozen = await freezing.value
        XCTAssertEqual(frozen.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(frozen.totalSamples, 3)
        XCTAssertEqual(frozen.firstFrameAt, at)
        XCTAssertNil(buffer.beginFrame(), "no callback may enter after freeze")
    }

    func testPCMCapDropsOnlyMemoryCopyAndKeepsHonestDurationCount() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 4)
        let firstFrame = try XCTUnwrap(buffer.beginFrame())
        let first = buffer.append([0.1, 0.2, 0.3, 0.4], frame: firstFrame, at: .now)
        buffer.endFrame()
        XCTAssertFalse(first.didOverflowMemory)

        let overflowFrame = try XCTUnwrap(buffer.beginFrame())
        let overflow = buffer.append([0.5], frame: overflowFrame, at: .now)
        buffer.endFrame()
        XCTAssertTrue(overflow.didOverflowMemory)

        let frozen = await buffer.freeze()
        XCTAssertNil(frozen.samples, "a long take must use its complete disk-backed copy")
        XCTAssertEqual(frozen.totalSamples, 5, "duration counts captured sound, not retained RAM")
    }

    func testConcurrentPCMProducersUseComparableAudioTimestamps() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 3)
        let frames = [
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 100)), Float(1)),
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 200)), Float(2)),
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 300)), Float(3)),
        ]

        await withTaskGroup(of: Void.self) { group in
            for (frame, sample) in frames.reversed() {
                group.addTask {
                    await Task.yield()
                    _ = buffer.append([sample], frame: frame, at: .now)
                    buffer.endFrame()
                }
            }
        }

        let frozen = await buffer.freeze()
        XCTAssertEqual(frozen.samples, [1, 2, 3])
        XCTAssertEqual(frozen.totalSamples, 3)
    }

    func testNonMonotonicAudioTimelineFallsBackToLosslessIngressOrder() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 3)
        let frames = [
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 300)), Float(0)),
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 100)), Float(1)),
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 200)), Float(2)),
        ]
        for (frame, sample) in frames.reversed() {
            _ = buffer.append([sample], frame: frame, at: .now)
            buffer.endFrame()
        }

        let frozen = await buffer.freeze()
        XCTAssertEqual(frozen.samples, [0, 1, 2])
    }

    func testOneInvalidAudioTimestampMakesWholeSessionUseIngressOrder() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 3)
        let frames = [
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 300)), Float(0)),
            (try XCTUnwrap(buffer.beginFrame(sampleTime: nil)), Float(1)),
            (try XCTUnwrap(buffer.beginFrame(sampleTime: 100)), Float(2)),
        ]

        await withTaskGroup(of: Void.self) { group in
            for (frame, sample) in frames.reversed() {
                group.addTask {
                    _ = buffer.append([sample], frame: frame, at: .now)
                    buffer.endFrame()
                }
            }
        }

        let frozen = await buffer.freeze()
        XCTAssertEqual(frozen.samples, [0, 1, 2])
    }

    func testLastAudioCallbackNeverPerformsFlattenWork() async throws {
        let flattenEntered = DispatchSemaphore(value: 0)
        let releaseFlatten = DispatchSemaphore(value: 0)
        let endFrameReturned = DispatchSemaphore(value: 0)
        let buffer = RecordingPCMBuffer(maximumSamples: 4) {
            flattenEntered.signal()
            releaseFlatten.wait()
        }
        let frame = try XCTUnwrap(buffer.beginFrame())
        _ = buffer.append([0.1, 0.2, 0.3, 0.4], frame: frame, at: .now)

        let freezing = Task.detached { await buffer.freeze() }
        for _ in 0..<10 { await Task.yield() }
        let callback = Task.detached {
            buffer.endFrame()
            endFrameReturned.signal()
        }

        XCTAssertEqual(flattenEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            endFrameReturned.wait(timeout: .now() + 0.1),
            .success,
            "the last tap callback must only detach a snapshot, never flatten PCM"
        )
        releaseFlatten.signal()
        let frozen = await freezing.value
        await callback.value
        XCTAssertEqual(frozen.samples, [0.1, 0.2, 0.3, 0.4])
    }

    func testFiveMinuteChunkAppendAndOverflowStayWithinBroadRTBudget() async throws {
        let chunk = [Float](repeating: 0.1, count: 640)
        let frameCount = 7_500 // 4.8M samples: five minutes at 16 kHz.
        let buffer = RecordingPCMBuffer(maximumSamples: frameCount * chunk.count)
        let clock = ContinuousClock()
        let appendStart = clock.now
        for index in 0..<frameCount {
            let frame = try XCTUnwrap(
                buffer.beginFrame(sampleTime: AVAudioFramePosition(index * chunk.count))
            )
            _ = buffer.append(chunk, frame: frame, at: appendStart)
            buffer.endFrame()
        }
        let appendElapsed = appendStart.duration(to: clock.now)

        let overflowFrame = try XCTUnwrap(buffer.beginFrame())
        let overflowStart = clock.now
        let overflow = buffer.append([0.2], frame: overflowFrame, at: overflowStart)
        let overflowElapsed = overflowStart.duration(to: clock.now)
        buffer.endFrame()

        XCTAssertLessThan(
            appendElapsed,
            .seconds(2),
            "debug capture bookkeeping for a maximum take regressed catastrophically"
        )
        XCTAssertLessThan(
            overflowElapsed,
            .milliseconds(100),
            "crossing the cap must detach history in O(1), not destroy/copy it on the tap"
        )
        XCTAssertTrue(overflow.didOverflowMemory)
        let frozen = await buffer.freeze()
        XCTAssertNil(frozen.samples)
        XCTAssertEqual(frozen.totalSamples, frameCount * chunk.count + 1)
    }

    func testOverlappingConverterCallbacksRunOneAtATimeInTokenOrder() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 2)
        let firstFrame = try XCTUnwrap(buffer.beginFrame())
        let secondFrame = try XCTUnwrap(buffer.beginFrame())
        let sequencer = RecordingTapConversionSequencer()
        let secondScheduled = DispatchSemaphore(value: 0)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let diskOrder = LockedSamples()
        let firstFrameMarks = LockedSamples()

        let second = Task.detached {
            secondScheduled.signal()
            return try sequencer.perform(frame: secondFrame) {
                secondEntered.signal()
                let append = buffer.append([2], frame: secondFrame, at: .now)
                if append.isFirstFrame { firstFrameMarks.append(2) }
                diskOrder.append(2)
                return 2
            }
        }
        XCTAssertEqual(secondScheduled.wait(timeout: .now() + 1), .success)

        let first = Task.detached {
            try sequencer.perform(frame: firstFrame) {
                firstEntered.signal()
                // Conversion has finished, but lossless PCM/WAV commit is
                // deliberately gated to prove the turn remains owned here.
                releaseFirst.wait()
                let append = buffer.append([1], frame: firstFrame, at: .now)
                if append.isFirstFrame { firstFrameMarks.append(1) }
                diskOrder.append(1)
                return 1
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 0.1),
            .timedOut,
            "the shared AVAudioConverter must never be entered concurrently"
        )

        releaseFirst.signal()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 1)
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
        buffer.endFrame()
        buffer.endFrame()
        let frozen = await buffer.freeze()
        XCTAssertEqual(frozen.samples, [1, 2])
        XCTAssertEqual(diskOrder.values, [1, 2])
        XCTAssertEqual(firstFrameMarks.values, [1])
    }

    func testCancellingConversionSequencerReleasesQueuedOverlap() async throws {
        let buffer = RecordingPCMBuffer(maximumSamples: 2)
        let firstFrame = try XCTUnwrap(buffer.beginFrame())
        let secondFrame = try XCTUnwrap(buffer.beginFrame())
        let sequencer = RecordingTapConversionSequencer()
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)

        let first = Task.detached {
            try sequencer.perform(frame: firstFrame) {
                firstEntered.signal()
                releaseFirst.wait()
                return 1
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)
        let second = Task.detached {
            try sequencer.perform(frame: secondFrame) { 2 }
        }

        // Production performs this exact pair before scheduling any
        // AVAudioEngine stop/removeTap work. New callbacks are refused and an
        // overlap sleeping on NSCondition is released without joining it.
        buffer.closeAdmission()
        sequencer.cancelPending()
        XCTAssertNil(buffer.beginFrame())
        do {
            _ = try await withTranscriptionDeadline(.milliseconds(100)) {
                try await second.value
            }
            XCTFail("a queued old-session conversion should be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        releaseFirst.signal()
        let firstValue = try await first.value
        XCTAssertEqual(firstValue, 1)
        buffer.endFrame()
        buffer.endFrame()
    }

    func testCancelledFreezeDoesNotWaitForAStuckOldCallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cancelled-freeze-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldBuffer = RecordingPCMBuffer(maximumSamples: 8)
        let committedFrame = try XCTUnwrap(oldBuffer.beginFrame())
        _ = oldBuffer.append([0.1], frame: committedFrame, at: .now)
        oldBuffer.endFrame()
        let stuckFrame = try XCTUnwrap(oldBuffer.beginFrame())

        let oldFreeze = Task { await oldBuffer.freeze() }
        for _ in 0..<10 { await Task.yield() }
        oldFreeze.cancel()

        let frozen = try await withTranscriptionDeadline(.milliseconds(100)) {
            await oldFreeze.value
        }
        XCTAssertNil(frozen.samples)
        XCTAssertEqual(frozen.totalSamples, 0)
        XCTAssertNil(oldBuffer.beginFrame())
        let oldRecovery = Task {
            await oldBuffer.recoverAfterCancelledFreeze(callbackGrace: .milliseconds(20))
        }

        // The stale callback may eventually return, but its bounded recovery
        // lease owns only the old buffer. N+1 freezes independently first.
        let newBuffer = RecordingPCMBuffer(maximumSamples: 8)
        let newFrame = try XCTUnwrap(newBuffer.beginFrame())
        _ = newBuffer.append([0.7], frame: newFrame, at: .now)
        newBuffer.endFrame()
        let newFrozen = await newBuffer.freeze()
        XCTAssertEqual(newFrozen.samples, [0.7])

        // Do not release the old callback yet. Recovery must publish the
        // already committed prefix on its own bounded deadline.
        let recovered = try await withTranscriptionDeadline(.milliseconds(250)) {
            await oldRecovery.value
        }
        XCTAssertEqual(recovered.samples, [0.1])
        XCTAssertEqual(recovered.totalSamples, 1)

        let recording = finalizeMemoryOnlyCapturedRecording(
            url: directory.appending(path: "unopened.wav"),
            frozen: recovered,
            sampleRate: 16_000
        )
        let optionalRecoveredURL = try await recording.materializedRecoveryURL()
        let recoveredURL = try XCTUnwrap(optionalRecoveredURL)
        XCTAssertEqual(try AVAudioFile(forReading: recoveredURL).length, 1)
        let publishedBytes = try Data(contentsOf: recoveredURL)

        let lateAppend = oldBuffer.append([0.2], frame: stuckFrame, at: .now)
        XCTAssertTrue(lateAppend.wasRejected)
        oldBuffer.endFrame()

        // The late callback cannot produce a second snapshot or mutate the
        // exact-once materialized prefix after its recovery deadline.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try Data(contentsOf: recoveredURL), publishedBytes)
        let repeatedURL = try await recording.materializedRecoveryURL()
        XCTAssertEqual(repeatedURL, recoveredURL)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension.lowercased() == "wav" }.count,
            1
        )
    }

    func testCancellationAfterFreezeSnapshotMaterializesThatExactSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "freeze-handoff-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let buffer = RecordingPCMBuffer(maximumSamples: 8)
        let frame = try XCTUnwrap(buffer.beginFrame())
        let expectedSamples: [Float] = [0.125, -0.25, 0.5]
        _ = buffer.append(expectedSamples, frame: frame, at: .now)
        buffer.endFrame()

        let snapshotReady = OneShotAsyncGate()
        let allowCancellationCheck = OneShotAsyncGate()
        let handoff = Task.detached { () -> FrozenPCM in
            let prefrozen = await buffer.freeze()
            await snapshotReady.open()
            await allowCancellationCheck.wait()
            if Task.isCancelled {
                return await buffer.recoverAfterCancelledFreeze(prefrozen: prefrozen)
            }
            return prefrozen
        }
        try await withTranscriptionDeadline(.seconds(1)) {
            await snapshotReady.wait()
        }
        handoff.cancel()
        await allowCancellationCheck.open()

        let recovered = try await withTranscriptionDeadline(.milliseconds(100)) {
            await handoff.value
        }
        XCTAssertEqual(recovered.samples, expectedSamples)
        XCTAssertEqual(recovered.totalSamples, expectedSamples.count)

        let recoveredRecording = finalizeMemoryOnlyCapturedRecording(
            url: directory.appending(path: "cancelled.wav"),
            frozen: recovered,
            sampleRate: 16_000
        )
        let optionalRecoveredURL = try await recoveredRecording.materializedRecoveryURL()
        let recoveredURL = try XCTUnwrap(optionalRecoveredURL)

        let expectedURL = directory.appending(path: "expected.wav")
        let expectedWriter = WAVWriter(url: expectedURL, sampleRate: 16_000)
        try expectedWriter.open()
        try expectedWriter.append(expectedSamples)
        _ = try expectedWriter.close()
        XCTAssertEqual(
            try Data(contentsOf: recoveredURL),
            try Data(contentsOf: expectedURL),
            "cancellation after freeze must hand off the existing snapshot, not take an empty second one"
        )
    }

    func testTwoPermanentCallbacksContainWithinBoundAndReleaseRecoveryCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "two-bounded-containments-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recoveryCapacity = RecordingFreezeRecoveryContainment(maximumOutstanding: 2)
        let preservation = RecordingTechnicalPreservationContainment()
        var buffers: [RecordingPCMBuffer] = []
        var stuckFrames: [RecordingPCMFrame] = []
        var containments: [Task<Void, Never>] = []

        for index in 0..<2 {
            let reservation = try XCTUnwrap(recoveryCapacity.reserve())
            let lease = RecordingFreezeRecoveryLease(
                reservation: reservation,
                containment: recoveryCapacity
            )
            let buffer = RecordingPCMBuffer(maximumSamples: 8)
            let prefix: [Float] = [Float(index + 1) / 10]
            let prefixFrame = try XCTUnwrap(buffer.beginFrame())
            _ = buffer.append(prefix, frame: prefixFrame, at: .now)
            buffer.endFrame()
            let stuckFrame = try XCTUnwrap(buffer.beginFrame())
            buffer.closeAdmission()
            buffers.append(buffer)
            stuckFrames.append(stuckFrame)

            let url = directory.appending(path: "take-\(index).wav")
            containments.append(Task.detached {
                let frozen = await buffer.recoverAfterCancelledFreeze(
                    callbackGrace: .milliseconds(20)
                )
                let recording = finalizeMemoryOnlyCapturedRecording(
                    url: url,
                    frozen: frozen,
                    sampleRate: 16_000
                )
                scheduleTechnicalRecordingPreservation(
                    recording,
                    lease: lease,
                    containment: preservation
                )
            })
        }

        // Generous runaway backstops: the assertions below prove containment
        // and lease release; these deadlines only bound a genuine hang and
        // must not measure a loaded CI runner's disk.
        for containment in containments {
            try await withTranscriptionDeadline(.seconds(2)) {
                await containment.value
            }
        }
        try await withTranscriptionDeadline(.seconds(5)) {
            await preservation.waitUntilIdle()
        }
        let recoveryURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "wav" }
        XCTAssertEqual(recoveryURLs.count, 2)
        var recoveredSamples: [Int16] = []
        for url in recoveryURLs {
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 1)
            let data = try Data(contentsOf: url)
            let sample = data.withUnsafeBytes { bytes in
                Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: 44, as: Int16.self))
            }
            recoveredSamples.append(sample)
        }
        XCTAssertEqual(recoveredSamples.sorted(), [3_276, 6_553])

        let laterReservation = try XCTUnwrap(
            recoveryCapacity.reserve(),
            "both permanent-callback containments must release recovery capacity after preservation"
        )
        recoveryCapacity.release(laterReservation)

        // The callbacks are still permanently executing at every assertion
        // above. Releasing them later cannot mutate either published prefix.
        for (buffer, frame) in zip(buffers, stuckFrames) {
            XCTAssertTrue(buffer.append([0.9], frame: frame, at: .now).wasRejected)
            buffer.endFrame()
        }
    }

    func testTwoWedgedStoragePreservationsCannotPinEveryRecoveryLease() async throws {
        let recoveryCapacity = RecordingFreezeRecoveryContainment(maximumOutstanding: 2)
        let preservation = RecordingTechnicalPreservationContainment()
        let releaseStorage = OneShotAsyncGate()

        for index in 0..<2 {
            let reservation = try XCTUnwrap(recoveryCapacity.reserve())
            let lease = RecordingFreezeRecoveryLease(
                reservation: reservation,
                containment: recoveryCapacity
            )
            let url = URL(fileURLWithPath: "/tmp/wedged-preservation-\(index).wav")
            let wedged = Task<URL, Error> {
                await releaseStorage.wait()
                return url
            }
            let recording = CapturedRecording(
                url: url,
                duration: 0.1,
                samples: [0.1],
                readableTask: wedged,
                durableTask: wedged
            )
            scheduleTechnicalRecordingPreservation(
                recording,
                lease: lease,
                containment: preservation,
                storageDeadline: .milliseconds(20)
            )
        }

        // Runaway backstop, not a benchmark: the 20 ms storage deadline above
        // is what expires the wedged preservations; idle just has to arrive.
        try await withTranscriptionDeadline(.seconds(2)) {
            await preservation.waitUntilIdle()
        }
        let laterOne = try XCTUnwrap(recoveryCapacity.reserve())
        let laterTwo = try XCTUnwrap(recoveryCapacity.reserve())
        recoveryCapacity.release(laterOne)
        recoveryCapacity.release(laterTwo)

        await releaseStorage.open()
        try await Task.sleep(for: .milliseconds(20))
    }

    func testConcurrentCancelledMemoryRecoveriesSerializeWithoutDroppingSecondPrefix() async throws {
        enum ExpectedFailure: Error { case noRawFile }

        let recoveryCapacity = RecordingFreezeRecoveryContainment(maximumOutstanding: 2)
        let preservation = RecordingTechnicalPreservationContainment()
        let calls = LockedCount()
        let firstMaterializationEntered = OneShotAsyncGate()
        let releaseFirstMaterialization = OneShotAsyncGate()

        for index in 0..<2 {
            let reservation = try XCTUnwrap(recoveryCapacity.reserve())
            let lease = RecordingFreezeRecoveryLease(
                reservation: reservation,
                containment: recoveryCapacity
            )
            let unavailable = Task<URL, Error> { throw ExpectedFailure.noRawFile }
            let url = URL(fileURLWithPath: "/tmp/serialized-cancelled-prefix-\(index).wav")
            let recording = CapturedRecording(
                url: url,
                duration: 0.1,
                samples: [Float(index + 1) / 10],
                readableTask: unavailable,
                durableTask: unavailable,
                materializeRecovery: {
                    calls.increment()
                    if calls.value == 1 {
                        await firstMaterializationEntered.open()
                        await releaseFirstMaterialization.wait()
                    }
                    return url
                }
            )
            scheduleTechnicalRecordingPreservation(
                recording,
                lease: lease,
                containment: preservation,
                storageDeadline: .milliseconds(200)
            )
        }

        try await withTranscriptionDeadline(.milliseconds(100)) {
            await firstMaterializationEntered.wait()
        }
        XCTAssertEqual(calls.value, 1)
        await releaseFirstMaterialization.open()
        try await withTranscriptionDeadline(.milliseconds(200)) {
            await preservation.waitUntilIdle()
        }
        XCTAssertEqual(
            calls.value,
            2,
            "the second cancelled PCM prefix must wait for the lane, not lose a tryAcquire race"
        )
        let laterOne = try XCTUnwrap(recoveryCapacity.reserve())
        let laterTwo = try XCTUnwrap(recoveryCapacity.reserve())
        recoveryCapacity.release(laterOne)
        recoveryCapacity.release(laterTwo)
    }

    func testRepeatedAbortDetachesHistoricalChunksFromPermanentlyExecutingCallbacks() async throws {
        let releaseContainment = RecordingPCMDiscardReleaseContainment()
        let releasedChunks = LockedCount()
        var stuckBuffers: [RecordingPCMBuffer] = []
        var stuckFrames: [RecordingPCMFrame] = []
        let sessionCount = 100
        let chunksPerSession = 32

        for session in 0..<sessionCount {
            let buffer = RecordingPCMBuffer(
                maximumSamples: chunksPerSession,
                onChunkRelease: { releasedChunks.increment() },
                discardReleaseContainment: releaseContainment
            )
            for sample in 0..<chunksPerSession {
                let frame = try XCTUnwrap(buffer.beginFrame())
                _ = buffer.append(
                    [Float((session + sample) % 10) / 10],
                    frame: frame,
                    at: .now
                )
                buffer.endFrame()
            }
            let stuckFrame = try XCTUnwrap(buffer.beginFrame())
            buffer.closeAdmission()
            buffer.discard()
            stuckBuffers.append(buffer)
            stuckFrames.append(stuckFrame)
        }

        try await withTranscriptionDeadline(.seconds(1)) {
            await releaseContainment.waitUntilIdle()
        }
        XCTAssertEqual(releasedChunks.value, sessionCount * chunksPerSession)
        XCTAssertEqual(
            releaseContainment.maximumConcurrentDrains,
            1,
            "repeated Escape must reuse one off-RT release owner, not spawn an unbounded task backlog"
        )

        // Every simulated callback still retains its old PCM buffer, proving
        // the historical chains were detached rather than merely deferred on
        // that indefinitely live object.
        for (buffer, frame) in zip(stuckBuffers, stuckFrames) {
            XCTAssertTrue(buffer.append([0.8], frame: frame, at: .now).wasRejected)
        }
        XCTAssertEqual(releasedChunks.value, sessionCount * chunksPerSession)
        for (buffer, _) in zip(stuckBuffers, stuckFrames) { buffer.endFrame() }
    }

    /// The blocking teardown must not run on Swift's cooperative pool.
    ///
    /// This is the recognition stall, pinned at its cause. `engine.stop()` and
    /// `removeTap` may block inside AVFAudio — the comment on the containment
    /// says so — and they used to be launched with `Task.detached`, which puts
    /// them on the cooperative pool: one thread per core, and Swift documents
    /// that blocking one is not yielding it but losing it. The recognition
    /// that follows a dictation is suspended on that same pool, so a parked
    /// teardown held the finished text behind it. Field logs showed exactly
    /// that shape — recognition seconds long around an inference call that
    /// never exceeded 1.07 s, with the main thread awake throughout.
    ///
    /// Asserted by naming the queue rather than by racing the scheduler: a
    /// test that blocks one thread and hopes the pool notices passes on a
    /// machine with a spare core, which is every developer machine and no
    /// loaded one. The label is checkable and cannot pass by luck.
    func testTheBlockingTeardownRunsOffTheCooperativePool() throws {
        let lane = RecordingEngineShutdownContainment()
        let ran = DispatchSemaphore(value: 0)
        let label = UnsafeMutableTransferBox<String?>(nil)

        let reservation = try XCTUnwrap(lane.reserve())
        lane.submit(reservation: reservation) {
            label.value = String(
                cString: __dispatch_queue_get_label(nil),
                encoding: .utf8
            )
            ran.signal()
        }
        XCTAssertEqual(ran.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(
            label.value,
            RecordingEngineShutdownContainment.teardownQueueLabel,
            "a call documented as blocking must not occupy a cooperative-pool thread"
        )
    }

    func testWedgedOldEngineShutdownAllowsNPlusOneWithGloballyBoundedWork() throws {
        let lane = RecordingEngineShutdownContainment()
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let pendingRan = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseOld.signal() }
        }

        let oldReservation = try XCTUnwrap(lane.reserve())
        lane.submit(reservation: oldReservation) {
            oldEntered.signal()
            releaseOld.wait()
        }
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)

        // The production actor has already nilled its engine/context. N+1 can
        // reserve and run while old shutdown is stuck, but N+2 is rejected so
        // no third task/engine can accumulate.
        let nextReservation = try XCTUnwrap(lane.reserve())
        XCTAssertNil(
            lane.reserve(),
            "one executing plus one live/pending generation is the global bound"
        )
        lane.submit(reservation: nextReservation) { pendingRan.signal() }
        XCTAssertEqual(pendingRan.wait(timeout: .now() + 0.05), .timedOut)

        releaseOld.signal()
        released = true
        XCTAssertEqual(pendingRan.wait(timeout: .now() + 1), .success)
        let afterDrain = try XCTUnwrap(lane.reserve())
        lane.release(afterDrain)
    }

    func testTwoPermanentlyStartingEnginesRemainCancellableAndGloballyBounded() async throws {
        let lane = RecordingEngineStartContainment(maximumOutstanding: 2)
        let oldEntered = DispatchSemaphore(value: 0)
        let nextEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let releaseNext = DispatchSemaphore(value: 0)
        let oldAbandoned = DispatchSemaphore(value: 0)
        let nextAbandoned = DispatchSemaphore(value: 0)
        var releasedOld = false
        var releasedNext = false
        defer {
            if !releasedOld { releaseOld.signal() }
            if !releasedNext { releaseNext.signal() }
        }

        let oldReservation = try XCTUnwrap(lane.reserve())
        let old = Task.detached {
            await lane.start(
                reservation: oldReservation,
                operation: {
                    oldEntered.signal()
                    releaseOld.wait()
                    return .success(())
                },
                onAbandon: { oldAbandoned.signal() }
            )
        }
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)

        lane.cancel(reservation: oldReservation)
        let oldOutcome = try await withTranscriptionDeadline(.milliseconds(100)) {
            await old.value
        }
        XCTAssertEqual(oldOutcome, .cancelled)

        // N's cancellation returns to the controller without joining the
        // cancellation-deaf native call. N+1 receives its own bounded lane and
        // can therefore reach the same logical timeout independently.
        let nextReservation = try XCTUnwrap(lane.reserve())
        let next = Task.detached {
            await lane.start(
                reservation: nextReservation,
                operation: {
                    nextEntered.signal()
                    releaseNext.wait()
                    return .success(())
                },
                onAbandon: { nextAbandoned.signal() }
            )
        }
        XCTAssertEqual(nextEntered.wait(timeout: .now() + 1), .success)
        XCTAssertNil(
            lane.reserve(),
            "two permanently executing native starts are the global engine/worker bound"
        )

        lane.cancel(reservation: nextReservation)
        let nextOutcome = try await withTranscriptionDeadline(.milliseconds(100)) {
            await next.value
        }
        XCTAssertEqual(nextOutcome, .cancelled)
        XCTAssertNil(lane.reserve(), "logical cancellation must not hide live native resources")

        releaseNext.signal()
        releasedNext = true
        XCTAssertEqual(nextAbandoned.wait(timeout: .now() + 1), .success)
        let recoveredSlot = try XCTUnwrap(lane.reserve())
        lane.release(recoveredSlot)

        releaseOld.signal()
        releasedOld = true
        XCTAssertEqual(oldAbandoned.wait(timeout: .now() + 1), .success)
    }

    func testLateCancelledEngineStartCannotBecomeTheNewGeneration() async throws {
        let lane = RecordingEngineStartContainment(maximumOutstanding: 2)
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let oldAbandoned = DispatchSemaphore(value: 0)
        let abandonedCount = LockedCount()
        var released = false
        defer {
            if !released { releaseOld.signal() }
        }

        let oldReservation = try XCTUnwrap(lane.reserve())
        let old = Task.detached {
            await lane.start(
                reservation: oldReservation,
                operation: {
                    oldEntered.signal()
                    releaseOld.wait()
                    return .success(())
                },
                onAbandon: {
                    abandonedCount.increment()
                    oldAbandoned.signal()
                }
            )
        }
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)
        lane.cancel(reservation: oldReservation)
        let oldOutcome = try await withTranscriptionDeadline(.milliseconds(100)) {
            await old.value
        }
        XCTAssertEqual(oldOutcome, .cancelled)

        let nextReservation = try XCTUnwrap(lane.reserve())
        let next = Task.detached {
            await lane.start(
                reservation: nextReservation,
                operation: { .success(()) },
                onAbandon: { XCTFail("the current generation must not be abandoned") }
            )
        }
        let nextOutcome = try await withTranscriptionDeadline(.milliseconds(100)) {
            await next.value
        }
        XCTAssertEqual(nextOutcome, .started)

        // N returns only after N+1 has already been accepted. Its sole allowed
        // effect is exact-generation cleanup; no second result/adoption exists.
        releaseOld.signal()
        released = true
        XCTAssertEqual(oldAbandoned.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(abandonedCount.value, 1)
    }

    func testEngineStartAdoptionRequiresExactPendingSessionAndLiveDisposition() {
        let oldSession = DictationSessionID()
        let currentSession = DictationSessionID()
        let oldID = UUID()
        let currentID = UUID()
        let oldURL = URL(fileURLWithPath: "/tmp/old-start.wav")
        let currentURL = URL(fileURLWithPath: "/tmp/current-start.wav")

        XCTAssertTrue(
            recordingStartMayAdopt(
                pendingID: currentID,
                pendingSession: currentSession,
                pendingURL: currentURL,
                completedID: currentID,
                completedSession: currentSession,
                completedURL: currentURL,
                disposition: .active,
                isTombstoned: false
            )
        )
        XCTAssertFalse(
            recordingStartMayAdopt(
                pendingID: currentID,
                pendingSession: currentSession,
                pendingURL: currentURL,
                completedID: oldID,
                completedSession: oldSession,
                completedURL: oldURL,
                disposition: .active,
                isTombstoned: false
            ),
            "a late N completion must not adopt the N+1 pending slot"
        )
        XCTAssertFalse(
            recordingStartMayAdopt(
                pendingID: currentID,
                pendingSession: currentSession,
                pendingURL: currentURL,
                completedID: currentID,
                completedSession: currentSession,
                completedURL: currentURL,
                disposition: .keepInBackground,
                isTombstoned: false
            )
        )
        XCTAssertFalse(
            recordingStartMayAdopt(
                pendingID: currentID,
                pendingSession: currentSession,
                pendingURL: currentURL,
                completedID: currentID,
                completedSession: currentSession,
                completedURL: currentURL,
                disposition: .active,
                isTombstoned: true
            )
        )
    }

    func testEngineStartCancelledBeforeSubmissionNeverLaunchesNativeWork() async throws {
        let lane = RecordingEngineStartContainment(maximumOutstanding: 2)
        let reservation = try XCTUnwrap(lane.reserve())
        let nativeCalls = LockedCount()
        let abandonments = LockedCount()
        lane.cancel(reservation: reservation)

        let outcome = try await withTranscriptionDeadline(.milliseconds(100)) {
            await lane.start(
                reservation: reservation,
                operation: {
                    nativeCalls.increment()
                    return .success(())
                },
                onAbandon: { abandonments.increment() }
            )
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(nativeCalls.value, 0)
        XCTAssertEqual(abandonments.value, 1)
        let reclaimed = try XCTUnwrap(lane.reserve())
        lane.release(reclaimed)
    }

    func testWedgedWriterCloseAllowsOnlyOneLivePendingDescriptor() throws {
        let lane = RecordingWriterCloseContainment(maximumOutstanding: 2)
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let pendingRan = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseOld.signal() }
        }

        let oldReservation = try XCTUnwrap(lane.reserve())
        lane.submit(reservation: oldReservation) {
            oldEntered.signal()
            releaseOld.wait()
        }
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)

        let nextReservation = try XCTUnwrap(lane.reserve())
        XCTAssertNil(
            lane.reserve(),
            "one wedged close plus one live/pending writer is the global FD bound"
        )
        lane.submit(reservation: nextReservation) { pendingRan.signal() }
        XCTAssertEqual(pendingRan.wait(timeout: .now() + 0.05), .timedOut)

        releaseOld.signal()
        released = true
        XCTAssertEqual(pendingRan.wait(timeout: .now() + 1), .success)
        let afterDrain = try XCTUnwrap(lane.reserve())
        lane.release(afterDrain)
    }

    func testAbortBeforeStartTombstoneRejectsLateAndOlderRequestsOnly() {
        let older = DictationSessionID()
        let cancelled = DictationSessionID()
        let newer = DictationSessionID()
        var tombstones = RecordingSessionTombstones()

        tombstones.recordCancellation(cancelled)

        XCTAssertTrue(tombstones.contains(cancelled))
        XCTAssertTrue(tombstones.contains(older), "an even older delayed start is stale too")
        XCTAssertFalse(tombstones.contains(newer), "N+1 remains startable")
    }

    func testPermanentWriterOpenWedgeKeepsOneWorkerAndOneHundredTakesUsePCM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "writer-open-wedge-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let openCalls = LockedCount()
        let disposals = LockedCount()
        let unexpectedCompletions = LockedCount()
        let oldEntered = DispatchSemaphore(value: 0)
        let releaseOld = DispatchSemaphore(value: 0)
        let oldCancelled = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseOld.signal() }
        }
        let coordinator = RecordingWriterOpenCoordinator(
            open: { _ in
                openCalls.increment()
                if openCalls.value == 1 {
                    oldEntered.signal()
                    releaseOld.wait()
                }
            },
            dispose: { _ in disposals.increment() }
        )
        let wedgedSession = DictationSessionID()
        XCTAssertTrue(
            coordinator.begin(
                writer: WAVWriter(url: directory.appending(path: "wedged.wav")),
                session: wedgedSession,
                completion: { result in
                    if case .cancelled = result { oldCancelled.signal() }
                }
            )
        )
        XCTAssertEqual(oldEntered.wait(timeout: .now() + 1), .success)
        coordinator.cancel(session: wedgedSession)
        XCTAssertEqual(oldCancelled.wait(timeout: .now() + 0.1), .success)

        let clock = ContinuousClock()
        let started = clock.now
        for index in 0..<100 {
            let session = DictationSessionID()
            XCTAssertFalse(
                coordinator.begin(
                    writer: WAVWriter(url: directory.appending(path: "short-\(index).wav")),
                    session: session,
                    completion: { _ in unexpectedCompletions.increment() }
                )
            )

            let pcm = RecordingPCMBuffer(maximumSamples: 8)
            let frame = try XCTUnwrap(pcm.beginFrame())
            _ = pcm.append([Float(index), 0.25], frame: frame, at: .now)
            pcm.endFrame()
            let frozen = await pcm.freeze()
            XCTAssertEqual(frozen.samples, [Float(index), 0.25])
        }
        XCTAssertLessThan(
            started.duration(to: clock.now),
            .seconds(1),
            "filesystem availability must not become microphone start latency"
        )
        XCTAssertEqual(openCalls.value, 1, "only one non-cancellable open may be in flight")
        XCTAssertEqual(disposals.value, 100, "rejected writers create no worker or descriptor")
        XCTAssertEqual(unexpectedCompletions.value, 0)

        releaseOld.signal()
        released = true
        for _ in 0..<200 where disposals.value < 101 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(disposals.value, 101, "the cancelled late result is disposed exactly once")

        let nextOpened = DispatchSemaphore(value: 0)
        XCTAssertTrue(
            coordinator.begin(
                writer: WAVWriter(url: directory.appending(path: "after-wedge.wav")),
                session: DictationSessionID(),
                completion: { result in
                    if case let .opened(managedWriter) = result {
                        managedWriter.scheduleAbandon()
                        nextOpened.signal()
                    }
                }
            )
        )
        XCTAssertEqual(nextOpened.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(openCalls.value, 2)
    }

    func testLateWriterOpenSelfDisposesWhenDispositionWasDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "late-open-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "late.wav")
        let disposition = RecordingDisposition()
        disposition.register([url])
        let opened = DispatchSemaphore(value: 0)
        let releaseOpen = DispatchSemaphore(value: 0)
        let disposed = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseOpen.signal() }
        }
        let coordinator = RecordingWriterOpenCoordinator(
            open: { writer in
                try writer.open()
                opened.signal()
                releaseOpen.wait()
            },
            dispose: { writer in
                try? FileManager.default.removeItem(at: writer.fileURL)
                disposed.signal()
            }
        )

        XCTAssertTrue(
            coordinator.begin(
                writer: WAVWriter(url: url),
                session: DictationSessionID(),
                disposition: disposition,
                completion: { result in
                    if case .cancelled = result { completed.signal() }
                }
            )
        )
        XCTAssertEqual(opened.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertTrue(disposition.requestDelete())
        releaseOpen.signal()
        released = true
        XCTAssertEqual(disposed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "open completion must clean itself even if the capture actor is wedged"
        )
    }

    func testFirstPCMCommitAndWriterAttachHaveOneUnambiguousWinner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "disk-attach-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cancellations = LockedCount()
        let memoryOnly = RecordingDiskAttachment { cancellations.increment() }
        memoryOnly.submit([0.1])
        XCTAssertEqual(cancellations.value, 1)

        let lateWriter = WAVWriter(url: directory.appending(path: "late.wav"))
        try lateWriter.open()
        let lateDisk = RecordingDiskState(writer: lateWriter) { _ in }
        let lateSink = FrameSink()
        let lateEnqueue = lateSink.start { lateDisk.append($0) }
        let latePipeline = RecordingDiskPipeline(
            writer: lateWriter,
            disk: lateDisk,
            sink: lateSink,
            enqueue: lateEnqueue
        )
        XCTAssertFalse(
            memoryOnly.attach(latePipeline),
            "a writer that missed the prefix must never be published as complete"
        )
        lateSink.cancel()
        lateWriter.abandonForRecovery()

        let attached = RecordingDiskAttachment {}
        let completeWriter = WAVWriter(url: directory.appending(path: "complete.wav"))
        try completeWriter.open()
        let completeDisk = RecordingDiskState(writer: completeWriter) { _ in }
        let completeSink = FrameSink()
        let completeEnqueue = completeSink.start { completeDisk.append($0) }
        let completePipeline = RecordingDiskPipeline(
            writer: completeWriter,
            disk: completeDisk,
            sink: completeSink,
            enqueue: completeEnqueue
        )
        XCTAssertTrue(attached.attach(completePipeline))
        attached.closeForMemoryLimit()
        attached.submit([0.2, 0.3])
        let taken = try XCTUnwrap(attached.takePipeline())
        await taken.sink.seal().value
        XCTAssertEqual(completeWriter.duration, 2.0 / 16_000, accuracy: 0.0001)
        completeWriter.abandonForRecovery()
    }

    func testFailedAttachedDiskUsesGracefulPCMCapInsteadOfDroppingTake() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "failed-attached-cap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = WAVWriter(url: directory.appending(path: "failed.wav"))
        try writer.open()
        let disk = RecordingDiskState(writer: writer) { _ in }
        let sink = FrameSink()
        let enqueue = sink.start { disk.append($0) }
        let attachment = RecordingDiskAttachment {}
        XCTAssertTrue(
            attachment.attach(
                RecordingDiskPipeline(
                    writer: writer,
                    disk: disk,
                    sink: sink,
                    enqueue: enqueue
                )
            )
        )
        disk.queueOverflowed()
        XCTAssertNotNil(disk.recordedFailure)

        let pcm = RecordingPCMBuffer(maximumSamples: 2)
        let first = try XCTUnwrap(pcm.beginFrame())
        _ = pcm.append([0.1, 0.2], frame: first, at: .now)
        pcm.endFrame()
        let overflowing = try XCTUnwrap(pcm.beginFrame())
        let limit = pcm.append(
            [0.3],
            frame: overflowing,
            at: .now,
            preserveAtLimit: true
        )
        pcm.endFrame()
        if limit.didReachHardLimit { attachment.closeForMemoryLimit() }

        XCTAssertTrue(limit.didReachHardLimit)
        XCTAssertFalse(limit.didOverflowMemory)
        let frozen = await pcm.freeze()
        XCTAssertEqual(frozen.samples, [0.1, 0.2])
        XCTAssertEqual(frozen.totalSamples, 2)
        attachment.takePipeline()?.sink.cancel()
        writer.abandonForRecovery()
    }

    func testQueuedDiskFailureAfterCapSnapshotStillRetainsCompletePCM() async throws {
        enum InjectedFailure: Error { case delayedWrite }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "delayed-cap-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let enteredWrite = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        var released = false
        defer {
            if !released { releaseWrite.signal() }
        }
        let writer = WAVWriter(
            url: directory.appending(path: "delayed.wav"),
            dataWriter: { _, _ in
                enteredWrite.signal()
                releaseWrite.wait()
                throw InjectedFailure.delayedWrite
            }
        )
        try writer.open()
        let disk = RecordingDiskState(writer: writer) { _ in }
        let sink = FrameSink()
        let enqueue = sink.start { disk.append($0) }
        let attachment = RecordingDiskAttachment {}
        XCTAssertTrue(
            attachment.attach(
                RecordingDiskPipeline(
                    writer: writer,
                    disk: disk,
                    sink: sink,
                    enqueue: enqueue
                )
            )
        )

        let pcm = RecordingPCMBuffer(maximumSamples: 3)
        let firstFrame = try XCTUnwrap(pcm.beginFrame())
        let first = pcm.append(
            [0.1, 0.2],
            frame: firstFrame,
            at: .now,
            preserveAtLimit: true
        )
        pcm.endFrame()
        attachment.submit(try XCTUnwrap(first.committedSamples))
        XCTAssertEqual(enteredWrite.wait(timeout: .now() + 1), .success)
        XCTAssertNil(
            disk.recordedFailure,
            "the kernel failure is deliberately unresolved at the cap decision"
        )

        let capFrame = try XCTUnwrap(pcm.beginFrame())
        let cap = pcm.append(
            [0.3, 0.4],
            frame: capFrame,
            at: .now,
            preserveAtLimit: true
        )
        pcm.endFrame()
        XCTAssertTrue(cap.didReachHardLimit)
        attachment.submit(try XCTUnwrap(cap.committedSamples))
        attachment.closeForMemoryLimit()
        let frozen = await pcm.freeze()
        XCTAssertEqual(frozen.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(frozen.totalSamples, 3)

        releaseWrite.signal()
        released = true
        let pipeline = try XCTUnwrap(attachment.takePipeline())
        let recording = finalizeCapturedRecording(
            url: writer.fileURL,
            writer: writer,
            disk: disk,
            sink: pipeline.sink,
            frozen: frozen,
            sampleRate: 16_000
        )
        await XCTAssertThrowsErrorAsync(try await recording.readableURL())
        let materialized = try await recording.materializedRecoveryURL()
        let recoveryURL = try XCTUnwrap(materialized)
        XCTAssertEqual(try AVAudioFile(forReading: recoveryURL).length, 3)
    }

    func testMemoryAndDiskFailureSurfaceOnceAndKeepDurationHonest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "dual-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = WAVWriter(url: directory.appending(path: "take.wav"))
        try writer.open()
        let notifications = LockedCount()
        let disk = RecordingDiskState(writer: writer) { _ in notifications.increment() }
        disk.queueOverflowed()
        XCTAssertEqual(notifications.value, 0, "complete PCM still protects a short take")

        let buffer = RecordingPCMBuffer(maximumSamples: 2)
        let firstFrame = try XCTUnwrap(buffer.beginFrame())
        _ = buffer.append([0.1, 0.2], frame: firstFrame, at: .now)
        buffer.endFrame()
        let overflowFrame = try XCTUnwrap(buffer.beginFrame())
        let overflow = buffer.append([0.3], frame: overflowFrame, at: .now)
        buffer.endFrame()
        XCTAssertTrue(overflow.didOverflowMemory)
        disk.memoryDidOverflow()
        disk.memoryDidOverflow()

        let frozen = await buffer.freeze()
        XCTAssertNil(frozen.samples)
        XCTAssertEqual(frozen.totalSamples, 3)
        XCTAssertEqual(notifications.value, 1, "dual storage failure is reported exactly once")
    }

    func testBlockedOldStorageFailureCannotInterruptNewSession() async throws {
        enum InjectedFailure: Error { case oldWrite }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stale-storage-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldID = UUID()
        let oldURL = directory.appending(path: "old.wav")
        let newID = UUID()
        let newURL = directory.appending(path: "new.wav")
        let receiver = SessionFailureReceiver()
        await receiver.activate(id: oldID, url: oldURL)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let writer = WAVWriter(url: oldURL, dataWriter: { _, _ in
            entered.signal()
            release.wait()
            throw InjectedFailure.oldWrite
        })
        try writer.open()
        let disk = RecordingDiskState(writer: writer) { _ in
            Task {
                await receiver.report(id: oldID, url: oldURL)
                delivered.signal()
            }
        }
        disk.memoryDidOverflow()
        let blockedOldWrite = Task.detached { disk.append([0.1]) }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        await receiver.activate(id: newID, url: newURL)
        release.signal()
        await blockedOldWrite.value
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        let failureCount = await receiver.failureCount
        XCTAssertEqual(failureCount, 0)
        writer.abandonForRecovery()
    }

    func testCaptureRequestFenceRejectsStaleSessionEvenWithoutURL() {
        let activeURL = URL(fileURLWithPath: "/tmp/new-session.wav")
        let staleSession = DictationSessionID()
        let activeSession = DictationSessionID()

        XCTAssertFalse(
            captureRequestMatches(
                activeSession: activeSession,
                activeURL: activeURL,
                expectedSession: staleSession,
                expectedURL: nil
            ),
            "a preparing-session cancel with no URL must not target the next session"
        )
        XCTAssertTrue(
            captureRequestMatches(
                activeSession: activeSession,
                activeURL: activeURL,
                expectedSession: activeSession,
                expectedURL: nil
            ),
            "the same preparing session must remain cancellable before its URL returns"
        )
        XCTAssertFalse(
            captureRequestMatches(
                activeSession: activeSession,
                activeURL: activeURL,
                expectedSession: activeSession,
                expectedURL: URL(fileURLWithPath: "/tmp/old-session.wav")
            )
        )
    }

    func testNewerAdmissionSynchronouslyReclaimsOnlyCausallyFinishedContext() {
        let older = DictationSessionID()
        let newer = DictationSessionID()

        XCTAssertEqual(
            recordingAdmissionDecision(
                activeSession: older,
                activeDisposition: .active,
                requestedSession: newer
            ),
            .reject
        )
        XCTAssertEqual(
            recordingAdmissionDecision(
                activeSession: older,
                activeDisposition: .deleteRequested,
                requestedSession: newer
            ),
            .supersedeDestructively
        )
        XCTAssertEqual(
            recordingAdmissionDecision(
                activeSession: older,
                activeDisposition: .keepInBackground,
                requestedSession: newer
            ),
            .supersedeTechnically
        )
        XCTAssertEqual(
            recordingAdmissionDecision(
                activeSession: newer,
                activeDisposition: .deleteRequested,
                requestedSession: older
            ),
            .reject,
            "a stale start may never reclaim a newer active generation"
        )
    }

    func testTechnicalContainmentWithNoContextNeverUnlinksExpectedRawPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "contain-no-context-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawURL = directory.appending(path: "already-detached.wav")
        try Data([1, 2, 3, 4]).write(to: rawURL)
        let capture = MicrophoneCapture(directory: directory)

        await capture.containRecording(
            session: DictationSessionID(),
            expectedURL: rawURL
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rawURL.path),
            "technical containment must not reinterpret an absent context as user deletion"
        )
        XCTAssertEqual(try Data(contentsOf: rawURL), Data([1, 2, 3, 4]))
    }

    func testLastCallbackFailureReachesFreezeBeforeDelayedUIDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "last-callback-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = RecordingPCMBuffer(maximumSamples: 8)
        let successfulFrame = try XCTUnwrap(buffer.beginFrame())
        _ = buffer.append([0.1], frame: successfulFrame, at: .now)
        buffer.endFrame()
        _ = try XCTUnwrap(buffer.beginFrame())
        let failureLedger = RecordingCaptureFailureLedger()
        let failure = AudioCaptureError.unsupportedAudioFormat("injected converter failure")

        let oldID = UUID()
        let oldURL = URL(fileURLWithPath: "/tmp/failing-session.wav")
        let newID = UUID()
        let newURL = URL(fileURLWithPath: "/tmp/next-session.wav")
        let receiver = SessionFailureReceiver()
        await receiver.activate(id: oldID, url: oldURL)
        let releaseUI = DispatchSemaphore(value: 0)
        let uiFinished = DispatchSemaphore(value: 0)

        let freezing = Task { await buffer.freeze() }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(failureLedger.record(failure))
        XCTAssertFalse(
            failureLedger.record(failure),
            "one converter failure may schedule only one live notification"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseUI.wait()
            Task {
                await receiver.report(id: oldID, url: oldURL)
                uiFinished.signal()
            }
        }
        buffer.endFrame()

        let frozen = await freezing.value
        XCTAssertEqual(
            frozen.samples,
            [0.1],
            "fatal capture must retain the complete valid prefix for technical recovery"
        )
        XCTAssertEqual(
            failureLedger.recordedFailure,
            failure,
            "freeze must observe the synchronous fatal ledger before allowing ASR"
        )
        var recognizerCalls = 0
        if failureLedger.recordedFailure == nil {
            recognizerCalls += 1
        }
        XCTAssertEqual(
            recognizerCalls,
            0,
            "a fatal converter ledger still gates the valid prefix away from ASR"
        )

        let recoveryRecording = finalizeMemoryOnlyCapturedRecording(
            url: directory.appending(path: "failed.wav"),
            frozen: frozen,
            sampleRate: 16_000
        )
        let optionalRecoveryURL = try await recoveryRecording.materializedRecoveryURL()
        let recoveryURL = try XCTUnwrap(optionalRecoveryURL)
        XCTAssertEqual(try AVAudioFile(forReading: recoveryURL).length, 1)

        // Production clears the old context before waiting at the callback
        // barrier. Its delayed UI task must not touch the next session; the
        // finalizer surfaces the ledger error for N exactly once instead.
        await receiver.activate(id: newID, url: newURL)
        releaseUI.signal()
        XCTAssertEqual(uiFinished.wait(timeout: .now() + 1), .success)
        let nextSessionFailures = await receiver.failureCount
        XCTAssertEqual(nextSessionFailures, 0)
    }

    func testDiskFailureCanRebuildACompleteRecoveryWAVFromPCM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "raw-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "take.wav")
        let writer = WAVWriter(url: url)
        try writer.open()
        let disk = RecordingDiskState(writer: writer) { _ in }
        disk.queueOverflowed()
        let sink = FrameSink()
        _ = sink.start { disk.append($0) }
        let recording = finalizeCapturedRecording(
            url: url,
            writer: writer,
            disk: disk,
            sink: sink,
            frozen: FrozenPCM(samples: [0.1, 0.2, 0.3], totalSamples: 3, firstFrameAt: .now),
            sampleRate: 16_000
        )

        await XCTAssertThrowsErrorAsync(try await recording.readableURL())
        XCTAssertEqual(recording.samples, [0.1, 0.2, 0.3])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "failed disk audio stays in Takes for the existing launch repair"
        )
        let rebuiltOptional = try await recording.materializedRecoveryURL()
        let rebuilt = try XCTUnwrap(rebuiltOptional)
        XCTAssertNotEqual(rebuilt, url)
        XCTAssertEqual(
            try AVAudioFile(forReading: rebuilt).length,
            3,
            "recovery must contain the full in-memory take, not the truncated disk prefix"
        )
        XCTAssertThrowsError(try writer.append([0.3])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
    }

    func testManagedSealFaultReleasesWriterCapacityExactlyOnce() async throws {
        enum InjectedFailure: Error { case seal }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "managed-seal-fault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let containment = RecordingWriterCloseContainment(maximumOutstanding: 2)

        for index in 0..<2 {
            var reservation: RecordingWriterCloseReservation?
            for _ in 0..<200 where reservation == nil {
                reservation = containment.reserve()
                if reservation == nil {
                    await Task.yield()
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            let claimed = try XCTUnwrap(
                reservation,
                "a prior seal fault leaked its managed writer reservation"
            )
            let writes = LockedCount()
            let writer = WAVWriter(
                url: directory.appending(path: "fault-\(index).wav"),
                dataWriter: { handle, data in
                    writes.increment()
                    if writes.value == 2 { throw InjectedFailure.seal }
                    try handle.write(contentsOf: data)
                }
            )
            try writer.open()
            let managed = ManagedRecordingWriter(
                writer: writer,
                reservation: claimed,
                containment: containment
            )
            let disk = RecordingDiskState(writer: writer) { _ in }
            let sink = FrameSink()
            let enqueue = sink.start { disk.append($0) }
            enqueue([0.1])
            let recording = finalizeCapturedRecording(
                url: writer.fileURL,
                writer: writer,
                managedWriter: managed,
                disk: disk,
                sink: sink,
                frozen: FrozenPCM(
                    samples: [0.1],
                    totalSamples: 1,
                    firstFrameAt: .now
                ),
                sampleRate: 16_000
            )
            await XCTAssertThrowsErrorAsync(try await recording.readableURL())
        }

        var afterFaults: RecordingWriterCloseReservation?
        for _ in 0..<200 where afterFaults == nil {
            afterFaults = containment.reserve()
            if afterFaults == nil {
                await Task.yield()
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        containment.release(
            try XCTUnwrap(
                afterFaults,
                "two seal faults must not permanently force later capture to memory-only"
            )
        )
    }

    func testFinalizedCaptureCarriesItsOwnStartupLatencySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "capture-latency-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "take.wav")
        let writer = WAVWriter(url: url)
        try writer.open()
        let disk = RecordingDiskState(writer: writer) { _ in }
        let sink = FrameSink()
        _ = sink.start { disk.append($0) }
        let recording = finalizeCapturedRecording(
            url: url,
            writer: writer,
            disk: disk,
            sink: sink,
            frozen: FrozenPCM(samples: [0.1], totalSamples: 1, firstFrameAt: .now),
            sampleRate: 16_000,
            startupLatency: .milliseconds(130)
        )

        XCTAssertEqual(recording.startupLatency, .milliseconds(130))
        _ = try await recording.durableURL()
    }

    func testMemoryOnlyCaptureRecognizesImmediatelyAndBuildsRecoveryLazily() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-only-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recording = finalizeMemoryOnlyCapturedRecording(
            url: directory.appending(path: "unopened-take.wav"),
            frozen: FrozenPCM(
                samples: [0.1, 0.2, 0.3],
                totalSamples: 3,
                firstFrameAt: .now
            ),
            sampleRate: 16_000,
            startupLatency: .milliseconds(42)
        )

        XCTAssertEqual(recording.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(recording.startupLatency, .milliseconds(42))
        await XCTAssertThrowsErrorAsync(try await recording.readableURL())
        let optionalRecoveryURL = try await recording.materializedRecoveryURL()
        let recoveryURL = try XCTUnwrap(optionalRecoveryURL)
        XCTAssertEqual(try AVAudioFile(forReading: recoveryURL).length, 3)
    }

    func testMemoryRecoveryPublishesOnlyAtomicFinalAfterCompleteSeal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-atomic-publish-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payloadEntered = DispatchSemaphore(value: 0)
        let releasePayload = DispatchSemaphore(value: 0)
        let writes = LockedCount()
        var released = false
        defer {
            if !released { releasePayload.signal() }
        }
        let recovery = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed.wav"),
            samples: [0.1, 0.2, 0.3],
            sampleRate: 16_000,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    dataWriter: { handle, data in
                        writes.increment()
                        if writes.value == 1 {
                            payloadEntered.signal()
                            releasePayload.wait()
                        }
                        try handle.write(contentsOf: data)
                    }
                )
            }
        )
        let materializing = Task { try await recovery.materialize() }
        XCTAssertEqual(payloadEntered.wait(timeout: .now() + 1), .success)

        let whileWriting = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(whileWriting.contains { $0.pathExtension == "partial" })
        XCTAssertFalse(
            whileWriting.contains { $0.pathExtension.lowercased() == "wav" },
            "launch repair must never see a prefix as a publishable WAV"
        )

        releasePayload.signal()
        released = true
        let finalURL = try await materializing.value
        XCTAssertEqual(finalURL.pathExtension, "wav")
        XCTAssertEqual(try AVAudioFile(forReading: finalURL).length, 3)
        let afterPublish = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(afterPublish.contains { $0.pathExtension == "partial" })
    }

    func testDispositionDeletesLateMemoryMaterializationBeforePublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-disposition-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let disposition = RecordingDisposition()
        let payloadEntered = DispatchSemaphore(value: 0)
        let releasePayload = DispatchSemaphore(value: 0)
        let writes = LockedCount()
        var released = false
        defer {
            if !released { releasePayload.signal() }
        }
        let recovery = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed.wav"),
            samples: [0.1, 0.2, 0.3],
            sampleRate: 16_000,
            disposition: disposition,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    dataWriter: { handle, data in
                        writes.increment()
                        if writes.value == 1 {
                            payloadEntered.signal()
                            releasePayload.wait()
                        }
                        try handle.write(contentsOf: data)
                    }
                )
            },
            disposer: { url in try? FileManager.default.removeItem(at: url) }
        )

        let materializing = Task { try await recovery.materialize() }
        XCTAssertEqual(payloadEntered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).contains { $0.pathExtension == "partial" }
        )

        XCTAssertTrue(disposition.requestDelete())
        releasePayload.signal()
        released = true
        await XCTAssertThrowsErrorAsync(try await materializing.value)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(leftovers.contains { $0.pathExtension == "partial" })
        XCTAssertFalse(
            leftovers.contains { $0.pathExtension.lowercased() == "wav" },
            "a delete intent registered before I/O must own every late output name"
        )
    }

    func testMemoryRecoveryFaultDisposesOnlyNonPromotablePartial() async throws {
        enum InjectedFailure: Error { case prefix }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-partial-fault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let disposed = LockedURLs()
        let recovery = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed.wav"),
            samples: [0.1, 0.2],
            sampleRate: 16_000,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    dataWriter: { handle, data in
                        try handle.write(contentsOf: data.prefix(1))
                        throw InjectedFailure.prefix
                    }
                )
            },
            disposer: { url in
                disposed.append(url)
                try? FileManager.default.removeItem(at: url)
            }
        )

        await XCTAssertThrowsErrorAsync(try await recovery.materialize())
        XCTAssertEqual(disposed.values.count, 1)
        XCTAssertEqual(disposed.values.first?.pathExtension, "partial")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(leftovers.contains { $0.pathExtension.lowercased() == "wav" })
        XCTAssertFalse(leftovers.contains { $0.pathExtension == "partial" })
    }

    func testMemoryRecoveryIsSingleFlightAndSynchronizesExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-single-flight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let synchronizations = LockedCount()
        let recovery = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed.wav"),
            samples: [0.1, 0.2, 0.3],
            sampleRate: 16_000,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    synchronizer: { handle in
                        synchronizations.increment()
                        try handle.synchronize()
                    }
                )
            }
        )

        async let firstCall = recovery.materialize()
        async let secondCall = recovery.materialize()
        let firstURL = try await firstCall
        let secondURL = try await secondCall
        XCTAssertEqual(firstURL, secondURL)
        XCTAssertEqual(synchronizations.value, 1)
        XCTAssertEqual(try AVAudioFile(forReading: firstURL).length, 3)
    }

    func testMemoryRecoveryWriteFaultReleasesGlobalWriteSlot() async throws {
        enum InjectedFailure: Error { case write }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-write-fault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let failing = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed.wav"),
            samples: [0.1],
            sampleRate: 16_000,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    dataWriter: { _, _ in throw InjectedFailure.write }
                )
            }
        )
        await XCTAssertThrowsErrorAsync(try await failing.materialize())

        let succeeding = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "next.wav"),
            samples: [0.2],
            sampleRate: 16_000
        )
        let recovered = try await withTranscriptionDeadline(.milliseconds(250)) {
            try await succeeding.materialize()
        }
        XCTAssertEqual(try AVAudioFile(forReading: recovered).length, 1)
    }

    func testMemoryRecoverySyncFaultRetainsReadableFinalAndReleasesDurabilitySlot() async throws {
        enum InjectedFailure: Error { case sync }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "memory-sync-fault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let failing = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed.wav"),
            samples: [0.1],
            sampleRate: 16_000,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    synchronizer: { _ in throw InjectedFailure.sync }
                )
            }
        )
        await XCTAssertThrowsErrorAsync(try await failing.materialize())
        let retainedFinals = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "wav" }
        XCTAssertEqual(retainedFinals.count, 1)
        XCTAssertEqual(
            try AVAudioFile(forReading: try XCTUnwrap(retainedFinals.first)).length,
            1,
            "a post-publication durability error must not delete readable recovery audio"
        )

        let succeeding = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "next.wav"),
            samples: [0.2],
            sampleRate: 16_000
        )
        let recovered = try await withTranscriptionDeadline(.milliseconds(250)) {
            try await succeeding.materialize()
        }
        XCTAssertEqual(try AVAudioFile(forReading: recovered).length, 1)
    }

    func testDurabilityBacklogIsBoundedWhenOneFsyncStalls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "durability-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var didRelease = false
        defer {
            if !didRelease { release.signal() }
        }

        let firstURL = directory.appending(path: "first.wav")
        let firstWriter = WAVWriter(url: firstURL, synchronizer: { handle in
            entered.signal()
            release.wait()
            try handle.synchronize()
        })
        try firstWriter.open()
        try firstWriter.append([0.1, 0.2])
        let firstDisk = RecordingDiskState(writer: firstWriter) { _ in }
        let firstSink = FrameSink()
        _ = firstSink.start { firstDisk.append($0) }
        let first = finalizeCapturedRecording(
            url: firstURL,
            writer: firstWriter,
            disk: firstDisk,
            sink: firstSink,
            frozen: FrozenPCM(samples: [0.1, 0.2], totalSamples: 2, firstFrameAt: .now),
            sampleRate: 16_000
        )
        _ = try await first.readableURL()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try FileManager.default.removeItem(at: firstURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))

        let secondSyncs = LockedCount()
        let secondURL = directory.appending(path: "second.wav")
        let secondWriter = WAVWriter(url: secondURL, synchronizer: { handle in
            secondSyncs.increment()
            try handle.synchronize()
        })
        try secondWriter.open()
        try secondWriter.append([0.3, 0.4])
        let secondDisk = RecordingDiskState(writer: secondWriter) { _ in }
        let secondSink = FrameSink()
        _ = secondSink.start { secondDisk.append($0) }
        let second = finalizeCapturedRecording(
            url: secondURL,
            writer: secondWriter,
            disk: secondDisk,
            sink: secondSink,
            frozen: FrozenPCM(samples: [0.3, 0.4], totalSamples: 2, firstFrameAt: .now),
            sampleRate: 16_000
        )

        _ = try await second.readableURL()
        await XCTAssertThrowsErrorAsync(try await second.durableURL())
        XCTAssertEqual(secondSyncs.value, 0, "a stuck fsync must not create a second stuck task")
        XCTAssertThrowsError(try secondWriter.append([0.5])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
        XCTAssertEqual(try AVAudioFile(forReading: secondURL).length, 2)

        let recoverySyncs = LockedCount()
        let recovery = MemoryRecoveryWAV(
            originalURL: directory.appending(path: "failed-live-take.wav"),
            samples: [0.6, 0.7, 0.8],
            sampleRate: 16_000,
            writerFactory: { url, sampleRate in
                WAVWriter(
                    url: url,
                    sampleRate: sampleRate,
                    synchronizer: { handle in
                        recoverySyncs.increment()
                        try handle.synchronize()
                    }
                )
            }
        )
        let recoveryCallOne = Task { try await recovery.materialize() }
        let recoveryCallTwo = Task { try await recovery.materialize() }
        let recoveryURL = try await withTranscriptionDeadline(.milliseconds(250)) {
            try await recoveryCallOne.value
        }
        let repeatedRecoveryURL = try await recoveryCallTwo.value
        XCTAssertEqual(recoveryURL, repeatedRecoveryURL)
        XCTAssertEqual(
            recoverySyncs.value,
            0,
            "memory recovery must not start a second fsync while durability is occupied"
        )
        XCTAssertEqual(
            try AVAudioFile(forReading: recoveryURL).length,
            3,
            "the unsynchronized recovery must still have a sealed readable header"
        )

        release.signal()
        didRelease = true
        _ = try await first.durableURL()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstURL.path),
            "finishing fsync on an unlinked success-path file must not recreate it"
        )
    }

    func testDiskWriteBacklogIsBoundedWhenOneKernelWriteStalls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "write-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var didRelease = false
        defer {
            if !didRelease { release.signal() }
        }

        let firstWriter = WAVWriter(
            url: directory.appending(path: "first.wav"),
            dataWriter: { handle, data in
                entered.signal()
                release.wait()
                try handle.write(contentsOf: data)
            }
        )
        try firstWriter.open()
        let firstDisk = RecordingDiskState(writer: firstWriter) { _ in }
        let blockedWrite = Task.detached { firstDisk.append([0.1, 0.2]) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        let secondWriter = WAVWriter(url: directory.appending(path: "second.wav"))
        try secondWriter.open()
        let secondDisk = RecordingDiskState(writer: secondWriter) { _ in }
        secondDisk.append([0.3, 0.4])

        XCTAssertNotNil(secondDisk.recordedFailure)
        XCTAssertEqual(secondWriter.duration, 0)
        secondWriter.abandonForRecovery()

        release.signal()
        didRelease = true
        await blockedWrite.value
        XCTAssertEqual(firstWriter.duration, 2.0 / 16_000, accuracy: 0.0001)
        firstWriter.abandonForRecovery()
    }

    func testHeaderWriteBacklogIsBoundedWhenOneSealStalls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "seal-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var didRelease = false
        defer {
            if !didRelease { release.signal() }
        }

        let firstURL = directory.appending(path: "first.wav")
        let firstWriter = WAVWriter(url: firstURL, dataWriter: { handle, data in
            entered.signal()
            release.wait()
            try handle.write(contentsOf: data)
        })
        try firstWriter.open()
        let firstDisk = RecordingDiskState(writer: firstWriter) { _ in }
        let firstSink = FrameSink()
        _ = firstSink.start { firstDisk.append($0) }
        let first = finalizeCapturedRecording(
            url: firstURL,
            writer: firstWriter,
            disk: firstDisk,
            sink: firstSink,
            frozen: FrozenPCM(samples: [0.1], totalSamples: 1, firstFrameAt: .now),
            sampleRate: 16_000
        )
        let firstReadable = Task { try await first.readableURL() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        let secondURL = directory.appending(path: "second.wav")
        let secondWriter = WAVWriter(url: secondURL)
        try secondWriter.open()
        let secondDisk = RecordingDiskState(writer: secondWriter) { _ in }
        let secondSink = FrameSink()
        _ = secondSink.start { secondDisk.append($0) }
        let second = finalizeCapturedRecording(
            url: secondURL,
            writer: secondWriter,
            disk: secondDisk,
            sink: secondSink,
            frozen: FrozenPCM(samples: [0.2], totalSamples: 1, firstFrameAt: .now),
            sampleRate: 16_000
        )

        do {
            _ = try await withTranscriptionDeadline(.milliseconds(100)) {
                try await second.readableURL()
            }
            XCTFail("the second seal should fail while the one storage slot is occupied")
        } catch is TranscriptionTimeout {
            XCTFail("the second seal must fail promptly, not consume the UI deadline")
        } catch {
            // Expected storage-busy failure.
        }
        XCTAssertThrowsError(try secondWriter.append([0.3])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }

        release.signal()
        didRelease = true
        _ = try await firstReadable.value
        _ = try await first.durableURL()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}

/// Carries one value out of a synchronous callback without tripping Sendable.
final class UnsafeMutableTransferBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

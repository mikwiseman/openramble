import Foundation
import Testing

@testable import AgentBridge

@Suite("Background transcription scheduler")
struct BackgroundSchedulerTests {
    @Test("Background jobs are FIFO and never overlap")
    func fifo() async throws {
        let reservation = InteractiveReservation()
        let scheduler = BackgroundScheduler<Int>(maximumQueued: 4, reservation: reservation)
        let probe = SchedulerProbe()
        scheduler.beginInteractiveWork()

        let first = Task { try await scheduler.submit { await probe.run(value: 1) }.output }
        for _ in 0..<100 where await scheduler.queuedCount < 1 { await Task.yield() }
        let second = Task { try await scheduler.submit { await probe.run(value: 2) }.output }
        for _ in 0..<100 where await scheduler.queuedCount < 2 { await Task.yield() }
        let third = Task { try await scheduler.submit { await probe.run(value: 3) }.output }
        for _ in 0..<100 where await scheduler.queuedCount < 3 { await Task.yield() }
        scheduler.endInteractiveWork()
        let values = try await [first.value, second.value, third.value]

        #expect(values == [1, 2, 3])
        #expect(await probe.maximumConcurrency == 1)
        #expect(await probe.started == [1, 2, 3])
    }

    @Test("Interactive reservation pauses queued work synchronously")
    func reservation() async throws {
        let reservation = InteractiveReservation()
        let scheduler = BackgroundScheduler<Int>(maximumQueued: 2, reservation: reservation)
        scheduler.beginInteractiveWork()
        #expect(reservation.isReserved)

        let work = Task { try await scheduler.submit { 7 }.output }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await scheduler.queuedCount == 1)

        scheduler.endInteractiveWork()
        #expect(try await work.value == 7)
    }

    @Test("Interactive work preempts the active job with a retryable reason")
    func preemption() async throws {
        let reservation = InteractiveReservation()
        let scheduler = BackgroundScheduler<Int>(maximumQueued: 2, reservation: reservation)
        let probe = CancellationProbe()
        let work = Task {
            try await scheduler.submit { try await probe.run() }.output
        }
        await probe.waitUntilStarted()

        scheduler.beginInteractiveWork()

        await #expect(throws: BackgroundSchedulerError.preemptedByInteractiveWork) {
            try await work.value
        }
    }

    @Test("Interactive work waits until a cancellation-resistant job releases the engine")
    func waitsForDrain() async throws {
        let reservation = InteractiveReservation()
        let scheduler = BackgroundScheduler<Int>(maximumQueued: 2, reservation: reservation)
        let probe = DrainProbe()
        let work = Task {
            try await scheduler.submit { await probe.run() }.output
        }
        await probe.waitUntilStarted()

        scheduler.beginInteractiveWork()
        let waiter = Task {
            try await scheduler.waitUntilInteractiveReady()
            await probe.markInteractiveReady()
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(await probe.interactiveWasReady == false)

        await probe.release()
        try await waiter.value
        #expect(await probe.interactiveWasReady)
        await #expect(throws: BackgroundSchedulerError.preemptedByInteractiveWork) {
            try await work.value
        }
    }

    @Test("Client cancellation remains CancellationError")
    func cancellation() async throws {
        let reservation = InteractiveReservation()
        let scheduler = BackgroundScheduler<Int>(maximumQueued: 2, reservation: reservation)
        let probe = CancellationProbe()
        let work = Task {
            try await scheduler.submit { try await probe.run() }.output
        }
        await probe.waitUntilStarted()
        work.cancel()

        await #expect(throws: CancellationError.self) {
            try await work.value
        }
    }

    @Test("Queue admission is bounded")
    func backpressure() async throws {
        let reservation = InteractiveReservation()
        reservation.begin()
        let scheduler = BackgroundScheduler<Int>(maximumQueued: 1, reservation: reservation)
        let first = Task { try await scheduler.submit { 1 }.output }
        for _ in 0..<100 where await scheduler.queuedCount == 0 { await Task.yield() }

        await #expect(throws: BackgroundSchedulerError.queueFull(maximum: 1)) {
            try await scheduler.submit { 2 }.output
        }

        first.cancel()
        _ = try? await first.value
    }
}

private actor SchedulerProbe {
    private(set) var started: [Int] = []
    private var concurrency = 0
    private(set) var maximumConcurrency = 0

    func run(value: Int) async -> Int {
        started.append(value)
        concurrency += 1
        maximumConcurrency = max(maximumConcurrency, concurrency)
        await Task.yield()
        concurrency -= 1
        return value
    }
}

private actor CancellationProbe {
    private var started = false

    func run() async throws -> Int {
        started = true
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private actor DrainProbe {
    private var started = false
    private var released = false
    private(set) var interactiveWasReady = false

    func run() async -> Int {
        started = true
        while !released { await Task.yield() }
        return 1
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() { released = true }
    func markInteractiveReady() { interactiveWasReady = true }
}

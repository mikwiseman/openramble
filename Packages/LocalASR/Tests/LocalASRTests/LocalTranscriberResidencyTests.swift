import DictationCore
import XCTest
@testable import LocalASR

/// The engine lifecycle under concurrency: loads are single-flight, unloads
/// never interleave with work, and a discarded generation cannot resurrect.
///
/// Two callers race in production: the press-time warm-up and the transcribe
/// closure's own prepare. Without coalescing they start two 16-second model
/// loads — doubling the memory spike on exactly the machine whose memory
/// pressure caused the unload in the first place.
final class LocalTranscriberResidencyTests: XCTestCase {
    /// An engine whose load waits at a gate until the test releases it.
    private actor GatedEngine: ASREngineAdapting {
        private(set) var loadCount = 0
        private(set) var unloadCount = 0
        private var loaded = false
        private var gate: CheckedContinuation<Void, Never>?
        private var gateOpen = false
        private var shouldFail = false

        func setShouldFail(_ value: Bool) { shouldFail = value }

        func openGate() {
            gateOpen = true
            gate?.resume()
            gate = nil
        }

        func closeGate() { gateOpen = false }

        func loadModels(from directory: URL) async throws {
            loadCount += 1
            if !gateOpen {
                await withCheckedContinuation { continuation in
                    if gateOpen {
                        continuation.resume()
                    } else {
                        gate = continuation
                    }
                }
            }
            if shouldFail { throw ASREngineError.modelsUnavailable("gated failure") }
            loaded = true
        }

        func transcribe(samples: [Float]) async throws -> ASRResult {
            guard loaded else { throw ASREngineError.modelsNotLoaded }
            return ASRResult(text: "ok", audioDuration: 1, processingDuration: 0.1)
        }

        func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
            try await transcribe(samples: samples)
        }

        func unload() async {
            unloadCount += 1
            loaded = false
        }
    }

    private let directory = URL(fileURLWithPath: "/tmp/residency-model")

    private func settle(_ iterations: Int = 20) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Two concurrent prepares — one load.
    func testConcurrentPreparesCoalesceIntoOneLoad() async throws {
        let engine = GatedEngine()
        let transcriber = LocalTranscriber(engine: engine)
        let directory = self.directory

        let first = Task { try await transcriber.prepare(modelDirectory: directory) }
        let second = Task { try await transcriber.prepare(modelDirectory: directory) }
        await settle()
        await engine.openGate()
        try await first.value
        try await second.value

        let loads = await engine.loadCount
        XCTAssertEqual(loads, 1, "the second caller must ride the in-flight load")
        let prepared = await transcriber.isPrepared
        XCTAssertTrue(prepared)
    }

    /// A failed load reports to every waiter and does not poison retries.
    func testFailedLoadPropagatesAndRetryLoadsAgain() async throws {
        let engine = GatedEngine()
        await engine.setShouldFail(true)
        await engine.openGate()
        let transcriber = LocalTranscriber(engine: engine)

        await XCTAssertThrowsErrorAsync(try await transcriber.prepare(modelDirectory: directory))
        let preparedAfterFailure = await transcriber.isPrepared
        XCTAssertFalse(preparedAfterFailure)

        await engine.setShouldFail(false)
        try await transcriber.prepare(modelDirectory: directory)
        let loads = await engine.loadCount
        XCTAssertEqual(loads, 2, "a failed load must clear the in-flight slot")
        let prepared = await transcriber.isPrepared
        XCTAssertTrue(prepared)
    }

    /// A forced unload during a load wins: the finishing load is discarded,
    /// its caller sees cancellation, and the engine holds nothing.
    func testForcedUnloadDuringLoadDiscardsTheStaleGeneration() async throws {
        let engine = GatedEngine()
        let transcriber = LocalTranscriber(engine: engine)
        let directory = self.directory

        let load = Task { try await transcriber.prepare(modelDirectory: directory) }
        await settle()
        await transcriber.unload()
        await engine.openGate()

        let result = await load.result
        if case .success = result {
            XCTFail("a load overtaken by unload must not report success")
        }
        let prepared = await transcriber.isPrepared
        XCTAssertFalse(prepared, "the stale generation must not resurrect the engine")
        let unloads = await engine.unloadCount
        XCTAssertGreaterThanOrEqual(unloads, 1, "the orphaned load's weights must be released")
    }

    /// Residency's polite unload refuses while work is in flight; the forced
    /// one (wedge recovery) still goes through.
    func testUnloadIfIdleRefusesDuringLoad() async throws {
        let engine = GatedEngine()
        let transcriber = LocalTranscriber(engine: engine)
        let directory = self.directory

        let load = Task { try await transcriber.prepare(modelDirectory: directory) }
        await settle()
        let unloaded = await transcriber.unloadIfIdle()
        XCTAssertFalse(unloaded, "a polite unload must never interleave with a load")

        await engine.openGate()
        try await load.value
        let unloadedAfter = await transcriber.unloadIfIdle()
        XCTAssertTrue(unloadedAfter, "idle after load — the polite unload proceeds")
        let prepared = await transcriber.isPrepared
        XCTAssertFalse(prepared)
    }
}

/// XCTAssertThrowsError for async expressions.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}

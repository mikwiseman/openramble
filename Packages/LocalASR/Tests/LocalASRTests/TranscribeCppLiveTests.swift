import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

/// The engine against a real model, on real audio.
///
/// Skipped unless a model directory is provided, because the weights are 740 MB
/// and are not committed. Point it at a prepared revision to run:
///
/// ```
/// OPENRAMBLE_TEST_MODEL_DIR=/path/to/revision \
/// OPENRAMBLE_TEST_AUDIO=/path/to/take.wav \
///   swift test --package-path Packages/LocalASR --filter TranscribeCppLiveTests
/// ```
///
/// A skipped test is not a passing one. This is the only check that proves the
/// runtime loads, uses the platform's backend, and returns words; everything else in the
/// suite proves the code around it.
final class TranscribeCppLiveTests: XCTestCase {
    /// Intel runs the encoder on the CPU too. Check the text before changing
    /// its thread count; these timings under Rosetta are not Intel benchmarks.
    func testCPUThreadCountsPreserveRecognition() async throws {
        let samples = try audioSamples()
        let directory = try modelDirectory()
        var reference: String?
        for threads: Int32 in [1, 4] {
            let adapter = TranscribeCppAdapter(backend: .cpu, threadCount: threads)
            try await adapter.loadModels(from: directory)
            try await adapter.warmUpInference()
            for _ in 0..<3 {
                let result = try await adapter.transcribe(samples: samples)
                XCTAssertFalse(result.text.isEmpty)
                if let reference {
                    XCTAssertEqual(result.text, reference)
                } else {
                    reference = result.text
                }
                print("[cpu] threads=\(threads) duration=\(result.processingDuration)")
            }
            await adapter.unload()
        }
    }

    func testCancellationDiscardsNativeResultAndNextRequestStillWorks() async throws {
        let samples = try audioSamples()
        guard samples.count >= 60 * 16_000 else {
            throw XCTSkip("use at least a minute of speech for cancellation")
        }
        let adapter = TranscribeCppAdapter()
        try await adapter.loadModels(from: try modelDirectory())
        try await adapter.warmUpInference()
        let started = ContinuousClock.now
        let work = Task { try await adapter.transcribe(samples: samples) }
        try await Task.sleep(for: .milliseconds(100))
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("cancelled native work returned a stale transcript")
        } catch ASREngineError.cancelled {
        } catch is CancellationError {
        }
        let elapsed = started.duration(to: .now)
        print("[cancellation] elapsed=\(elapsed)")
        let next = try await adapter.transcribe(samples: Array(samples.prefix(10 * 16_000)))
        XCTAssertFalse(next.text.isEmpty, "cancellation poisoned the next request")
        await adapter.unload()
    }

    private func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_TEST_MODEL_DIR"],
              !path.isEmpty
        else {
            throw XCTSkip("set OPENRAMBLE_TEST_MODEL_DIR to run the live engine tests")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func audioSamples() throws -> [Float] {
        guard let path = ProcessInfo.processInfo.environment["OPENRAMBLE_TEST_AUDIO"],
              !path.isEmpty
        else {
            throw XCTSkip("set OPENRAMBLE_TEST_AUDIO to run the live engine tests")
        }
        return try AudioFileReader().samples(from: URL(fileURLWithPath: path))
    }

    /// Opt-in pressure gate for the shipping default. Run it while
    /// `asr-load-repro.sh ... cpu` is active; it must fail if the default
    /// silently returns to the runtime's eight spin-polling threads.
    func testDefaultThreadCountResistsCPUPressure() async throws {
        guard ProcessInfo.processInfo.environment["OPENRAMBLE_PRESSURE_GATE"] == "1" else {
            throw XCTSkip("set OPENRAMBLE_PRESSURE_GATE=1 and apply CPU pressure")
        }
        let samples = try audioSamples()
        let directory = try modelDirectory()
        let shipping = TranscribeCppAdapter()
        let eight = TranscribeCppAdapter(threadCount: 8)
        try await shipping.loadModels(from: directory)
        try await eight.loadModels(from: directory)
        try await shipping.warmUpInference()
        try await eight.warmUpInference()

        var shippingTimes: [Double] = []
        var eightTimes: [Double] = []
        for index in 0..<5 {
            if index.isMultiple(of: 2) {
                shippingTimes.append(try await shipping.transcribe(samples: samples).processingDuration)
                eightTimes.append(try await eight.transcribe(samples: samples).processingDuration)
            } else {
                eightTimes.append(try await eight.transcribe(samples: samples).processingDuration)
                shippingTimes.append(try await shipping.transcribe(samples: samples).processingDuration)
            }
        }
        print("[pressure-gate] shipping=\(shippingTimes) eight=\(eightTimes)")
        XCTAssertLessThan(
            try XCTUnwrap(shippingTimes.max()),
            try XCTUnwrap(eightTimes.min()),
            "the shipping topology must stay completely separated from eight threads under pressure"
        )
    }

    /// The whole point, in one test: a model loads, runs, and produces words.
    func testItLoadsAndTranscribesRealAudio() async throws {
        let adapter = TranscribeCppAdapter()
        let samples = try audioSamples()

        try await adapter.loadModels(from: try modelDirectory())
        let loaded = await adapter.isLoaded
        XCTAssertTrue(loaded)

        // The upstream Intel slice is CPU-only. Apple Silicon must keep Metal;
        // a successful load on the wrong backend is not a passing test.
        let backend = await adapter.activeBackend
        #if arch(x86_64)
        XCTAssertEqual(backend?.lowercased(), "cpu")
        #else
        XCTAssertTrue(
            backend?.lowercased().hasPrefix("mtl") == true,
            "the engine must run on Metal, got \(backend ?? "nothing")"
        )
        #endif

        try await adapter.warmUpInference()

        let result = try await adapter.transcribe(samples: samples)
        XCTAssertFalse(
            result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the engine returned no text"
        )
        XCTAssertGreaterThan(result.audioDuration, 0)
        XCTAssertGreaterThan(result.processingDuration, 0)
        print("[live] backend=\(backend ?? "?") rtf=\(result.processingDuration / result.audioDuration)")
        print("[live] text=\(result.text)")

        await adapter.unload()
        let unloaded = await adapter.isLoaded
        XCTAssertFalse(unloaded)
    }

    /// Repeated load/unload cycles must not leak or abort.
    ///
    /// This is the shape that killed an earlier experiment with a related
    /// runtime: teardown on an unlucky path hit a Metal residency-set
    /// destructor assertion and took the process down. Cycling here is cheap
    /// insurance against shipping that.
    func testRepeatedLoadAndUnloadCyclesSurvive() async throws {
        let directory = try modelDirectory()
        let adapter = TranscribeCppAdapter()
        for _ in 0..<3 {
            try await adapter.loadModels(from: directory)
            let loaded = await adapter.isLoaded
            XCTAssertTrue(loaded)
            await adapter.unload()
        }
    }

    /// The same audio must produce the same text. A recognizer that drifts
    /// between identical runs cannot be debugged by anyone.
    func testTheSameAudioProducesTheSameText() async throws {
        let adapter = TranscribeCppAdapter()
        let samples = try audioSamples()
        try await adapter.loadModels(from: try modelDirectory())
        try await adapter.warmUpInference()

        let first = try await adapter.transcribe(samples: samples)
        let second = try await adapter.transcribe(samples: samples)
        XCTAssertEqual(first.text, second.text)
    }

    /// Queue admission must not masquerade as inference time. Two calls share
    /// one serial engine queue, so the follower waits, but its C runtime work
    /// should still measure like the leader's.
    func testSerialQueueWaitIsSeparateFromEngineProcessing() async throws {
        let adapter = TranscribeCppAdapter()
        let samples = try audioSamples()
        try await adapter.loadModels(from: try modelDirectory())
        try await adapter.warmUpInference()

        let leader = Task { try await adapter.transcribe(samples: samples) }
        try await Task.sleep(for: .milliseconds(5))
        let follower = try await adapter.transcribe(samples: samples)
        let first = try await leader.value

        XCTAssertGreaterThan(
            follower.engineDispatchDuration,
            first.processingDuration / 2,
            "the follower must expose its wait for the serial engine queue"
        )
        XCTAssertEqual(
            follower.processingDuration,
            first.processingDuration,
            accuracy: first.processingDuration * 0.25,
            "queue wait must not inflate the measured C runtime work"
        )
    }

    /// A take far shorter than a second is ordinary — a corrected word, a
    /// "yes". It must be handled, not padded into a full window's worth of work
    /// the way the previous engine did.
    func testAVeryShortTakeIsAccepted() async throws {
        let adapter = TranscribeCppAdapter()
        try await adapter.loadModels(from: try modelDirectory())
        try await adapter.warmUpInference()

        let half = [Float](repeating: 0, count: TranscribeCppAdapter.requiredSampleRate / 2)
        let result = try await adapter.transcribe(samples: half)
        // Silence may legitimately produce nothing; what matters is that it
        // returns rather than throwing or hanging.
        XCTAssertGreaterThan(result.processingDuration, 0)
        print("[live] half-second silence took \(result.processingDuration)s")
    }
}

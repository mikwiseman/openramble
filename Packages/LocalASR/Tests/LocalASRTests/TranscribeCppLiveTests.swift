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
/// runtime loads, runs on Metal, and returns words; everything else in the
/// suite proves the code around it.
final class TranscribeCppLiveTests: XCTestCase {
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

    /// The whole point, in one test: a model loads, runs, and produces words.
    func testItLoadsAndTranscribesRealAudio() async throws {
        let adapter = TranscribeCppAdapter()
        let samples = try audioSamples()

        try await adapter.loadModels(from: try modelDirectory())
        let loaded = await adapter.isLoaded
        XCTAssertTrue(loaded)

        // Pinned, not requested-and-hoped-for. A silent fall back to CPU would
        // be the kind of difference that only shows up as "sometimes it's
        // slow". The runtime names the device rather than the backend family —
        // "MTL0" for the first Metal device — so this checks the family.
        let backend = await adapter.activeBackend
        XCTAssertTrue(
            backend?.lowercased().hasPrefix("mtl") == true,
            "the engine must run on Metal, got \(backend ?? "nothing")"
        )

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

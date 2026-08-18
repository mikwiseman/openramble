import DictationCore
import XCTest
@testable import LocalASR

/// The engine boundary, checked without a model.
///
/// These cover the parts that fail on someone else's Mac at an awkward moment:
/// an install that produced no model file, one that somehow produced two, and
/// recognition attempted before anything is loaded. The live behaviour is
/// covered separately, by a test that needs a real model on disk.
final class TranscribeCppAdapterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "transcribe-cpp-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String) throws {
        try Data("not a real model".utf8)
            .write(to: directory.appending(path: name, directoryHint: .notDirectory))
    }

    // MARK: - Finding the model

    func testTheSingleModelFileIsFound() throws {
        try write("parakeet-tdt-0.6b-v3-Q8_0.gguf")
        try write("README.md")
        let found = try TranscribeCppAdapter.modelFile(in: directory)
        XCTAssertEqual(found.lastPathComponent, "parakeet-tdt-0.6b-v3-Q8_0.gguf")
    }

    /// An install that produced nothing usable must say so, not fail later
    /// inside the runtime with a message nobody can act on.
    func testAnEmptyRevisionIsReportedAsUnavailable() throws {
        try write("README.md")
        XCTAssertThrowsError(try TranscribeCppAdapter.modelFile(in: directory)) { error in
            guard case ASREngineError.modelsUnavailable = error else {
                return XCTFail("expected modelsUnavailable, got \(error)")
            }
        }
    }

    /// Two models in one revision is an installer bug. Picking one arbitrarily
    /// would turn it into a quality complaint months later, from a person whose
    /// dictation quietly ran on the wrong weights.
    func testTwoModelsAreRefusedRatherThanGuessedBetween() throws {
        try write("parakeet-tdt-0.6b-v3-Q8_0.gguf")
        try write("parakeet-tdt-0.6b-v3-Q4_K_M.gguf")
        XCTAssertThrowsError(try TranscribeCppAdapter.modelFile(in: directory)) { error in
            guard case let ASREngineError.modelsUnavailable(message) = error else {
                return XCTFail("expected modelsUnavailable, got \(error)")
            }
            XCTAssertTrue(message.contains("2"), "the message should name the count: \(message)")
        }
    }

    func testAnUnreadableDirectoryIsReportedAsUnavailable() {
        let missing = directory.appending(path: "absent", directoryHint: .isDirectory)
        XCTAssertThrowsError(try TranscribeCppAdapter.modelFile(in: missing)) { error in
            guard case ASREngineError.modelsUnavailable = error else {
                return XCTFail("expected modelsUnavailable, got \(error)")
            }
        }
    }

    // MARK: - Refusing to work without a model

    func testRecognitionBeforeLoadingFailsClosed() async {
        let adapter = TranscribeCppAdapter()
        do {
            _ = try await adapter.transcribe(samples: [Float](repeating: 0, count: 16_000))
            XCTFail("recognition without a model unexpectedly succeeded")
        } catch ASREngineError.modelsNotLoaded {
            // Expected.
        } catch {
            XCTFail("expected modelsNotLoaded, got \(error)")
        }
    }

    func testWarmUpBeforeLoadingFailsClosed() async {
        let adapter = TranscribeCppAdapter()
        do {
            try await adapter.warmUpInference()
            XCTFail("warm-up without a model unexpectedly succeeded")
        } catch ASREngineError.modelsNotLoaded {
            // Expected.
        } catch {
            XCTFail("expected modelsNotLoaded, got \(error)")
        }
    }

    /// An empty buffer is a caller mistake and must be named as one. Handing
    /// zero samples to the runtime is not a recognition failure.
    func testAnEmptyBufferIsRejectedAsAFormatProblem() async {
        let adapter = TranscribeCppAdapter()
        do {
            _ = try await adapter.transcribe(samples: [])
            XCTFail("an empty buffer unexpectedly succeeded")
        } catch ASREngineError.modelsNotLoaded {
            // Also acceptable: nothing is loaded either. The ordering of the
            // two guards is not the contract.
        } catch ASREngineError.unsupportedAudioFormat {
            // Expected once a model is present.
        } catch {
            XCTFail("expected a format or not-loaded error, got \(error)")
        }
    }

    func testUnloadingWithoutLoadingIsHarmless() async {
        let adapter = TranscribeCppAdapter()
        await adapter.unload()
        let loaded = await adapter.isLoaded
        XCTAssertFalse(loaded)
    }
}

import DictationCore
import LocalASR
import XCTest

/// Moving from v3 to Parakeet Ultra without a moment of broken dictation.
///
/// The person who updates keeps dictating with the model already on their Mac.
/// The new model is offered, downloaded on request, and used once it verifies
/// and loads; only then is the old one deleted.
@MainActor
final class ModelUpgradeTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    func testAnUpdatedMacKeepsDictatingWithItsModelAndIsOfferedUltra() async throws {
        try harness.installPreviousModelMarker()
        let state = harness.makeState()

        await state.refreshModelState()

        XCTAssertTrue(state.modelState.isReady, "the model already on disk keeps dictation working")
        XCTAssertEqual(state.upgradeState, .notInstalled, "the new model is offered, not imposed")
        XCTAssertEqual(state.remainingDownloadMegabytes, 486, "the offer names the new model's size")
    }

    func testAFreshMacIsAskedForUltraAndNoUpgradeIsShown() async throws {
        let state = harness.makeState()

        await state.refreshModelState()

        XCTAssertEqual(state.modelState, .notInstalled)
        XCTAssertNil(state.upgradeState)
    }

    func testOnceUltraIsInstalledItServesAndTheOldModelIsDeletedAfterItLoads() async throws {
        try harness.installPreviousModelMarker()
        try harness.installModelMarker()
        let engine = DirectoryRecordingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        await state.refreshModelState()
        for _ in 0..<500 where !state.isEngineReady {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(state.isEngineReady)
        XCTAssertNil(state.upgradeState)
        let loaded = engine.loadedDirectories
        XCTAssertTrue(loaded.allSatisfy { $0.path.contains("parakeet-ultra") }, "only Ultra was loaded: \(loaded)")

        let previous = try harness.previousModelDirectory()
        for _ in 0..<500 where FileManager.default.fileExists(atPath: previous.path) {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path), "the replaced model is removed after Ultra loads")
    }

    func testTheOldModelServesWhileUltraIsOnOfferAndIsKeptUntilThen() async throws {
        try harness.installPreviousModelMarker()
        let engine = DirectoryRecordingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        await state.refreshModelState()
        for _ in 0..<500 where !state.isEngineReady {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(state.isEngineReady)
        let loaded = engine.loadedDirectories
        XCTAssertTrue(loaded.allSatisfy { $0.path.contains("parakeet-tdt-0.6b-v3") }, "v3 serves until Ultra is ready: \(loaded)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try harness.previousModelDirectory().path))
    }

    func testDeletingTheModelRemovesBothCopies() async throws {
        try harness.installPreviousModelMarker()
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        state.deleteModel()
        for _ in 0..<500 where state.modelState != .notInstalled {
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(state.modelState, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try harness.previousModelDirectory().path))
    }

    func testTheUpgradeCardSaysDictationKeepsWorking() {
        let offer = ModelStatus.upgrade(state: .notInstalled, downloadMegabytes: 486)
        XCTAssertEqual(offer.actions, [.install])
        XCTAssertEqual(offer.title(for: .install), "Download Model — 486 MB")

        let failed = ModelStatus.upgrade(state: .failed(.download("offline")), downloadMegabytes: 486)
        XCTAssertEqual(failed.actions, [.retry])
        XCTAssertEqual(failed.tone, .failure)
        XCTAssertTrue(failed.detail?.contains("current model") == true)
    }
}

/// An engine that loads anything and remembers which folders it was given.
final class DirectoryRecordingEngine: ASREngineAdapting, @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [URL] = []

    var loadedDirectories: [URL] { lock.withLock { directories } }

    func loadModels(from directory: URL) async throws {
        lock.withLock { directories.append(directory) }
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        ASRResult(text: "", audioDuration: 1, processingDuration: 0)
    }

    func unload() async {}
}

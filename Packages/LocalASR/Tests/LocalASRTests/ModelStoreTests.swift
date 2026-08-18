import CryptoKit
import XCTest
@testable import LocalASR

/// Fake loader: gives predefined content, counts calls
/// and knows how to fall. The real network is not involved in the tests.
actor FakeDownloader: ModelDownloading {
    private var contents: [String: Data]
    private var contentsByHost: [String: [String: Data]] = [:]
    private var failure: ModelDownloadError?
    private var failuresByHost: [String: ModelDownloadError] = [:]
    /// How many more times this host should fail before it starts working.
    ///
    /// A flaky network is not "the mirror is down", it is "the mirror answers
    /// on the second try". Without this the retry path cannot be tested at all.
    private var transientFailuresByHost: [String: (remaining: Int, error: ModelDownloadError)] = [:]
    private(set) var attemptsByHost: [String: Int] = [:]
    private(set) var requestedPaths: [String] = []
    /// Hosts are in order of access - they show whether it has reached the backup address.
    private(set) var requestedHosts: [String] = []

    init(contents: [String: Data]) {
        self.contents = contents
    }

    func setFailure(_ error: ModelDownloadError?) { failure = error }

    /// Force a specific source to fail: this is how the transition to the next one is checked.
    func setFailure(_ error: ModelDownloadError, forHost host: String) {
        failuresByHost[host] = error
    }

    /// Fail `times` in a row on this host, then behave normally.
    func setTransientFailures(
        _ times: Int,
        error: ModelDownloadError = .network("A TLS error caused the secure connection to fail."),
        forHost host: String
    ) {
        transientFailuresByHost[host] = (remaining: times, error: error)
    }

    /// Slip other content to the source: the amounts are required to catch it regardless
    /// from where the file came from.
    func setContents(_ contents: [String: Data], forHost host: String) {
        contentsByHost[host] = contents
    }

    func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        requestedPaths.append(url.lastPathComponent)
        let host = url.host() ?? ""
        requestedHosts.append(host)
        attemptsByHost[host, default: 0] += 1
        if let failure { throw failure }
        if let hostFailure = failuresByHost[host] { throw hostFailure }
        if var transient = transientFailuresByHost[host], transient.remaining > 0 {
            transient.remaining -= 1
            transientFailuresByHost[host] = transient
            throw transient.error
        }

        // We look for the key at the tail of the address - this way the test does not depend on the form of the link.
        // Both shapes are real: the origin keeps the repository path, while a
        // GitHub release asset cannot contain slashes and arrives flattened.
        let table = contentsByHost[host] ?? contents
        let key = table.keys.first { candidate in
            url.absoluteString.hasSuffix(candidate)
                || url.absoluteString.hasSuffix(
                    candidate.replacingOccurrences(of: "/", with: "__")
                )
        }
        guard let key, let data = table[key] else {
            throw ModelDownloadError.httpStatus(404)
        }

        onProgress(Int64(data.count))
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "fake-\(UUID().uuidString)", directoryHint: .notDirectory)
        try data.write(to: temporary)
        return temporary
    }
}

final class ModelStoreTests: XCTestCase {
    private var root: URL!

    private let fileA = Data("\u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C}\u{043E}\u{0435} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0433}\u{043E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}".utf8)
    private let fileB = Data("\u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C}\u{043E}\u{0435} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0433}\u{043E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}".utf8)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeManifest(corruptChecksumForB: Bool = false) -> ModelManifest {
        ModelManifest(
            modelID: "test-model",
            repository: "acme/test",
            revision: String(repeating: "a", count: 40),
            runtimeVersion: "0.15.5",
            quantization: "test",
            license: "CC-BY-4.0",
            files: [
                .init(path: "Encoder.mlmodelc/weight.bin", byteCount: Int64(fileA.count), sha256: sha256(fileA)),
                .init(
                    path: "vocab.json",
                    byteCount: Int64(fileB.count),
                    sha256: corruptChecksumForB ? String(repeating: "b", count: 64) : sha256(fileB)
                ),
            ]
        )
    }

    private func makeStore(manifest: ModelManifest, downloader: ModelDownloading) -> (ModelStore, ModelInstallLayout) {
        let layout = ModelInstallLayout(root: root, modelID: manifest.modelID, revision: manifest.revision, engineFolderName: "repo")
        let store = ModelStore(manifest: manifest, layout: layout, downloader: downloader)
        return (store, layout)
    }

    func testInstallsAndBecomesReady() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{043E}\u{0441}\u{044C} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}\u{0435} \u{0441}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{0435}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.readyMarker.path))
        // The files are located inside a folder whose name the library loader expects.
        let encoder = layout.engineDirectory.appending(path: "Encoder.mlmodelc/weight.bin")
        XCTAssertEqual(try Data(contentsOf: encoder), fileA)
    }

    func testCorruptedFileLeavesNothingInstalled() async throws {
        // The sum of the second file in the manifest will certainly not add up.
        let manifest = makeManifest(corruptChecksumForB: true)
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} \u{043F}\u{0440}\u{043E}\u{0432}\u{0430}\u{043B} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0438}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        guard case .verification = error else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{043A}\u{0438}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
        }
        // The main thing: there is no half-installed model left.
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    func testNetworkFailureLeavesNoStagingBehind() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(.network("\u{0441}\u{0435}\u{0442}\u{044C} \u{043D}\u{0435}\u{0434}\u{043E}\u{0441}\u{0442}\u{0443}\u{043F}\u{043D}\u{0430}"))
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case .failed = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} \u{043F}\u{0440}\u{043E}\u{0432}\u{0430}\u{043B}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: layout.modelDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            leftovers.allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") },
            "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043F}\u{0440}\u{043E}\u{0432}\u{0430}\u{043B}\u{0430} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043E}\u{0441}\u{0442}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} staging-\u{0434}\u{0438}\u{0440}\u{0435}\u{043A}\u{0442}\u{043E}\u{0440}\u{0438}\u{0439}: \(leftovers)"
        )
    }

    func testRefreshRejectsMarkerFromAnotherRevision() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()

        // Add a label from another revision - the installation should stop
        // be considered suitable, not “probably suitable”.
        let alien = ModelReadyMarker(
            revision: String(repeating: "f", count: 40),
            runtimeVersion: "0.15.5",
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount,
            verifiedAt: Date()
        )
        try JSONEncoder().encode(alien).write(to: layout.readyMarker)

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} repairRequired, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    func testRefreshRequiresReadyMarkerWhenModelDirectoryExists() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        try FileManager.default.removeItem(at: layout.readyMarker)

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} repairRequired, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    func testRefreshRejectsCorruptedReadyMarker() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        try Data("not-json".utf8).write(to: layout.readyMarker)

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} repairRequired, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    func testRefreshRequiresEveryInstalledFile() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        try FileManager.default.removeItem(at: layout.engineDirectory.appending(path: "vocab.json"))

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} repairRequired, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    func testRefreshRejectsHiddenFileOutsideManifestInventory() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        try Data("unexpected".utf8).write(to: layout.engineDirectory.appending(path: ".hidden"))

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("Exact inventory \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043E}\u{0442}\u{0432}\u{0435}\u{0440}\u{0433}\u{0430}\u{0442}\u{044C} hidden-\u{0444}\u{0430}\u{0439}\u{043B}: \(state)")
        }
    }

    /// Finder creates `.DS_Store` when simply browsing a folder. This is trash, not
    /// damage: it is impossible to declare repair and transfer 483 MB because of it.
    func testScenario001() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let dsStore = layout.engineDirectory.appending(path: ".DS_Store")
        try Data([0x00, 0x00, 0x00, 0x01]).write(to: dsStore)

        let state = await store.refreshState()

        guard case .ready = state else {
            return XCTFail("\u{041F}\u{0440}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440} \u{043F}\u{0430}\u{043F}\u{043A}\u{0438} \u{0432} Finder \u{043D}\u{0435} \u{043F}\u{043E}\u{0432}\u{043E}\u{0434} \u{043F}\u{0435}\u{0440}\u{0435}\u{043A}\u{0430}\u{0447}\u{0438}\u{0432}\u{0430}\u{0442}\u{044C} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C}: \(state)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dsStore.path),
            "\u{041C}\u{0443}\u{0441}\u{043E}\u{0440} Finder \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{0443}\u{0431}\u{0440}\u{0430}\u{043D}, \u{0438}\u{043D}\u{0430}\u{0447}\u{0435} \u{043E}\u{043D} \u{0432}\u{0435}\u{0440}\u{043D}\u{0451}\u{0442} repair \u{043F}\u{0440}\u{0438} \u{0441}\u{043B}\u{0435}\u{0434}\u{0443}\u{044E}\u{0449}\u{0435}\u{043C} \u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0435}"
        )
    }

    func testRefreshDetectsSameSizeMutation() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let target = layout.engineDirectory.appending(path: "vocab.json")
        let corrupt = Data(repeating: 0x78, count: fileB.count)
        try corrupt.write(to: target)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: target.path)

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} repairRequired, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    func testRefreshRestoresInterruptedPromotionBackup() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        try FileManager.default.moveItem(at: layout.installedDirectory, to: layout.backupDirectory)

        let state = await store.refreshState()

        XCTAssertTrue(state.isReady)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.readyMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.backupDirectory.path))
    }

    func testEveryPromotionInterruptionRecoversOldOrNewReadyModel() async throws {
        for checkpoint in ModelPromotionCheckpoint.allCases {
            let caseRoot = root.appending(path: String(describing: checkpoint))
            try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
            let manifest = makeManifest()
            let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
            let layout = ModelInstallLayout(
                root: caseRoot,
                modelID: manifest.modelID,
                revision: manifest.revision,
                engineFolderName: "repo"
            )

            let baseline = ModelStore(manifest: manifest, layout: layout, downloader: downloader)
            await baseline.install()
            let baselineState = await baseline.currentState()
            XCTAssertTrue(baselineState.isReady, "baseline \(checkpoint)")

            let interrupted = ModelStore(
                manifest: manifest,
                layout: layout,
                downloader: downloader,
                injectedPromotionFailure: checkpoint
            )
            await interrupted.install()
            let interruptedState = await interrupted.currentState()
            switch checkpoint {
            case .afterBackupRemoval:
                // Past this point the model is installed and marked ready, and
                // only the old copy is left to sweep up. A sweep that fails is
                // not a failed install: reporting it as one skipped the engine
                // warm-up and, on the next launch, offered redownloading 483 MB
                // as the sole remedy for a model that was already working.
                XCTAssertTrue(
                    interruptedState.isReady,
                    "housekeeping after the ready marker must not fail the install: \(interruptedState)"
                )
            default:
                guard case .failed = interruptedState else {
                    return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} injected failure \u{043D}\u{0430} \(checkpoint)")
                }
            }

            let relaunched = ModelStore(manifest: manifest, layout: layout, downloader: downloader)
            let recovered = await relaunched.refreshState()
            XCTAssertTrue(recovered.isReady, "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \(checkpoint) \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{0430} \u{0441}\u{0442}\u{0430}\u{0440}\u{0430}\u{044F} \u{043B}\u{0438}\u{0431}\u{043E} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C}: \(recovered)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.backupDirectory.path))
        }
    }

    func testDeleteRemovesEverything() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let installedState = await store.currentState()
        XCTAssertTrue(installedState.isReady)

        await store.delete()

        let finalState = await store.currentState()
        XCTAssertEqual(finalState, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.modelDirectory.path))
    }

    func testInstallIsSkippedWhenAlreadyReady() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()
        let firstRoundRequests = await downloader.requestedPaths.count

        await store.install()
        let secondRoundRequests = await downloader.requestedPaths.count

        XCTAssertEqual(
            secondRoundRequests,
            firstRoundRequests,
            "\u{041F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440}\u{043D}\u{0430}\u{044F} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0430} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}\u{0439} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043D}\u{0438}\u{0447}\u{0435}\u{0433}\u{043E} \u{043A}\u{0430}\u{0447}\u{0430}\u{0442}\u{044C}"
        )
    }

    func testExplicitRepairReinstallsEvenWhenStoreWasReady() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let firstRoundRequests = await downloader.requestedPaths.count

        await store.repair()

        let repairedState = await store.currentState()
        let repairedRequests = await downloader.requestedPaths.count
        XCTAssertTrue(repairedState.isReady)
        XCTAssertEqual(repairedRequests, firstRoundRequests * 2)
    }

    /// Updating FluidAudio should not cost the user to download the model.
    ///
    /// Model revision - the committed SHA of the commit; if it hasn't changed, to
    /// The disk contains exactly the same bytes that the new manifest requests. Previously label
    /// was checked together with the library version, and the dependency patch turned into
    /// “the model is damaged, download 483 MB again” for everyone who updated
    /// application. Now this is a recheck of the amounts on the spot and a rewritten label.
    func testFluidAudioBumpRevalidatesLocallyWithoutDownloading() async throws {
        let installed = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: installed, downloader: downloader)
        await store.install()
        let installedState = await store.currentState()
        XCTAssertTrue(installedState.isReady)
        let requestsAfterInstall = await downloader.requestedPaths.count

        // The library was updated, the weights were not touched: the same revision, the same set
        // files, another version of FluidAudio.
        let bumped = ModelManifest(
            modelID: installed.modelID,
            repository: installed.repository,
            revision: installed.revision,
            runtimeVersion: "0.15.6",
            quantization: installed.quantization,
            license: installed.license,
            files: installed.files
        )
        let upgraded = ModelStore(manifest: bumped, layout: layout, downloader: downloader)

        let state = await upgraded.refreshState()

        XCTAssertTrue(state.isReady, "\u{0426}\u{0435}\u{043B}\u{044B}\u{0435} \u{0444}\u{0430}\u{0439}\u{043B}\u{044B} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0431}\u{0430}\u{043C}\u{043F}\u{0430} \u{0431}\u{0438}\u{0431}\u{043B}\u{0438}\u{043E}\u{0442}\u{0435}\u{043A}\u{0438} — \u{044D}\u{0442}\u{043E} Ready, \u{0430} \u{043D}\u{0435} repair. \u{041F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        let requestsAfterRefresh = await downloader.requestedPaths.count
        XCTAssertEqual(
            requestsAfterRefresh,
            requestsAfterInstall,
            "\u{041D}\u{0438} \u{043E}\u{0434}\u{043D}\u{043E}\u{0433}\u{043E} \u{0431}\u{0430}\u{0439}\u{0442}\u{0430} \u{0438}\u{0437} \u{0441}\u{0435}\u{0442}\u{0438} \u{0441}\u{043A}\u{0430}\u{0447}\u{0430}\u{043D}\u{043E} \u{0431}\u{044B}\u{0442}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E}"
        )
        // The label has been rewritten for the new version - otherwise, complete reconciliation of amounts
        // would be repeated every time the application is launched.
        let marker = try JSONDecoder().decode(
            ModelReadyMarker.self,
            from: Data(contentsOf: layout.readyMarker)
        )
        XCTAssertEqual(marker.runtimeVersion, "0.15.6")
        XCTAssertTrue(marker.matches(bumped))
    }

    /// The other side of the same edit: changing the revision means different weights, and so
    /// here pumping must happen, and not quietly pass for a suitable installation.
    func testDifferentRevisionStillNeedsInstall() async throws {
        let installed = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: installed, downloader: downloader)
        await store.install()

        let newRevision = ModelManifest(
            modelID: installed.modelID,
            repository: installed.repository,
            revision: String(repeating: "c", count: 40),
            runtimeVersion: installed.runtimeVersion,
            quantization: installed.quantization,
            license: installed.license,
            files: installed.files
        )
        let layout = ModelInstallLayout(
            root: root,
            modelID: newRevision.modelID,
            revision: newRevision.revision,
            engineFolderName: "repo"
        )
        let other = ModelStore(manifest: newRevision, layout: layout, downloader: downloader)

        let state = await other.refreshState()

        guard case .notInstalled = state else {
            return XCTFail("\u{0414}\u{0440}\u{0443}\u{0433}\u{0430}\u{044F} \u{0440}\u{0435}\u{0432}\u{0438}\u{0437}\u{0438}\u{044F} — \u{044D}\u{0442}\u{043E} \u{043D}\u{0435} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043B}\u{0435}\u{043D}\u{043D}\u{0430}\u{044F} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    /// Damage remains corruption: a version bump should not turn into
    /// “We won’t check, and it will do.”
    func testFluidAudioBumpStillCatchesDamagedFile() async throws {
        let installed = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: installed, downloader: downloader)
        await store.install()

        // The file has been replaced after installation - the same size, different content.
        let victim = layout.engineDirectory.appending(path: "Encoder.mlmodelc/weight.bin")
        try Data("\u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C}\u{043E}\u{0435} \u{041F}\u{0415}\u{0420}\u{0412}\u{041E}\u{0413}\u{041E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}".utf8).write(to: victim)

        let bumped = ModelManifest(
            modelID: installed.modelID,
            repository: installed.repository,
            revision: installed.revision,
            runtimeVersion: "0.15.6",
            quantization: installed.quantization,
            license: installed.license,
            files: installed.files
        )
        let upgraded = ModelStore(manifest: bumped, layout: layout, downloader: downloader)

        let state = await upgraded.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("\u{041F}\u{043E}\u{0434}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{044B}\u{0439} \u{0444}\u{0430}\u{0439}\u{043B} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0442}\u{0440}\u{0435}\u{0431}\u{043E}\u{0432}\u{0430}\u{0442}\u{044C} \u{0432}\u{043E}\u{0441}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043B}\u{0435}\u{043D}\u{0438}\u{044F}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
    }

    func testProgressIsReportedWhileDownloading() {
        XCTAssertEqual(ModelState.downloading(receivedBytes: 50, totalBytes: 200).progress, 0.25)
        XCTAssertEqual(ModelState.verifying(checked: 1, total: 4).progress, 0.25)
        XCTAssertNil(ModelState.notInstalled.progress)
    }
}

import CryptoKit
import XCTest
@testable import LocalASR

/// Two independent paths to the model: a spare address and import from a ready-made folder.
///
/// The meaning of both is the same: a single source is a single point of failure. If
/// the repository will be deleted or closed for the region, a new user will not start
/// the application in general. The verification of trust does not change one step: the amount
/// SHA-256 from the manifest is considered the same for any origin of the file.
final class ModelSourcesTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    private let fileA = Data("\u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C}\u{043E}\u{0435} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0433}\u{043E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}".utf8)
    private let fileB = Data("\u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C}\u{043E}\u{0435} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0433}\u{043E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}".utf8)
    /// The GitHub release mirror leads because it measured faster; the Hugging
    /// Face origin backs it up. Both serve byte-identical, checksum-verified
    /// files, so the order is only ever a speed choice.
    private let leadingHost = "github.com"
    private let backupHost = "huggingface.co"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sources-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeManifest(
        withMirror: Bool = true,
        corruptChecksumForB: Bool = false,
        pathForB: String = "vocab.json"
    ) -> ModelManifest {
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
                    path: pathForB,
                    byteCount: Int64(fileB.count),
                    sha256: corruptChecksumForB ? String(repeating: "b", count: 64) : sha256(fileB)
                ),
            ],
            mirror: withMirror ? .init(repository: "mikwiseman/openramble", releaseTag: "models-test") : nil
        )
    }

    private func makeStore(
        manifest: ModelManifest,
        downloader: ModelDownloading = FakeDownloader(contents: [:])
    ) -> (ModelStore, ModelInstallLayout) {
        let layout = ModelInstallLayout(
            root: root,
            modelID: manifest.modelID,
            revision: manifest.revision,
            engineFolderName: "repo"
        )
        return (ModelStore(manifest: manifest, layout: layout, downloader: downloader), layout)
    }

    /// Arrange the files as they are provided by the installed model on another machine.
    private func fillSource(manifest: ModelManifest, contents: [String: Data]) throws {
        for file in manifest.files {
            guard let data = contents[file.path] else { continue }
            let url = source.appending(path: file.path, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
    }

    // MARK: - Spare source

    func testManifestBuildsBothAddresses() throws {
        let manifest = makeManifest()
        let file = manifest.files[0]

        let addresses = manifest.downloadURLs(for: file)

        XCTAssertEqual(addresses.count, 2, "\u{0410}\u{0434}\u{0440}\u{0435}\u{0441}\u{043E}\u{0432} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0431}\u{044B}\u{0442}\u{044C} \u{0434}\u{0432}\u{0430}: \u{043E}\u{0441}\u{043D}\u{043E}\u{0432}\u{043D}\u{043E}\u{0439} \u{0438} \u{0437}\u{0430}\u{043F}\u{0430}\u{0441}\u{043D}\u{043E}\u{0439}")
        XCTAssertEqual(addresses[0].host(), leadingHost, "the faster source is tried first")
        XCTAssertEqual(addresses[1].host(), backupHost)
        // GitHub does not allow forward slashes in the attachment name - the path is flattened.
        XCTAssertEqual(addresses[0].lastPathComponent, "Encoder.mlmodelc__weight.bin")
    }

    func testFallsBackToTheOtherSourceWhenTheLeadingOneIsGone() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        // The repository was deleted - exactly the scenario for which all this was done.
        await downloader.setFailure(.httpStatus(404), forHost: leadingHost)
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "\u{0417}\u{0430}\u{043F}\u{0430}\u{0441}\u{043D}\u{043E}\u{0439} \u{0438}\u{0441}\u{0442}\u{043E}\u{0447}\u{043D}\u{0438}\u{043A} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0432}\u{044B}\u{0442}\u{044F}\u{043D}\u{0443}\u{0442}\u{044C} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0443}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        let hosts = await downloader.requestedHosts
        XCTAssertEqual(hosts.first, leadingHost, "the faster source is tried first")
        XCTAssertTrue(hosts.contains(backupHost), "the backup address was never asked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    func testBackupIsNotTouchedWhileTheLeadingSourceWorks() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let hosts = await downloader.requestedHosts
        XCTAssertFalse(hosts.contains(backupHost), "no reason to touch the backup while the lead works")
    }

    func testBothSourcesFailingNamesBoth() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(.httpStatus(404), forHost: backupHost)
        await downloader.setFailure(.network("\u{0445}\u{043E}\u{0441}\u{0442} \u{043D}\u{0435}\u{0434}\u{043E}\u{0441}\u{0442}\u{0443}\u{043F}\u{0435}\u{043D}"), forHost: leadingHost)
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .download(message) = error else {
            return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0441}\u{044F} \u{0432}\u{043D}\u{044F}\u{0442}\u{043D}\u{044B}\u{0439} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437} \u{0437}\u{0430}\u{0433}\u{0440}\u{0443}\u{0437}\u{043A}\u{0438}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        XCTAssertTrue(message.contains(backupHost), "\u{0412} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0435} \u{043D}\u{0435}\u{0442} \u{043E}\u{0441}\u{043D}\u{043E}\u{0432}\u{043D}\u{043E}\u{0433}\u{043E} \u{0438}\u{0441}\u{0442}\u{043E}\u{0447}\u{043D}\u{0438}\u{043A}\u{0430}: \(message)")
        XCTAssertTrue(message.contains(leadingHost), "\u{0412} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0435} \u{043D}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0430}\u{0441}\u{043D}\u{043E}\u{0433}\u{043E} \u{0438}\u{0441}\u{0442}\u{043E}\u{0447}\u{043D}\u{0438}\u{043A}\u{0430}: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    /// Source failure and user failure are two different things. After "cancellation"
    /// sorting through mirrors means downloading half a gigabyte in spite of a direct command.
    func testCancellationDoesNotWalkToTheOtherSource() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        await downloader.setFailure(.cancelled, forHost: leadingHost)
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        XCTAssertEqual(state, .notInstalled, "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} — \u{044D}\u{0442}\u{043E} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430}, \u{0430} \u{043D}\u{0435} \u{043F}\u{0440}\u{043E}\u{0432}\u{0430}\u{043B} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0438}")
        let hosts = await downloader.requestedHosts
        XCTAssertFalse(hosts.contains(backupHost), "cancellation must not walk to the next address")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    /// The backup address does not weaken anything: the file from it is checked by the same
    /// amounts. Otherwise the mirror would become a hole in trust.
    func testMirrorContentIsCheckedByTheSameChecksums() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        await downloader.setFailure(.httpStatus(404), forHost: leadingHost)
        await downloader.setContents(
            ["weight.bin": fileA, "vocab.json": Data("\u{043F}\u{043E}\u{0434}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{043E}\u{0435} \u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{043C}\u{043E}\u{0435}".utf8)],
            forHost: backupHost
        )
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state, case .verification = error else {
            return XCTFail("\u{041F}\u{043E}\u{0434}\u{043C}\u{0435}\u{043D}\u{0430} \u{0438}\u{0437} \u{0437}\u{0435}\u{0440}\u{043A}\u{0430}\u{043B}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043F}\u{0430}\u{0434}\u{0430}\u{0442}\u{044C} \u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{043A}\u{0435}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    func testManifestWithoutMirrorHasSingleAddress() {
        let manifest = makeManifest(withMirror: false)

        XCTAssertEqual(manifest.downloadURLs(for: manifest.files[0]).count, 1)
        XCTAssertNil(manifest.mirrorURL(for: manifest.files[0]))
    }

    func testMalformedMirrorIsRejectedAtDecode() throws {
        let manifest = makeManifest()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as! [String: Any]
        json["mirror"] = ["repository": "\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}\u{0438}\u{043C}\u{044F}", "releaseTag": "models-test"]

        XCTAssertThrowsError(
            try ModelManifest.decode(from: JSONSerialization.data(withJSONObject: json)),
            "\u{041A}\u{0440}\u{0438}\u{0432}\u{043E}\u{0439} \u{0437}\u{0430}\u{043F}\u{0430}\u{0441}\u{043D}\u{043E}\u{0439} \u{0430}\u{0434}\u{0440}\u{0435}\u{0441} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043B}\u{043E}\u{0432}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{043D}\u{0430} \u{0441}\u{0442}\u{0430}\u{0440}\u{0442}\u{0435}, \u{0430} \u{043D}\u{0435} \u{043F}\u{0440}\u{0438} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437}\u{0435} \u{043E}\u{0441}\u{043D}\u{043E}\u{0432}\u{043D}\u{043E}\u{0433}\u{043E}"
        )
    }

    func testBundledManifestHasMirror() throws {
        // The second path to the model must exist in the manifest that
        // actually goes to the user, and not just in the test.
        let manifest = try ModelManifest.bundled()

        let mirror = try XCTUnwrap(manifest.mirror, "\u{0423} \u{0431}\u{043E}\u{0435}\u{0432}\u{043E}\u{0433}\u{043E} \u{043C}\u{0430}\u{043D}\u{0438}\u{0444}\u{0435}\u{0441}\u{0442}\u{0430} \u{043D}\u{0435}\u{0442} \u{0437}\u{0430}\u{043F}\u{0430}\u{0441}\u{043D}\u{043E}\u{0433}\u{043E} \u{0438}\u{0441}\u{0442}\u{043E}\u{0447}\u{043D}\u{0438}\u{043A}\u{0430}")
        XCTAssertEqual(mirror.repository.split(separator: "/").count, 2)
        XCTAssertEqual(manifest.downloadURLs(for: manifest.files[0]).count, 2)
    }

    // MARK: - Import from folder

    func testImportInstallsFromFolder() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: [
            "Encoder.mlmodelc/weight.bin": fileA,
            "vocab.json": fileB,
        ])
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "\u{0418}\u{043C}\u{043F}\u{043E}\u{0440}\u{0442} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}\u{0439} \u{043F}\u{0430}\u{043F}\u{043A}\u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0437}\u{0430}\u{043A}\u{0430}\u{043D}\u{0447}\u{0438}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{043E}\u{0439}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        let installed = layout.engineDirectory.appending(path: "Encoder.mlmodelc/weight.bin")
        XCTAssertEqual(try Data(contentsOf: installed), fileA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    func testImportNeverGoesToTheNetwork() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: [
            "Encoder.mlmodelc/weight.bin": fileA,
            "vocab.json": fileB,
        ])
        let downloader = FakeDownloader(contents: [:])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)

        await store.importModel(from: source)

        let requests = await downloader.requestedPaths
        XCTAssertTrue(requests.isEmpty, "\u{0418}\u{043C}\u{043F}\u{043E}\u{0440}\u{0442} \u{0438}\u{0437} \u{043F}\u{0430}\u{043F}\u{043A}\u{0438} \u{043D}\u{0435} \u{0438}\u{043C}\u{0435}\u{0435}\u{0442} \u{043F}\u{0440}\u{0430}\u{0432}\u{0430} \u{0445}\u{043E}\u{0434}\u{0438}\u{0442}\u{044C} \u{0432} \u{0441}\u{0435}\u{0442}\u{044C}: \(requests)")
    }

    func testImportWithOneBadChecksumInstallsNothing() async throws {
        // The sum of the second file in the manifest will certainly not add up.
        let manifest = makeManifest(corruptChecksumForB: true)
        try fillSource(manifest: manifest, contents: [
            "Encoder.mlmodelc/weight.bin": fileA,
            "vocab.json": fileB,
        ])
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case .verification = error else {
            return XCTFail("\u{041D}\u{0435}\u{0441}\u{043E}\u{0448}\u{0435}\u{0434}\u{0448}\u{0430}\u{044F}\u{0441}\u{044F} \u{0441}\u{0443}\u{043C}\u{043C}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{043D}\u{0430}\u{0432}\u{043B}\u{0438}\u{0432}\u{0430}\u{0442}\u{044C} \u{0438}\u{043C}\u{043F}\u{043E}\u{0440}\u{0442}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.installedDirectory.path),
            "\u{041F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437}\u{0430} \u{0432} \u{0446}\u{0435}\u{043B}\u{0435}\u{0432}\u{043E}\u{0439} \u{043F}\u{0430}\u{043F}\u{043A}\u{0435} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{043E}\u{0441}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043D}\u{0438} \u{043E}\u{0434}\u{043D}\u{043E}\u{0433}\u{043E} \u{0444}\u{0430}\u{0439}\u{043B}\u{0430}"
        )
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: layout.modelDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            leftovers.allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") },
            "\u{041F}\u{0440}\u{043E}\u{043C}\u{0435}\u{0436}\u{0443}\u{0442}\u{043E}\u{0447}\u{043D}\u{0430}\u{044F} \u{043F}\u{0430}\u{043F}\u{043A}\u{0430} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0431}\u{044B}\u{0442}\u{044C} \u{0443}\u{0431}\u{0440}\u{0430}\u{043D}\u{0430}: \(leftovers)"
        )
    }

    func testImportFromFolderMissingAFileFails() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: ["Encoder.mlmodelc/weight.bin": fileA])
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .importSource(message) = error else {
            return XCTFail("\u{041D}\u{0435}\u{043F}\u{043E}\u{043B}\u{043D}\u{0430}\u{044F} \u{043F}\u{0430}\u{043F}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0434}\u{0430}\u{0432}\u{0430}\u{0442}\u{044C} \u{0432}\u{043D}\u{044F}\u{0442}\u{043D}\u{044B}\u{0439} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        XCTAssertTrue(message.contains("vocab.json"), "\u{0412} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0435} \u{043D}\u{0435} \u{043D}\u{0430}\u{0437}\u{0432}\u{0430}\u{043D} \u{043D}\u{0435}\u{0434}\u{043E}\u{0441}\u{0442}\u{0430}\u{044E}\u{0449}\u{0438}\u{0439} \u{0444}\u{0430}\u{0439}\u{043B}: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    func testImportLeavesTheSourceFolderUntouched() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: [
            "Encoder.mlmodelc/weight.bin": fileA,
            "vocab.json": fileB,
        ])
        let (store, _) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        // The folder is foreign: you cannot take files from it, only copy them.
        for file in manifest.files {
            let origin = source.appending(path: file.path, directoryHint: .notDirectory)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: origin.path),
                "\u{0418}\u{0437} \u{0438}\u{0441}\u{0445}\u{043E}\u{0434}\u{043D}\u{043E}\u{0439} \u{043F}\u{0430}\u{043F}\u{043A}\u{0438} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B} \(file.path)"
            )
        }
    }

    /// The path barrier for someone else's folder is needed just as strictly: a manifest with “..” is not
    /// should be able to pull a file from anywhere on the disk.
    func testImportRefusesPathLeavingTheFolder() async throws {
        let manifest = makeManifest(pathForB: "../\u{0441}\u{043D}\u{0430}\u{0440}\u{0443}\u{0436}\u{0438}.json")
        try fillSource(manifest: manifest, contents: ["Encoder.mlmodelc/weight.bin": fileA])
        let outside = source.deletingLastPathComponent()
            .appending(path: "\u{0441}\u{043D}\u{0430}\u{0440}\u{0443}\u{0436}\u{0438}.json", directoryHint: .notDirectory)
        try fileB.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .importSource(message) = error else {
            return XCTFail("\u{041F}\u{0443}\u{0442}\u{044C} \u{043D}\u{0430}\u{0440}\u{0443}\u{0436}\u{0443} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{043D}\u{0430}\u{0432}\u{043B}\u{0438}\u{0432}\u{0430}\u{0442}\u{044C} \u{0438}\u{043C}\u{043F}\u{043E}\u{0440}\u{0442}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        XCTAssertTrue(message.contains("outside the folder"), "\u{041F}\u{0440}\u{0438}\u{0447}\u{0438}\u{043D}\u{0430} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437}\u{0430} \u{043D}\u{0435} \u{043D}\u{0430}\u{0437}\u{0432}\u{0430}\u{043D}\u{0430}: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    /// The symbolic link is replaced after checking the amount - in the established
    /// the model would have a pointer to the outside instead of a file.
    func testImportRefusesSymbolicLink() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: ["Encoder.mlmodelc/weight.bin": fileA])
        let elsewhere = source.appending(path: "\u{043D}\u{0430}\u{0441}\u{0442}\u{043E}\u{044F}\u{0449}\u{0438}\u{0439}.json", directoryHint: .notDirectory)
        try fileB.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "vocab.json", directoryHint: .notDirectory),
            withDestinationURL: elsewhere
        )
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .importSource(message) = error else {
            return XCTFail("\u{0421}\u{0438}\u{043C}\u{0432}\u{043E}\u{043B}\u{0438}\u{0447}\u{0435}\u{0441}\u{043A}\u{0430}\u{044F} \u{0441}\u{0441}\u{044B}\u{043B}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043E}\u{0442}\u{0432}\u{0435}\u{0440}\u{0433}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(state)")
        }
        XCTAssertTrue(message.contains("symbolic link"), "\u{041F}\u{0440}\u{0438}\u{0447}\u{0438}\u{043D}\u{0430} \u{043E}\u{0442}\u{043A}\u{0430}\u{0437}\u{0430} \u{043D}\u{0435} \u{043D}\u{0430}\u{0437}\u{0432}\u{0430}\u{043D}\u{0430}: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    func testImportIsSkippedWhenModelIsAlreadyInstalled() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let readyBefore = await store.currentState()
        XCTAssertTrue(readyBefore.isReady)

        // The folder is empty: if the import does start, the installation will break.
        await store.importModel(from: source)

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{0443}\u{044E} \u{0443}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{043A}\u{0443} \u{0438}\u{043C}\u{043F}\u{043E}\u{0440}\u{0442} \u{0442}\u{0440}\u{043E}\u{0433}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D}: \(state)")
    }
}

import CryptoKit
import XCTest
@testable import LocalASR

/// Подставной загрузчик: отдаёт заранее заданное содержимое, считает вызовы
/// и умеет падать. Настоящая сеть в тестах не участвует.
actor FakeDownloader: ModelDownloading {
    private var contents: [String: Data]
    private var contentsByHost: [String: [String: Data]] = [:]
    private var failure: ModelDownloadError?
    private var failuresByHost: [String: ModelDownloadError] = [:]
    private(set) var requestedPaths: [String] = []
    /// Хосты в порядке обращения — по ним видно, дошло ли дело до запасного адреса.
    private(set) var requestedHosts: [String] = []

    init(contents: [String: Data]) {
        self.contents = contents
    }

    func setFailure(_ error: ModelDownloadError?) { failure = error }

    /// Заставить конкретный источник отказать: так проверяется переход к следующему.
    func setFailure(_ error: ModelDownloadError, forHost host: String) {
        failuresByHost[host] = error
    }

    /// Подсунуть источнику другое содержимое: суммы обязаны ловить это независимо
    /// от того, откуда файл пришёл.
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
        if let failure { throw failure }
        if let hostFailure = failuresByHost[host] { throw hostFailure }

        // Ключ ищем по хвосту адреса — так тест не зависит от формы ссылки.
        let table = contentsByHost[host] ?? contents
        let key = table.keys.first { url.absoluteString.hasSuffix($0) }
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

    private let fileA = Data("содержимое первого файла".utf8)
    private let fileB = Data("содержимое второго файла".utf8)

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
            fluidAudioVersion: "0.15.5",
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
        XCTAssertTrue(state.isReady, "Ожидалось готовое состояние, получено: \(state)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.readyMarker.path))
        // Файлы лежат внутри папки, имя которой ожидает загрузчик библиотеки.
        let encoder = layout.engineDirectory.appending(path: "Encoder.mlmodelc/weight.bin")
        XCTAssertEqual(try Data(contentsOf: encoder), fileA)
    }

    func testCorruptedFileLeavesNothingInstalled() async throws {
        // Сумма второго файла в манифесте заведомо не сойдётся.
        let manifest = makeManifest(corruptChecksumForB: true)
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state else {
            return XCTFail("Ожидался провал установки, получено: \(state)")
        }
        guard case .verification = error else {
            return XCTFail("Ожидалась ошибка проверки, получено: \(error)")
        }
        // Главное: наполовину установленной модели не осталось.
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    func testNetworkFailureLeavesNoStagingBehind() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(.network("сеть недоступна"))
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case .failed = state else {
            return XCTFail("Ожидался провал, получено: \(state)")
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: layout.modelDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            leftovers.allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") },
            "После провала не должно оставаться staging-директорий: \(leftovers)"
        )
    }

    func testRefreshRejectsMarkerFromAnotherRevision() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()

        // Подкладываем метку от другой ревизии — установка должна перестать
        // считаться пригодной, а не «наверное, подойдёт».
        let alien = ModelReadyMarker(
            revision: String(repeating: "f", count: 40),
            fluidAudioVersion: "0.15.5",
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount,
            verifiedAt: Date()
        )
        try JSONEncoder().encode(alien).write(to: layout.readyMarker)

        let state = await store.refreshState()

        guard case .repairRequired = state else {
            return XCTFail("Ожидался repairRequired, получено: \(state)")
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
            return XCTFail("Ожидался repairRequired, получено: \(state)")
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
            return XCTFail("Ожидался repairRequired, получено: \(state)")
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
            return XCTFail("Ожидался repairRequired, получено: \(state)")
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
            return XCTFail("Exact inventory обязан отвергать hidden-файл: \(state)")
        }
    }

    /// Finder создаёт `.DS_Store` при простом просмотре папки. Это мусор, а не
    /// повреждение: объявлять из-за него repair и перекачивать 483 МБ нельзя.
    func testRefreshУбираетМусорFinderВместоRepair() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let dsStore = layout.engineDirectory.appending(path: ".DS_Store")
        try Data([0x00, 0x00, 0x00, 0x01]).write(to: dsStore)

        let state = await store.refreshState()

        guard case .ready = state else {
            return XCTFail("Просмотр папки в Finder не повод перекачивать модель: \(state)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dsStore.path),
            "Мусор Finder должен быть убран, иначе он вернёт repair при следующем осмотре"
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
            return XCTFail("Ожидался repairRequired, получено: \(state)")
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
            guard case .failed = await interrupted.currentState() else {
                return XCTFail("Ожидался injected failure на \(checkpoint)")
            }

            let relaunched = ModelStore(manifest: manifest, layout: layout, downloader: downloader)
            let recovered = await relaunched.refreshState()
            XCTAssertTrue(recovered.isReady, "После \(checkpoint) должна быть готова старая либо новая модель: \(recovered)")
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
            "Повторная установка готовой модели не должна ничего качать"
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

    func testProgressIsReportedWhileDownloading() {
        XCTAssertEqual(ModelState.downloading(receivedBytes: 50, totalBytes: 200).progress, 0.25)
        XCTAssertEqual(ModelState.verifying(checked: 1, total: 4).progress, 0.25)
        XCTAssertNil(ModelState.notInstalled.progress)
    }
}

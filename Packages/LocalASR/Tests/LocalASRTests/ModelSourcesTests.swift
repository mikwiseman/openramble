import CryptoKit
import XCTest
@testable import LocalASR

/// Два независимых пути к модели: запасной адрес и импорт из готовой папки.
///
/// Смысл обоих один: единственный источник — единственная точка отказа. Если
/// репозиторий удалят или закроют для региона, новый пользователь не запустит
/// приложение вообще. Проверка доверия при этом не меняется ни на шаг: сумма
/// SHA-256 из манифеста считается одинаково для любого происхождения файла.
final class ModelSourcesTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    private let fileA = Data("содержимое первого файла".utf8)
    private let fileB = Data("содержимое второго файла".utf8)
    private let primaryHost = "huggingface.co"
    private let mirrorHost = "github.com"

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
            fluidAudioVersion: "0.15.5",
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
            mirror: withMirror ? .init(repository: "mikwiseman/wai-dictation", releaseTag: "models-test") : nil
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

    /// Разложить файлы так, как их отдаёт установленная модель на другой машине.
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

    // MARK: - Запасной источник

    func testManifestBuildsBothAddresses() throws {
        let manifest = makeManifest()
        let file = manifest.files[0]

        let addresses = manifest.downloadURLs(for: file)

        XCTAssertEqual(addresses.count, 2, "Адресов должно быть два: основной и запасной")
        XCTAssertEqual(addresses[0].host(), primaryHost, "Первым идёт основной источник")
        XCTAssertEqual(addresses[1].host(), mirrorHost)
        // Косые черты в имени вложения GitHub не разрешает — путь уплощается.
        XCTAssertEqual(addresses[1].lastPathComponent, "Encoder.mlmodelc__weight.bin")
    }

    func testFallsBackToMirrorWhenPrimaryIsGone() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        // Репозиторий удалили — ровно тот сценарий, ради которого всё это.
        await downloader.setFailure(.httpStatus(404), forHost: primaryHost)
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "Запасной источник обязан вытянуть установку, получено: \(state)")
        let hosts = await downloader.requestedHosts
        XCTAssertEqual(hosts.first, primaryHost, "Начинать надо с основного адреса")
        XCTAssertTrue(hosts.contains(mirrorHost), "Запасной адрес не был опрошен")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    func testMirrorIsNotTouchedWhenPrimaryWorks() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let hosts = await downloader.requestedHosts
        XCTAssertFalse(hosts.contains(mirrorHost), "Пока основной источник жив, зеркало трогать незачем")
    }

    func testBothSourcesFailingNamesBoth() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: [:])
        await downloader.setFailure(.httpStatus(404), forHost: primaryHost)
        await downloader.setFailure(.network("хост недоступен"), forHost: mirrorHost)
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .download(message) = error else {
            return XCTFail("Ожидался внятный отказ загрузки, получено: \(state)")
        }
        XCTAssertTrue(message.contains(primaryHost), "В ошибке нет основного источника: \(message)")
        XCTAssertTrue(message.contains(mirrorHost), "В ошибке нет запасного источника: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    /// Отказ источника и отказ пользователя — разные вещи. После «отмены»
    /// перебирать зеркала значит качать полгигабайта вопреки прямой команде.
    func testCancellationDoesNotWalkToTheMirror() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        await downloader.setFailure(.cancelled, forHost: primaryHost)
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        XCTAssertEqual(state, .notInstalled, "Отмена — это отмена, а не провал установки")
        let hosts = await downloader.requestedHosts
        XCTAssertFalse(hosts.contains(mirrorHost), "После отмены запасной адрес трогать нельзя")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.readyMarker.path))
    }

    /// Запасной адрес ничего не ослабляет: файл из него проверяется теми же
    /// суммами. Иначе зеркало стало бы дырой в доверии.
    func testMirrorContentIsCheckedByTheSameChecksums() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        await downloader.setFailure(.httpStatus(404), forHost: primaryHost)
        await downloader.setContents(
            ["weight.bin": fileA, "vocab.json": Data("подменённое содержимое".utf8)],
            forHost: mirrorHost
        )
        let (store, layout) = makeStore(manifest: manifest, downloader: downloader)

        await store.install()

        let state = await store.currentState()
        guard case let .failed(error) = state, case .verification = error else {
            return XCTFail("Подмена из зеркала обязана падать на проверке, получено: \(state)")
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
        json["mirror"] = ["repository": "простоимя", "releaseTag": "models-test"]

        XCTAssertThrowsError(
            try ModelManifest.decode(from: JSONSerialization.data(withJSONObject: json)),
            "Кривой запасной адрес обязан ловиться на старте, а не при отказе основного"
        )
    }

    func testBundledManifestHasMirror() throws {
        // Второй путь к модели должен существовать в том манифесте, который
        // реально уезжает пользователю, а не только в тестовом.
        let manifest = try ModelManifest.bundled()

        let mirror = try XCTUnwrap(manifest.mirror, "У боевого манифеста нет запасного источника")
        XCTAssertEqual(mirror.repository.split(separator: "/").count, 2)
        XCTAssertEqual(manifest.downloadURLs(for: manifest.files[0]).count, 2)
    }

    // MARK: - Импорт из папки

    func testImportInstallsFromFolder() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: [
            "Encoder.mlmodelc/weight.bin": fileA,
            "vocab.json": fileB,
        ])
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "Импорт готовой папки обязан заканчиваться установкой, получено: \(state)")
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
        XCTAssertTrue(requests.isEmpty, "Импорт из папки не имеет права ходить в сеть: \(requests)")
    }

    func testImportWithOneBadChecksumInstallsNothing() async throws {
        // Сумма второго файла в манифесте заведомо не сойдётся.
        let manifest = makeManifest(corruptChecksumForB: true)
        try fillSource(manifest: manifest, contents: [
            "Encoder.mlmodelc/weight.bin": fileA,
            "vocab.json": fileB,
        ])
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case .verification = error else {
            return XCTFail("Несошедшаяся сумма обязана останавливать импорт, получено: \(state)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: layout.installedDirectory.path),
            "После отказа в целевой папке не должно остаться ни одного файла"
        )
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: layout.modelDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            leftovers.allSatisfy { !$0.lastPathComponent.hasPrefix(".staging-") },
            "Промежуточная папка должна быть убрана: \(leftovers)"
        )
    }

    func testImportFromFolderMissingAFileFails() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: ["Encoder.mlmodelc/weight.bin": fileA])
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .importSource(message) = error else {
            return XCTFail("Неполная папка обязана давать внятный отказ, получено: \(state)")
        }
        XCTAssertTrue(message.contains("vocab.json"), "В ошибке не назван недостающий файл: \(message)")
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

        // Папка чужая: забирать из неё файлы нельзя, только копировать.
        for file in manifest.files {
            let origin = source.appending(path: file.path, directoryHint: .notDirectory)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: origin.path),
                "Из исходной папки пропал \(file.path)"
            )
        }
    }

    /// Барьер путей для чужой папки нужен так же строго: манифест с «..» не
    /// должен уметь вытащить файл откуда угодно с диска.
    func testImportRefusesPathLeavingTheFolder() async throws {
        let manifest = makeManifest(pathForB: "../снаружи.json")
        try fillSource(manifest: manifest, contents: ["Encoder.mlmodelc/weight.bin": fileA])
        let outside = source.deletingLastPathComponent()
            .appending(path: "снаружи.json", directoryHint: .notDirectory)
        try fileB.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .importSource(message) = error else {
            return XCTFail("Путь наружу обязан останавливать импорт, получено: \(state)")
        }
        XCTAssertTrue(message.contains("за пределы"), "Причина отказа не названа: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    /// Символическую ссылку подменяют после проверки суммы — в установленной
    /// модели остался бы указатель наружу вместо файла.
    func testImportRefusesSymbolicLink() async throws {
        let manifest = makeManifest()
        try fillSource(manifest: manifest, contents: ["Encoder.mlmodelc/weight.bin": fileA])
        let elsewhere = source.appending(path: "настоящий.json", directoryHint: .notDirectory)
        try fileB.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "vocab.json", directoryHint: .notDirectory),
            withDestinationURL: elsewhere
        )
        let (store, layout) = makeStore(manifest: manifest)

        await store.importModel(from: source)

        let state = await store.currentState()
        guard case let .failed(error) = state, case let .importSource(message) = error else {
            return XCTFail("Символическая ссылка обязана отвергаться, получено: \(state)")
        }
        XCTAssertTrue(message.contains("ссылка"), "Причина отказа не названа: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.installedDirectory.path))
    }

    func testImportIsSkippedWhenModelIsAlreadyInstalled() async throws {
        let manifest = makeManifest()
        let downloader = FakeDownloader(contents: ["weight.bin": fileA, "vocab.json": fileB])
        let (store, _) = makeStore(manifest: manifest, downloader: downloader)
        await store.install()
        let readyBefore = await store.currentState()
        XCTAssertTrue(readyBefore.isReady)

        // Папка пустая: если импорт всё-таки начнётся, установка сломается.
        await store.importModel(from: source)

        let state = await store.currentState()
        XCTAssertTrue(state.isReady, "Готовую установку импорт трогать не должен: \(state)")
    }
}

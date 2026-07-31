import XCTest
@testable import LocalASR

/// Раскладка решает, куда лягут 483 МБ скачанных файлов.
///
/// Путь каждого файла приходит из манифеста, а манифест — это данные. Ошибка
/// здесь означает запись за пределы своей директории: в чужие настройки, в
/// автозагрузку, в соседнюю установку модели. Манифест такие пути отсеивает,
/// но раскладка обязана держать барьер самостоятельно — на то он и второй.
final class ModelInstallLayoutTests: XCTestCase {
    private var directory: URL!
    private var layout: ModelInstallLayout!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/waidictation-tests/parakeet", isDirectory: true)
        layout = ModelInstallLayout(
            root: URL(fileURLWithPath: "/tmp/waidictation-tests", isDirectory: true),
            modelID: "parakeet",
            revision: String(repeating: "a", count: 40),
            engineFolderName: "parakeet-tdt-0.6b-v3"
        )
    }

    private func file(_ path: String) -> ModelManifest.File {
        .init(path: path, byteCount: 1, sha256: String(repeating: "0", count: 64))
    }

    // MARK: - Выход за пределы директории

    func testRefusesPathClimbingOutOfTheDirectory() throws {
        // «../» в пути — попытка записать файл мимо установки. Отказ обязан
        // быть явным, а не «ну положим куда получилось».
        for path in ["../захвачено.bin", "вложенная/../../захвачено.bin", "../../../../etc/захвачено"] {
            XCTAssertThrowsError(try layout.destination(for: file(path), inside: directory)) { error in
                XCTAssertEqual(error as? ModelInstallError, .unsafePath(path), "Путь: \(path)")
            }
        }
    }

    func testRefusesSiblingDirectoryThatSharesTheNamePrefix() throws {
        // Самый неочевидный случай: «/tmp/…/parakeet» — строковый префикс
        // «/tmp/…/parakeet-подделка», поэтому проверка «начинается с» пропускала
        // такой путь наружу. Сравнение по компонентам пути его ловит.
        let path = "../parakeet-подделка/weights.bin"

        XCTAssertThrowsError(try layout.destination(for: file(path), inside: directory)) { error in
            XCTAssertEqual(error as? ModelInstallError, .unsafePath(path))
        }
    }

    func testRefusesEmptyPath() throws {
        // Пустой путь указывает на саму директорию: запись по нему затёрла бы
        // папку установки файлом.
        XCTAssertThrowsError(try layout.destination(for: file(""), inside: directory)) { error in
            XCTAssertEqual(error as? ModelInstallError, .unsafePath(""))
        }
    }

    func testAbsolutePathIsRefused() throws {
        // Раньше ведущий слэш молча подклеивался внутрь установки: «/etc/passwd»
        // становился файлом внутри папки модели. Наружу это не вело, но такого
        // пути в манифесте быть не может — значит, манифест испорчен, и узнать
        // об этом надо сразу, а не получить непонятный файл на диске.
        XCTAssertThrowsError(try layout.destination(for: file("/etc/passwd"), inside: directory))
    }

    func testKeepsNestedPathsFromTheManifest() throws {
        // Обычный случай: файлы модели лежат во вложенных бандлах.
        let destination = try layout.destination(
            for: file("Encoder.mlmodelc/weights/weight.bin"),
            inside: directory
        )

        XCTAssertEqual(
            destination.standardizedFileURL.path,
            directory.path + "/Encoder.mlmodelc/weights/weight.bin"
        )
    }

    // MARK: - Пути установки

    func testRevisionIsPartOfTheInstalledPath() {
        // Ревизия в имени папки — то, что позволяет поставить новую модель,
        // не сломав уже работающую старую.
        XCTAssertTrue(layout.installedDirectory.path.hasSuffix(String(repeating: "a", count: 40)))
        XCTAssertEqual(layout.engineDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(layout.readyMarker.lastPathComponent, ".ready.json")
    }

    func testStagingDirectoriesOfTwoAttemptsDoNotCollide() {
        // Две попытки установки не должны писать в одну папку: вторая затёрла бы
        // файлы первой и получилась бы установка из кусков разных загрузок.
        let first = layout.stagingDirectory(attempt: UUID())
        let second = layout.stagingDirectory(attempt: UUID())

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix(".staging-"))
    }

    func testEngineFolderNameDropsTheCoremlSuffix() throws {
        // Имя папки библиотека выводит из имени репозитория без «-coreml».
        // Ошибка здесь означает «модель установлена, но движок её не находит».
        let manifest = ModelManifest(
            modelID: "parakeet",
            repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            revision: String(repeating: "b", count: 40),
            fluidAudioVersion: "0.15.5",
            quantization: "int8",
            license: "CC-BY-4.0",
            files: [file("Encoder.mlmodelc/weight.bin")]
        )

        let derived = try ModelInstallLayout(manifest: manifest, root: URL(fileURLWithPath: "/tmp/x"))

        XCTAssertEqual(derived.engineDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
    }
}

/// Метка готовности — единственное, что отличает рабочую установку от папки
/// с файлами. Если она согласится на чужие данные, пользователь получит
/// «модель установлена» и падение в момент первой диктовки.
final class ModelReadyMarkerTests: XCTestCase {
    private let manifest = ModelManifest(
        modelID: "parakeet",
        repository: "acme/parakeet-coreml",
        revision: String(repeating: "c", count: 40),
        fluidAudioVersion: "0.15.5",
        quantization: "int8",
        license: "CC-BY-4.0",
        files: [
            .init(path: "a.bin", byteCount: 10, sha256: String(repeating: "0", count: 64)),
            .init(path: "b.bin", byteCount: 20, sha256: String(repeating: "1", count: 64)),
        ]
    )

    func testMatchesItsOwnManifest() {
        let marker = ModelReadyMarker(manifest: manifest, verifiedAt: Date())

        XCTAssertTrue(marker.matches(manifest))
    }

    func testRejectsInstallationMadeForAnotherFluidAudioVersion() {
        // Файлы те же, а движок другой: библиотека меняет ожидаемую раскладку
        // между версиями, и «наверное, подойдёт» здесь недопустимо.
        let marker = ModelReadyMarker(
            revision: manifest.revision,
            fluidAudioVersion: "0.14.0",
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount,
            verifiedAt: Date()
        )

        XCTAssertFalse(marker.matches(manifest))
    }

    func testRejectsMarkerWithWrongFileCountOrSize() {
        // Расхождение в числе файлов или в суммарном размере означает, что
        // установка неполная — на диске оказалась половина модели.
        let fewerFiles = ModelReadyMarker(
            revision: manifest.revision,
            fluidAudioVersion: manifest.fluidAudioVersion,
            fileCount: manifest.files.count - 1,
            totalByteCount: manifest.totalByteCount,
            verifiedAt: Date()
        )
        let smaller = ModelReadyMarker(
            revision: manifest.revision,
            fluidAudioVersion: manifest.fluidAudioVersion,
            fileCount: manifest.files.count,
            totalByteCount: manifest.totalByteCount - 1,
            verifiedAt: Date()
        )

        XCTAssertFalse(fewerFiles.matches(manifest))
        XCTAssertFalse(smaller.matches(manifest))
    }
}

/// Барьер не должен зависеть от того, что уже лежит на диске.
///
/// Он на этом и сломался: приведение пути к каноническому виду спрашивает
/// файловую систему, а та отвечает «/tmp» про существующую папку и
/// «/private/tmp» про ещё не созданный файл в ней же. Установка падала целиком,
/// на первом же законном файле.
final class ModelInstallLayoutFilesystemIndependenceTests: XCTestCase {
    private func makeLayout(root: URL) -> ModelInstallLayout {
        ModelInstallLayout(
            root: root,
            modelID: "parakeet-tdt-0.6b-v3",
            revision: "abc123",
            engineFolderName: "parakeet-tdt-0.6b-v3"
        )
    }

    private func file(_ path: String) -> ModelManifest.File {
        ModelManifest.File(path: path, byteCount: 1, sha256: String(repeating: "0", count: 64))
    }

    func testLegitimatePathIsAcceptedWhenDirectoryAlreadyExists() throws {
        // Именно так и бывает в жизни: установка создаёт папку, потом кладёт в
        // неё файлы.
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = makeLayout(root: root)
        let engine = layout.engineDirectory(inside: layout.stagingDirectory(attempt: UUID()))
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try layout.destination(for: file("Encoder.mlmodelc/weights/weight.bin"), inside: engine)

        XCTAssertTrue(
            destination.path.hasSuffix("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights/weight.bin"),
            "Законный файл обязан приниматься независимо от состояния диска: \(destination.path)"
        )
    }

    func testVerdictIsTheSameWhetherTheDirectoryExistsOrNot() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = makeLayout(root: root)
        let engine = layout.engineDirectory(inside: layout.stagingDirectory(attempt: UUID()))
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try layout.destination(for: file("Decoder.mlmodelc/metadata.json"), inside: engine)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let after = try layout.destination(for: file("Decoder.mlmodelc/metadata.json"), inside: engine)

        XCTAssertEqual(before, after, "Один и тот же файл — один и тот же путь")
    }

    func testWayOutIsStillRefused() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = makeLayout(root: root)
        let engine = layout.engineDirectory(inside: layout.stagingDirectory(attempt: UUID()))
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for path in ["../parakeet-подделка/weights.bin", "/etc/passwd", "a//b", "", "./x", "a/../../b"] {
            XCTAssertThrowsError(
                try layout.destination(for: file(path), inside: engine),
                "Путь «\(path)» ведёт наружу и обязан быть отвергнут"
            )
        }
    }
}

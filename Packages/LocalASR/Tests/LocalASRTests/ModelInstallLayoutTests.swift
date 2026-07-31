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

    func testAbsoluteLookingPathStaysInsideTheDirectory() throws {
        // Ведущий слэш система трактует как относительный путь, поэтому
        // «/etc/passwd» из манифеста окажется внутри установки, а не в системе.
        let destination = try layout.destination(for: file("/etc/passwd"), inside: directory)

        XCTAssertEqual(destination.standardizedFileURL.path, directory.path + "/etc/passwd")
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

import XCTest
@testable import DictationCore

/// Чтение файла существует отдельным типом ради одного обещания: приложение
/// не ходит в сеть. `Data(contentsOf:)` принимает любой адрес и по http молча
/// уходит наружу, из-за чего проверка сетевой поверхности не смогла бы отличить
/// чтение настроек от незаявленной отправки. Отказ по нефайловому адресу —
/// не мелочь, а то, на чём эта проверка держится.
final class LocalFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "localfile-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRefusesAnyAddressThatIsNotAFile() throws {
        // Ровно тот случай, ради которого тип и написан: адрес, ведущий наружу,
        // отвергается до всякого чтения.
        for address in [
            "https://huggingface.co/model.json",
            "http://localhost:8080/settings",
            "ftp://example.org/file",
        ] {
            let url = try XCTUnwrap(URL(string: address))

            XCTAssertThrowsError(try LocalFile.read(url), "Адрес: \(address)") { error in
                guard case let .notAFileURL(scheme) = error as? LocalFile.Failure else {
                    return XCTFail("Ожидался отказ по схеме адреса, получено: \(error)")
                }
                XCTAssertEqual(scheme, url.scheme)
            }
        }
    }

    func testReadsLocalFileByteForByte() throws {
        let url = directory.appending(path: "манифест.json", directoryHint: .notDirectory)
        let payload = Data("{\"модель\": \"parakeet\"}".utf8)
        try payload.write(to: url)

        XCTAssertEqual(try LocalFile.read(url), payload)
    }

    func testMissingFileIsAnError() throws {
        // Отсутствующий манифест — это сломанная сборка приложения, и молчать
        // об этом нельзя: без манифеста установка модели не имеет корня доверия.
        let url = directory.appending(path: "нет-такого.json", directoryHint: .notDirectory)

        XCTAssertThrowsError(try LocalFile.read(url)) { error in
            guard case .unreadable = error as? LocalFile.Failure else {
                return XCTFail("Ожидалась ошибка чтения, получено: \(error)")
            }
        }
    }

    func testEmptyFileReadsAsEmptyData() throws {
        // Пустой файл — не ошибка чтения. Разбираться с пустотой будет тот,
        // кто просил содержимое.
        let url = directory.appending(path: "пусто.json", directoryHint: .notDirectory)
        try Data().write(to: url)

        XCTAssertEqual(try LocalFile.read(url), Data())
    }
}

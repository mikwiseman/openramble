import CryptoKit
import XCTest
@testable import LocalASR

final class ModelVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "verifier-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: Data, named name: String) throws -> URL {
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try contents.write(to: url)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testAcceptsMatchingFile() throws {
        let payload = Data("привет, это тестовые данные".utf8)
        let url = try write(payload, named: "good.bin")
        let file = ModelManifest.File(
            path: "good.bin",
            byteCount: Int64(payload.count),
            sha256: sha256(payload)
        )

        XCTAssertNoThrow(try ModelVerifier().verify(file: file, at: url))
    }

    func testRejectsMissingFile() {
        let file = ModelManifest.File(path: "absent.bin", byteCount: 10, sha256: String(repeating: "a", count: 64))
        let url = directory.appending(path: "absent.bin")

        XCTAssertThrowsError(try ModelVerifier().verify(file: file, at: url)) { error in
            XCTAssertEqual(error as? ModelVerifier.Failure, .fileMissing("absent.bin"))
        }
    }

    func testRejectsSizeMismatchBeforeHashing() throws {
        let payload = Data(repeating: 0x41, count: 100)
        let url = try write(payload, named: "short.bin")
        // Заявленный размер больше реального — проверка размера должна сработать
        // раньше подсчёта суммы, потому что она на порядки дешевле.
        let file = ModelManifest.File(path: "short.bin", byteCount: 500, sha256: sha256(payload))

        XCTAssertThrowsError(try ModelVerifier().verify(file: file, at: url)) { error in
            XCTAssertEqual(
                error as? ModelVerifier.Failure,
                .sizeMismatch(path: "short.bin", expected: 500, actual: 100)
            )
        }
    }

    func testRejectsCorruptedContent() throws {
        // Размер совпадает, содержимое — нет. Ровно тот случай, ради которого
        // существует контрольная сумма: битая загрузка часто сохраняет длину.
        let payload = Data(repeating: 0x41, count: 128)
        let corrupted = Data(repeating: 0x42, count: 128)
        let url = try write(corrupted, named: "corrupt.bin")
        let file = ModelManifest.File(path: "corrupt.bin", byteCount: 128, sha256: sha256(payload))

        XCTAssertThrowsError(try ModelVerifier().verify(file: file, at: url)) { error in
            XCTAssertEqual(error as? ModelVerifier.Failure, .checksumMismatch("corrupt.bin"))
        }
    }

    func testHashesFileLargerThanOneChunk() throws {
        // Файл больше куска чтения — проверяем, что потоковый подсчёт собирает
        // сумму из нескольких кусков правильно.
        var payload = Data()
        payload.reserveCapacity(9 * 1024 * 1024)
        for index in 0..<(9 * 1024 * 1024) {
            payload.append(UInt8(index % 251))
        }
        let url = try write(payload, named: "big.bin")

        let digest = try ModelVerifier().sha256(of: url, path: "big.bin")

        XCTAssertEqual(digest, sha256(payload))
    }

    func testEmptyFileHashesToKnownValue() throws {
        let url = try write(Data(), named: "empty.bin")

        let digest = try ModelVerifier().sha256(of: url, path: "empty.bin")

        XCTAssertEqual(digest, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}

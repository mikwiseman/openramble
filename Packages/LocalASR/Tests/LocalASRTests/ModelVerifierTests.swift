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
        let payload = Data("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{044D}\u{0442}\u{043E} \u{0442}\u{0435}\u{0441}\u{0442}\u{043E}\u{0432}\u{044B}\u{0435} \u{0434}\u{0430}\u{043D}\u{043D}\u{044B}\u{0435}".utf8)
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
        // The declared size is larger than the real one - the size check should work
        // earlier than calculating the amount, because it is orders of magnitude cheaper.
        let file = ModelManifest.File(path: "short.bin", byteCount: 500, sha256: sha256(payload))

        XCTAssertThrowsError(try ModelVerifier().verify(file: file, at: url)) { error in
            XCTAssertEqual(
                error as? ModelVerifier.Failure,
                .sizeMismatch(path: "short.bin", expected: 500, actual: 100)
            )
        }
    }

    func testRejectsCorruptedContent() throws {
        // The size is the same, the content is not. Exactly the occasion for which
        // there is a checksum: a broken load often preserves the length.
        let payload = Data(repeating: 0x41, count: 128)
        let corrupted = Data(repeating: 0x42, count: 128)
        let url = try write(corrupted, named: "corrupt.bin")
        let file = ModelManifest.File(path: "corrupt.bin", byteCount: 128, sha256: sha256(payload))

        XCTAssertThrowsError(try ModelVerifier().verify(file: file, at: url)) { error in
            XCTAssertEqual(error as? ModelVerifier.Failure, .checksumMismatch("corrupt.bin"))
        }
    }

    func testHashesFileLargerThanOneChunk() throws {
        // The file is larger than the reading chunk - check what the streaming count collects
        // the sum of several pieces is correct.
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

import XCTest
@testable import LocalASR

final class ModelManifestTests: XCTestCase {
    private let validSHA = String(repeating: "a", count: 64)
    private let validRevision = "aed02740059203c4a87495924f685de3722ae9ce"

    private func manifestJSON(
        revision: String? = nil,
        files: String? = nil
    ) -> Data {
        let defaultFiles = """
        [{"path":"Encoder.mlmodelc/weights/weight.bin","byteCount":100,"sha256":"\(validSHA)"}]
        """
        return """
        {
          "modelID": "parakeet-tdt-0.6b-v3",
          "repository": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "revision": "\(revision ?? validRevision)",
          "fluidAudioVersion": "0.15.5",
          "quantization": "encoder 6-bit palettized, mixed precision",
          "license": "CC-BY-4.0",
          "files": \(files ?? defaultFiles)
        }
        """.data(using: .utf8)!
    }

    func testDecodesValidManifest() throws {
        let manifest = try ModelManifest.decode(from: manifestJSON())

        XCTAssertEqual(manifest.revision, validRevision)
        XCTAssertEqual(manifest.license, "CC-BY-4.0")
        XCTAssertEqual(manifest.totalByteCount, 100)
    }

    func testDownloadURLPinsRevision() throws {
        let manifest = try ModelManifest.decode(from: manifestJSON())
        let url = try XCTUnwrap(manifest.downloadURL(for: manifest.files[0]))

        // Ссылка обязана содержать конкретную ревизию, а не main: иначе содержимое
        // может измениться под нами и контрольные суммы перестанут сходиться.
        XCTAssertTrue(url.absoluteString.contains("/resolve/\(validRevision)/"))
        XCTAssertFalse(url.absoluteString.contains("/main/"))
    }

    func testRejectsBranchNameAsRevision() {
        assertInvalid(manifestJSON(revision: "main"))
    }

    func testRejectsShortRevision() {
        assertInvalid(manifestJSON(revision: "aed0274"))
    }

    func testRejectsPathTraversal() {
        let files = """
        [{"path":"../../etc/passwd","byteCount":10,"sha256":"\(validSHA)"}]
        """
        assertInvalid(manifestJSON(files: files))
    }

    func testRejectsAbsolutePath() {
        let files = """
        [{"path":"/etc/passwd","byteCount":10,"sha256":"\(validSHA)"}]
        """
        assertInvalid(manifestJSON(files: files))
    }

    func testRejectsUppercaseChecksum() {
        let files = """
        [{"path":"a.bin","byteCount":10,"sha256":"\(String(repeating: "A", count: 64))"}]
        """
        assertInvalid(manifestJSON(files: files))
    }

    func testRejectsZeroByteFile() {
        let files = """
        [{"path":"a.bin","byteCount":0,"sha256":"\(validSHA)"}]
        """
        assertInvalid(manifestJSON(files: files))
    }

    func testRejectsEmptyFileList() {
        assertInvalid(manifestJSON(files: "[]"))
    }

    private func assertInvalid(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ModelManifest.decode(from: data), file: file, line: line) { error in
            guard let error = error as? ModelManifestError else {
                return XCTFail("Ожидалась ModelManifestError, получено: \(error)", file: file, line: line)
            }
            if case .malformed = error {
                XCTFail("Ожидалась ошибка валидации, а не разбора: \(error)", file: file, line: line)
            }
        }
    }
}

final class ModelDownloadPolicyTests: XCTestCase {
    private let policy = ModelDownloadPolicy()

    func testAllowsPinnedModelAndApprovedRedirectHosts() throws {
        let allowed = [
            "https://huggingface.co/org/model/file",
            "https://cdn-lfs.hf.co/file",
            "https://us-east-1.aws.huggingface.co/file",
            "https://github.com/org/repo/releases/download/v1/file",
            "https://objects.githubusercontent.com/file",
            "https://release-assets.githubusercontent.com/file",
        ]

        for raw in allowed {
            XCTAssertNoThrow(try policy.validate(XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testRejectsHTTPAndLookalikeHosts() throws {
        let rejected = [
            "http://huggingface.co/file",
            "https://huggingface.co.attacker.example/file",
            "https://githubusercontent.com.attacker.example/file",
            "https://pages.github.com/file",
            "https://example.com/file",
        ]

        for raw in rejected {
            XCTAssertThrowsError(try policy.validate(XCTUnwrap(URL(string: raw))), raw)
        }
    }
}

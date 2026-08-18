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
          "runtimeVersion": "0.15.5",
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

        // The link must contain a specific revision, not main: otherwise the content
        // may change under us and the checksums will no longer converge.
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
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} ModelManifestError, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)", file: file, line: line)
            }
            if case .malformed = error {
                XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0432}\u{0430}\u{043B}\u{0438}\u{0434}\u{0430}\u{0446}\u{0438}\u{0438}, \u{0430} \u{043D}\u{0435} \u{0440}\u{0430}\u{0437}\u{0431}\u{043E}\u{0440}\u{0430}: \(error)", file: file, line: line)
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

    // MARK: - Compiled hint manifest

    /// The prompter manifest is the second root of trust: without it, installation
    /// The CTC model has neither file names nor checksums.
    func testScenario001() throws {
        let manifest = try ModelManifest.bundledVocabulary()

        XCTAssertEqual(manifest.modelID, "parakeet-ctc-110m")

        let paths = Set(manifest.files.map(\.path))
        // CtcModels.loadDirect reads these three; CtcTokenizer.load - tokenizer.json.
        for required in [
            "vocab.json",
            "tokenizer.json",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/weights/weight.bin",
        ] {
            XCTAssertTrue(paths.contains(required), "\u{0432} \u{043C}\u{0430}\u{043D}\u{0438}\u{0444}\u{0435}\u{0441}\u{0442}\u{0435} \u{043D}\u{0435}\u{0442} \(required)")
        }

        // The revision is recorded, the amounts for each file.
        XCTAssertEqual(manifest.revision.count, 40)
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 })

        // The hint must remain a light add-on, and not a second model
        // of the same weight: if the set suddenly grew, this is a file selection error.
        XCTAssertLessThan(manifest.totalByteCount, 150_000_000)
        XCTAssertGreaterThan(manifest.totalByteCount, 50_000_000)
    }

    /// Both models live in different installation folders: they have their own repositories,
    /// revisions and life cycles.
    func testScenario002() throws {
        let main = try ModelManifest.bundled()
        let vocabulary = try ModelManifest.bundledVocabulary()

        XCTAssertNotEqual(main.modelID, vocabulary.modelID)
        XCTAssertNotEqual(main.revision, vocabulary.revision)
    }
}

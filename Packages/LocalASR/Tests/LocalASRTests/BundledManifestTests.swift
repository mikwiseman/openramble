import XCTest
@testable import LocalASR

/// Checks the real manifest that will go to the user.
///
/// These guard data rather than code: if the generator one day produces the
/// wrong file set, or points at a different revision, the build should fail
/// here rather than on someone's Mac after a 486 MB download.
final class BundledManifestTests: XCTestCase {
    func testBundledManifestIsValid() throws {
        // Parsing at all means every decoder check passed: a full-length
        // revision, non-zero sizes, well-formed checksums, safe paths.
        let manifest = try ModelManifest.bundled()

        XCTAssertEqual(manifest.modelID, "parakeet-ultra-gguf")
        XCTAssertEqual(manifest.repository, "handy-computer/parakeet-ultra-gguf")
        XCTAssertEqual(manifest.revision, "a1539be1b849ea7463b88343e5277b373d0c4ea9")
        XCTAssertEqual(manifest.runtimeVersion, "transcribe.cpp 0.4.0")
        XCTAssertEqual(manifest.quantization, "Q4_K_M")
        // The weights are Moondream's post-training of NVIDIA's Parakeet TDT
        // 0.6B v3, and attribution is a licence condition rather than a courtesy.
        XCTAssertEqual(manifest.license, "CC-BY-4.0")

        // The model it replaced stays readable, so a Mac that holds it keeps
        // dictating until the new one verifies.
        let previous = try XCTUnwrap(try ModelManifest.bundledPrevious())
        XCTAssertEqual(previous.modelID, "parakeet-tdt-0.6b-v3-gguf")
        XCTAssertEqual(previous.revision, "85ac09ea12fc4b1112fa76810059364bc6adc9de")
    }

    /// One file, not a directory tree.
    ///
    /// The Core ML engine needed four compiled bundles and a vocabulary file,
    /// each a directory of weights and metadata, and most of the install
    /// machinery exists because of that shape. A GGUF is a single file, and
    /// this test is what keeps a future manifest from quietly reintroducing
    /// the old complexity.
    func testTheModelIsExactlyOneFile() throws {
        let manifest = try ModelManifest.bundled()
        XCTAssertEqual(manifest.files.map(\.path), ["parakeet-ultra-Q4_K_M.gguf"])
    }

    /// The published size, pinned.
    ///
    /// The repository also offers F32, F16, Q6_K, Q5_K_M and Q4_K_M builds of
    /// the same model. Selecting a different one is a decision with quality and
    /// memory consequences, and it should never happen by a manifest edit
    /// nobody noticed.
    func testDownloadSizeMatchesTheChosenQuantization() throws {
        let manifest = try ModelManifest.bundled()
        let megabytes = Double(manifest.totalByteCount) / 1_000_000

        // Q4_K_M was chosen over Q8_0 (740 MB) by a preregistered comparison:
        // research/model-upgrade-2026-10, H11.
        XCTAssertGreaterThan(megabytes, 470, "suspiciously small for Q4_K_M: \(megabytes) MB")
        XCTAssertLessThan(megabytes, 500, "suspiciously large for Q4_K_M: \(megabytes) MB")
    }

    func testEveryFileHasDistinctPathAndReachableURL() throws {
        let manifest = try ModelManifest.bundled()
        let paths = manifest.files.map(\.path)

        XCTAssertEqual(Set(paths).count, paths.count, "the manifest repeats a path")

        for file in manifest.files {
            let url = try XCTUnwrap(manifest.downloadURL(for: file), "no address for \(file.path)")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
        }
    }
}

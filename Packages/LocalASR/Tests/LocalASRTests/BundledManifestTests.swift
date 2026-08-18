import XCTest
@testable import LocalASR

/// Checks the real manifest that will go to the user.
///
/// These guard data rather than code: if the generator one day produces the
/// wrong file set, or points at a different revision, the build should fail
/// here rather than on someone's Mac after a 740 MB download.
final class BundledManifestTests: XCTestCase {
    func testBundledManifestIsValid() throws {
        // Parsing at all means every decoder check passed: a full-length
        // revision, non-zero sizes, well-formed checksums, safe paths.
        let manifest = try ModelManifest.bundled()

        XCTAssertEqual(manifest.modelID, "parakeet-tdt-0.6b-v3-gguf")
        XCTAssertEqual(manifest.repository, "handy-computer/parakeet-tdt-0.6b-v3-gguf")
        XCTAssertEqual(manifest.revision, "85ac09ea12fc4b1112fa76810059364bc6adc9de")
        XCTAssertEqual(manifest.runtimeVersion, "transcribe.cpp 0.2.0")
        XCTAssertEqual(manifest.quantization, "Q8_0")
        // The weights are NVIDIA's Parakeet TDT 0.6B v3, and attribution is a
        // licence condition rather than a courtesy.
        XCTAssertEqual(manifest.license, "CC-BY-4.0")
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
        XCTAssertEqual(manifest.files.map(\.path), ["parakeet-tdt-0.6b-v3-Q8_0.gguf"])
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

        XCTAssertGreaterThan(megabytes, 700, "suspiciously small for Q8_0: \(megabytes) MB")
        XCTAssertLessThan(megabytes, 780, "suspiciously large for Q8_0: \(megabytes) MB")
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

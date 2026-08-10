import XCTest
@testable import LocalASR

/// Checks the real manifest that will go to the user.
///
/// These tests guard not the code, but the data: if the manifest generator one day brings
/// the wrong set of files or it will fail at another revision, the assembly should fail here,
/// and not for the user after 483 MB of download.
final class BundledManifestTests: XCTestCase {
    func testBundledManifestIsValid() throws {
        // The very fact of successful parsing means that all decoder checks have passed:
        // full revision, non-zero sizes, correct amounts, safe paths.
        let manifest = try ModelManifest.bundled()

        XCTAssertEqual(manifest.modelID, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(manifest.repository, "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(manifest.revision, "aed02740059203c4a87495924f685de3722ae9ce")
        XCTAssertEqual(manifest.fluidAudioVersion, "0.15.5")
        XCTAssertEqual(manifest.license, "CC-BY-4.0")
    }

    func testContainsExactlyTheFourRequiredBundles() throws {
        let manifest = try ModelManifest.bundled()
        let bundles = Set(manifest.files.map { $0.path.split(separator: "/").first.map(String.init) ?? $0.path })

        XCTAssertEqual(
            bundles,
            [
                "Preprocessor.mlmodelc",
                "Encoder.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecisionv3.mlmodelc",
                "parakeet_vocab.json",
            ],
            "\u{0412} \u{043C}\u{0430}\u{043D}\u{0438}\u{0444}\u{0435}\u{0441}\u{0442} \u{043F}\u{043E}\u{043F}\u{0430}\u{043B}\u{043E} \u{043B}\u{0438}\u{0448}\u{043D}\u{0435}\u{0435} \u{0438}\u{043B}\u{0438} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{043E} \u{043D}\u{0443}\u{0436}\u{043D}\u{043E}\u{0435} — \u{0440}\u{0435}\u{043F}\u{043E}\u{0437}\u{0438}\u{0442}\u{043E}\u{0440}\u{0438}\u{0439} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438} \u{0441}\u{043E}\u{0434}\u{0435}\u{0440}\u{0436}\u{0438}\u{0442} "
                + "\u{0435}\u{0449}\u{0451} MelEncoder, EncoderInt4 \u{0438} JointDecisionv2, \u{043A}\u{043E}\u{0442}\u{043E}\u{0440}\u{044B}\u{0445} \u{0431}\u{044B}\u{0442}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E}"
        )
    }

    func testDownloadSizeStaysWithinExpectedRange() throws {
        let manifest = try ModelManifest.bundled()
        let megabytes = Double(manifest.totalByteCount) / 1_000_000

        // The user is promised "about 500 MB." A sharp jump means that the set
        // an extra bundle leaked - three gigabytes of the repository nearby.
        XCTAssertGreaterThan(megabytes, 400, "\u{041D}\u{0430}\u{0431}\u{043E}\u{0440} \u{043F}\u{043E}\u{0434}\u{043E}\u{0437}\u{0440}\u{0438}\u{0442}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E} \u{043B}\u{0451}\u{0433}\u{043A}\u{0438}\u{0439}: \(megabytes) \u{041C}\u{0411}")
        XCTAssertLessThan(megabytes, 600, "\u{041D}\u{0430}\u{0431}\u{043E}\u{0440} \u{043F}\u{043E}\u{0434}\u{043E}\u{0437}\u{0440}\u{0438}\u{0442}\u{0435}\u{043B}\u{044C}\u{043D}\u{043E} \u{0442}\u{044F}\u{0436}\u{0451}\u{043B}\u{044B}\u{0439}: \(megabytes) \u{041C}\u{0411}")
    }

    func testEveryFileHasDistinctPathAndReachableURL() throws {
        let manifest = try ModelManifest.bundled()
        let paths = manifest.files.map(\.path)

        XCTAssertEqual(Set(paths).count, paths.count, "\u{0412} \u{043C}\u{0430}\u{043D}\u{0438}\u{0444}\u{0435}\u{0441}\u{0442}\u{0435} \u{0435}\u{0441}\u{0442}\u{044C} \u{043F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440}\u{044F}\u{044E}\u{0449}\u{0438}\u{0435}\u{0441}\u{044F} \u{043F}\u{0443}\u{0442}\u{0438}")

        for file in manifest.files {
            let url = try XCTUnwrap(manifest.downloadURL(for: file), "\u{041D}\u{0435} \u{043F}\u{043E}\u{0441}\u{0442}\u{0440}\u{043E}\u{0438}\u{043B}\u{0441}\u{044F} \u{0430}\u{0434}\u{0440}\u{0435}\u{0441} \u{0434}\u{043B}\u{044F} \(file.path)")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
        }
    }
}

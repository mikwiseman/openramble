import XCTest
@testable import LocalASR

/// Проверки реального манифеста, который поедет пользователю.
///
/// Эти тесты стерегут не код, а данные: если генератор манифеста однажды принесёт
/// не тот набор файлов или сорвётся на другую ревизию, сборка должна упасть здесь,
/// а не у пользователя после 483 МБ загрузки.
final class BundledManifestTests: XCTestCase {
    func testBundledManifestIsValid() throws {
        // Сам факт успешного разбора означает, что прошли все проверки декодера:
        // полная ревизия, ненулевые размеры, корректные суммы, безопасные пути.
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
            "В манифест попало лишнее или пропало нужное — репозиторий модели содержит "
                + "ещё MelEncoder, EncoderInt4 и JointDecisionv2, которых быть не должно"
        )
    }

    func testDownloadSizeStaysWithinExpectedRange() throws {
        let manifest = try ModelManifest.bundled()
        let megabytes = Double(manifest.totalByteCount) / 1_000_000

        // Пользователю обещано «около 500 МБ». Резкий скачок означает, что в набор
        // просочился лишний бандл — три гигабайта репозитория рядом.
        XCTAssertGreaterThan(megabytes, 400, "Набор подозрительно лёгкий: \(megabytes) МБ")
        XCTAssertLessThan(megabytes, 600, "Набор подозрительно тяжёлый: \(megabytes) МБ")
    }

    func testEveryFileHasDistinctPathAndReachableURL() throws {
        let manifest = try ModelManifest.bundled()
        let paths = manifest.files.map(\.path)

        XCTAssertEqual(Set(paths).count, paths.count, "В манифесте есть повторяющиеся пути")

        for file in manifest.files {
            let url = try XCTUnwrap(manifest.downloadURL(for: file), "Не построился адрес для \(file.path)")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
        }
    }
}

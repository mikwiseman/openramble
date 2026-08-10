import XCTest
@testable import LocalASR

/// The layout decides where the 483 MB of downloaded files will go.
///
/// The path of each file comes from the manifest, and the manifest is the data. Error
/// here means writing outside of your directory: to someone else’s settings, to
/// autoload into the adjacent model installation. The manifesto eliminates such paths,
/// but the layout must hold the barrier on its own - that’s why it’s second.
final class ModelInstallLayoutTests: XCTestCase {
    private var directory: URL!
    private var layout: ModelInstallLayout!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/openramble-tests/parakeet", isDirectory: true)
        layout = ModelInstallLayout(
            root: URL(fileURLWithPath: "/tmp/openramble-tests", isDirectory: true),
            modelID: "parakeet",
            revision: String(repeating: "a", count: 40),
            engineFolderName: "parakeet-tdt-0.6b-v3"
        )
    }

    private func file(_ path: String) -> ModelManifest.File {
        .init(path: path, byteCount: 1, sha256: String(repeating: "0", count: 64))
    }

    // MARK: - Exiting directory boundaries

    func testRefusesPathClimbingOutOfTheDirectory() throws {
        // "../" in the path - an attempt to write a file past the installation. Refusal is required
        // be explicit, and not “well, let’s put it where it is.”
        for path in ["../\u{0437}\u{0430}\u{0445}\u{0432}\u{0430}\u{0447}\u{0435}\u{043D}\u{043E}.bin", "\u{0432}\u{043B}\u{043E}\u{0436}\u{0435}\u{043D}\u{043D}\u{0430}\u{044F}/../../\u{0437}\u{0430}\u{0445}\u{0432}\u{0430}\u{0447}\u{0435}\u{043D}\u{043E}.bin", "../../../../etc/\u{0437}\u{0430}\u{0445}\u{0432}\u{0430}\u{0447}\u{0435}\u{043D}\u{043E}"] {
            XCTAssertThrowsError(try layout.destination(for: file(path), inside: directory)) { error in
                XCTAssertEqual(error as? ModelInstallError, .unsafePath(path), "\u{041F}\u{0443}\u{0442}\u{044C}: \(path)")
            }
        }
    }

    func testRefusesSiblingDirectoryThatSharesTheNamePrefix() throws {
        // The most unobvious case: “/tmp/…/parakeet” is a string prefix
        // "/tmp/…/parakeet-fake", so the "starts with" check was skipped
        // this is the way out. Comparison by path components catches it.
        let path = "../parakeet-\u{043F}\u{043E}\u{0434}\u{0434}\u{0435}\u{043B}\u{043A}\u{0430}/weights.bin"

        XCTAssertThrowsError(try layout.destination(for: file(path), inside: directory)) { error in
            XCTAssertEqual(error as? ModelInstallError, .unsafePath(path))
        }
    }

    func testRefusesEmptyPath() throws {
        // An empty path points to the directory itself: writing to it would overwrite
        // installation folder file.
        XCTAssertThrowsError(try layout.destination(for: file(""), inside: directory)) { error in
            XCTAssertEqual(error as? ModelInstallError, .unsafePath(""))
        }
    }

    func testAbsolutePathIsRefused() throws {
        // Previously, the leading slash was silently pasted inside the installation: “/etc/passwd”
        // became a file inside the model folder. It didn't lead outside, but it
        // there cannot be a path in the manifest - that means the manifest is corrupted, and you can find out
        // we need to know about this right away, and not get an incomprehensible file on disk.
        XCTAssertThrowsError(try layout.destination(for: file("/etc/passwd"), inside: directory))
    }

    func testKeepsNestedPathsFromTheManifest() throws {
        // Common case: model files are located in nested bundles.
        let destination = try layout.destination(
            for: file("Encoder.mlmodelc/weights/weight.bin"),
            inside: directory
        )

        XCTAssertEqual(
            destination.standardizedFileURL.path,
            directory.path + "/Encoder.mlmodelc/weights/weight.bin"
        )
    }

    // MARK: - Installation paths

    func testRevisionIsPartOfTheInstalledPath() {
        // A revision in the folder name is what allows you to install a new model,
        // without breaking the old one that is already working.
        XCTAssertTrue(layout.installedDirectory.path.hasSuffix(String(repeating: "a", count: 40)))
        XCTAssertEqual(layout.engineDirectory.lastPathComponent, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(layout.readyMarker.lastPathComponent, ".ready.json")
    }

    func testStagingDirectoriesOfTwoAttemptsDoNotCollide() {
        // Two installation attempts should not be written to the same folder: the second one would overwrite
        // files first and the result would be an installation made up of pieces of different downloads.
        let first = layout.stagingDirectory(attempt: UUID())
        let second = layout.stagingDirectory(attempt: UUID())

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix(".staging-"))
    }

    func testEngineFolderNameDropsTheCoremlSuffix() throws {
        // The library derives the folder name from the repository name without “-coreml”.
        // The error here means “the model is installed, but the engine does not find it.”
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

/// The ready label is the only thing that distinguishes a working installation from a folder
/// with files. If she agrees to someone else's data, the user will receive
/// “the model is installed” and a crash at the time of the first dictation.
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
        // The files are the same, but the engine is different: the library changes the expected layout
        // between versions, and “probably will work” is unacceptable here.
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
        // A discrepancy in the number of files or in total size means that
        // installation is incomplete - half of the model is on the disk.
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

/// The barrier should not depend on what is already on the disk.
///
/// This is where he broke down: bringing the path to canonical form asks
/// file system, and it responds with “/tmp” about an existing folder and
/// “/private/tmp” is about a file in it that has not yet been created. The entire installation crashed
/// on the first legal file.
final class ModelInstallLayoutFilesystemIndependenceTests: XCTestCase {
    private func makeLayout(root: URL) -> ModelInstallLayout {
        ModelInstallLayout(
            root: root,
            modelID: "parakeet-tdt-0.6b-v3",
            revision: "abc123",
            engineFolderName: "parakeet-tdt-0.6b-v3"
        )
    }

    private func file(_ path: String) -> ModelManifest.File {
        ModelManifest.File(path: path, byteCount: 1, sha256: String(repeating: "0", count: 64))
    }

    func testLegitimatePathIsAcceptedWhenDirectoryAlreadyExists() throws {
        // This is exactly what happens in life: the installation creates a folder, then puts it in
        // her files.
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = makeLayout(root: root)
        let engine = layout.engineDirectory(inside: layout.stagingDirectory(attempt: UUID()))
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try layout.destination(for: file("Encoder.mlmodelc/weights/weight.bin"), inside: engine)

        XCTAssertTrue(
            destination.path.hasSuffix("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights/weight.bin"),
            "\u{0417}\u{0430}\u{043A}\u{043E}\u{043D}\u{043D}\u{044B}\u{0439} \u{0444}\u{0430}\u{0439}\u{043B} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043F}\u{0440}\u{0438}\u{043D}\u{0438}\u{043C}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043D}\u{0435}\u{0437}\u{0430}\u{0432}\u{0438}\u{0441}\u{0438}\u{043C}\u{043E} \u{043E}\u{0442} \u{0441}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{044F} \u{0434}\u{0438}\u{0441}\u{043A}\u{0430}: \(destination.path)"
        )
    }

    func testVerdictIsTheSameWhetherTheDirectoryExistsOrNot() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = makeLayout(root: root)
        let engine = layout.engineDirectory(inside: layout.stagingDirectory(attempt: UUID()))
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try layout.destination(for: file("Decoder.mlmodelc/metadata.json"), inside: engine)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        let after = try layout.destination(for: file("Decoder.mlmodelc/metadata.json"), inside: engine)

        XCTAssertEqual(before, after, "\u{041E}\u{0434}\u{0438}\u{043D} \u{0438} \u{0442}\u{043E}\u{0442} \u{0436}\u{0435} \u{0444}\u{0430}\u{0439}\u{043B} — \u{043E}\u{0434}\u{0438}\u{043D} \u{0438} \u{0442}\u{043E}\u{0442} \u{0436}\u{0435} \u{043F}\u{0443}\u{0442}\u{044C}")
    }

    func testWayOutIsStillRefused() throws {
        let root = URL(fileURLWithPath: "/private/tmp")
            .appending(path: "layout-\(UUID().uuidString)", directoryHint: .isDirectory)
        let layout = makeLayout(root: root)
        let engine = layout.engineDirectory(inside: layout.stagingDirectory(attempt: UUID()))
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for path in ["../parakeet-\u{043F}\u{043E}\u{0434}\u{0434}\u{0435}\u{043B}\u{043A}\u{0430}/weights.bin", "/etc/passwd", "a// b", "", "./x", "a/../../b"] {
            XCTAssertThrowsError(
                try layout.destination(for: file(path), inside: engine),
                "\u{041F}\u{0443}\u{0442}\u{044C} «\(path)» \u{0432}\u{0435}\u{0434}\u{0451}\u{0442} \u{043D}\u{0430}\u{0440}\u{0443}\u{0436}\u{0443} \u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{043E}\u{0442}\u{0432}\u{0435}\u{0440}\u{0433}\u{043D}\u{0443}\u{0442}"
            )
        }
    }
}

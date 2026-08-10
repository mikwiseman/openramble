import XCTest

final class AppPathsTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "openramble-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    // MARK: - Layout

    func testScenario001() throws {
        let support = try paths.support()

        XCTAssertEqual(support.lastPathComponent, "OpenRamble")
        XCTAssertTrue(try paths.takes().path.hasPrefix(support.path))
        XCTAssertTrue(try paths.audioRecovery().path.hasPrefix(support.path))
        XCTAssertTrue(try paths.models().path.hasPrefix(support.path))
    }

    func testScenario002() throws {
        // Active recording, recovery audio and model do not overlap.
        let directories = [
            try paths.takes(), try paths.audioRecovery(), try paths.models(),
        ]
        XCTAssertEqual(Set(directories.map(\.path)).count, 3)
    }

    func testLegacySupportDirectoryIsMigrated() throws {
        let legacy = root.appending(path: ["Wai", "Dictation"].joined(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("existing model".utf8).write(to: legacy.appending(path: "marker"))

        let support = try paths.support()

        XCTAssertEqual(support.lastPathComponent, "OpenRamble")
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appending(path: "marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testScenario003() throws {
        let takes = try paths.takes()
        let recovery = try paths.audioRecovery()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: takes.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recovery.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    // MARK: - Backups

    /// Speech recordings should not go into Time Machine.
    ///
    /// This folder contains a person's voice. A private product is not eligible
    /// put it into backup copies, where it will survive the dictation itself,
    /// and application.
    func testScenario004() throws {
        XCTAssertTrue(try isExcludedFromBackup(try paths.takes()))
    }

    /// Same for recovery-WAV: this is literally the voice of a person.
    func testScenario005() throws {
        XCTAssertTrue(try isExcludedFromBackup(try paths.audioRecovery()))
    }

    // MARK: - Failures

    /// A file system failure must reach the caller.
    ///
    func testScenario006() throws {
        let support = try paths.support()
        // In place of the future folder - a file. A directory with this name cannot be created.
        try Data().write(to: support.appending(path: "RecoveredAudio", directoryHint: .notDirectory))

        XCTAssertThrowsError(try paths.audioRecovery())
    }

    func testScenario007() throws {
        let support = try paths.support()
        try Data().write(to: support.appending(path: "Takes", directoryHint: .notDirectory))

        XCTAssertThrowsError(try paths.takes())
    }

    // MARK: - Process interruption

    func testScenario008() throws {
        let takes = try paths.takes()
        for name in ["take-1.wav", "take-2.wav"] {
            try Data("sound".utf8).write(to: takes.appending(path: name))
        }

        _ = try paths.takes()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: takes.path).sorted(),
            ["take-1.wav", "take-2.wav"]
        )
    }

    func testScenario009() throws {
        let takes = try paths.takes()
        try Data("sound".utf8).write(to: takes.appending(path: "take.wav"))
        try Data("not ours".utf8).write(to: takes.appending(path: "readme.txt"))

        _ = try paths.takes()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: takes.path).sorted(),
            ["readme.txt", "take.wav"]
        )
    }

    func testScenario010() throws {
        let recovery = try paths.audioRecovery()
        let saved = recovery.appending(path: "recording-1.wav")
        try Data("sound".utf8).write(to: saved)

        _ = try paths.takes()

        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testScenario011() throws {
        let takes = try paths.takes()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: takes.path), [])
    }
}

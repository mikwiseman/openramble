import XCTest

final class AppPathsTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wai-dictation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    // MARK: - Раскладка

    func testВсёЛежитВнутриСвоейПапки() throws {
        let support = try paths.support()

        XCTAssertEqual(support.lastPathComponent, "WaiDictation")
        XCTAssertTrue(try paths.takes().path.hasPrefix(support.path))
        XCTAssertTrue(try paths.audioRecovery().path.hasPrefix(support.path))
        XCTAssertTrue(try paths.models().path.hasPrefix(support.path))
    }

    func testЗаписиМодельИСпасённоеЛежатПорознь() throws {
        // Активная запись, recovery-аудио и модель не пересекаются.
        let directories = [
            try paths.takes(), try paths.audioRecovery(), try paths.models(),
        ]
        XCTAssertEqual(Set(directories.map(\.path)).count, 3)
    }

    func testПапкиСоздаются() throws {
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

    // MARK: - Резервные копии

    /// Записи речи не должны попадать в Time Machine.
    ///
    /// В этой папке лежит голос человека. Приватный продукт не имеет права
    /// раскладывать его по резервным копиям, где он переживёт и саму диктовку,
    /// и приложение.
    func testЗаписиИсключеныИзРезервныхКопий() throws {
        XCTAssertTrue(try isExcludedFromBackup(try paths.takes()))
    }

    /// То же для recovery-WAV: это дословно голос человека.
    func testRecoveryAudioИсключеноИзРезервныхКопий() throws {
        XCTAssertTrue(try isExcludedFromBackup(try paths.audioRecovery()))
    }

    // MARK: - Отказы

    /// Отказ файловой системы обязан дойти до вызывающего.
    ///
    func testПапкаRecoveryAudioНеСоздаласьЭтоОшибка() throws {
        let support = try paths.support()
        // На месте будущей папки — файл. Каталог с таким именем не создать.
        try Data().write(to: support.appending(path: "RecoveredAudio", directoryHint: .notDirectory))

        XCTAssertThrowsError(try paths.audioRecovery())
    }

    func testПапкаЗаписейНеСоздаласьЭтоОшибка() throws {
        let support = try paths.support()
        try Data().write(to: support.appending(path: "Takes", directoryHint: .notDirectory))

        XCTAssertThrowsError(try paths.takes())
    }

    // MARK: - Process interruption

    func testПовторноеОткрытиеTakesНеУдаляетБрошеннуюЗапись() throws {
        let takes = try paths.takes()
        for name in ["take-1.wav", "take-2.wav"] {
            try Data("звук".utf8).write(to: takes.appending(path: name))
        }

        _ = try paths.takes()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: takes.path).sorted(),
            ["take-1.wav", "take-2.wav"]
        )
    }

    func testTakesНеТрогаетЧужиеФайлы() throws {
        let takes = try paths.takes()
        try Data("звук".utf8).write(to: takes.appending(path: "take.wav"))
        try Data("не наше".utf8).write(to: takes.appending(path: "readme.txt"))

        _ = try paths.takes()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: takes.path).sorted(),
            ["readme.txt", "take.wav"]
        )
    }

    func testRecoveryAudioНеТрогаетсяПриОткрытииTakes() throws {
        let recovery = try paths.audioRecovery()
        let saved = recovery.appending(path: "recording-1.wav")
        try Data("звук".utf8).write(to: saved)

        _ = try paths.takes()

        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testПустаяПапкаTakesОстаётсяПустой() throws {
        let takes = try paths.takes()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: takes.path), [])
    }
}

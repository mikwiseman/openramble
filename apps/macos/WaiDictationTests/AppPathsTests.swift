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
        XCTAssertTrue(try paths.recovery().path.hasPrefix(support.path))
        XCTAssertTrue(try paths.models().path.hasPrefix(support.path))
    }

    func testЗаписиМодельИСпасённоеЛежатПорознь() throws {
        // Уборка записей ходит по одной папке. Если бы спасённый текст или
        // модель лежали в ней же, она сносила бы и их.
        let directories = [try paths.takes(), try paths.recovery(), try paths.models()]
        XCTAssertEqual(Set(directories.map(\.path)).count, 3)
    }

    func testПапкиСоздаются() throws {
        let takes = try paths.takes()
        let recovery = try paths.recovery()

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

    /// То же для спасённого текста: это дословно то, что человек продиктовал.
    func testСпасённыйТекстИсключёнИзРезервныхКопий() throws {
        XCTAssertTrue(try isExcludedFromBackup(try paths.recovery()))
    }

    // MARK: - Отказы

    /// Отказ файловой системы обязан дойти до вызывающего.
    ///
    /// Раньше `recovery()` глотал ошибку создания папки и возвращал адрес
    /// несуществующего каталога. Текст, который не удалось вставить, после этого
    /// пропадал молча — то есть ровно там, где его и спасали.
    func testПапкаСпасённогоНеСоздаласьЭтоОшибка() throws {
        let support = try paths.support()
        // На месте будущей папки — файл. Каталог с таким именем не создать.
        try Data().write(to: support.appending(path: "Recovered", directoryHint: .notDirectory))

        XCTAssertThrowsError(try paths.recovery())
    }

    func testПапкаЗаписейНеСоздаласьЭтоОшибка() throws {
        let support = try paths.support()
        try Data().write(to: support.appending(path: "Takes", directoryHint: .notDirectory))

        XCTAssertThrowsError(try paths.takes())
    }

    // MARK: - Уборка

    /// Записи, уцелевшие после падения приложения.
    ///
    /// Обычно папка пуста: файл удаляется сразу после распознавания. Но если
    /// приложение прервали посреди диктовки, голос останется на диске — и без
    /// уборки пролежит там навсегда.
    func testУборкаСноситБрошенныеЗаписи() throws {
        let takes = try paths.takes()
        for name in ["take-1.wav", "take-2.wav"] {
            try Data("звук".utf8).write(to: takes.appending(path: name))
        }

        XCTAssertEqual(paths.sweepAbandonedTakes(), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: takes.path), [])
    }

    func testУборкаНеТрогаетЧужиеФайлы() throws {
        let takes = try paths.takes()
        try Data("звук".utf8).write(to: takes.appending(path: "take.wav"))
        try Data("не наше".utf8).write(to: takes.appending(path: "readme.txt"))

        XCTAssertEqual(paths.sweepAbandonedTakes(), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: takes.path), ["readme.txt"])
    }

    func testУборкаНеТрогаетСпасённыйТекст() throws {
        let recovery = try paths.recovery()
        let saved = recovery.appending(path: "dictation-1.txt")
        try Data("несостоявшаяся вставка".utf8).write(to: saved)

        paths.sweepAbandonedTakes()

        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testУборкаПоПустойПапкеНичегоНеУбирает() throws {
        _ = try paths.takes()
        XCTAssertEqual(paths.sweepAbandonedTakes(), 0)
    }
}

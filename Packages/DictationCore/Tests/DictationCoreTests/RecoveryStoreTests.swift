import XCTest
@testable import DictationCore

/// Спасение текста, который не удалось вставить.
///
/// Сюда попадает то, что человек уже сказал вслух и считает сделанным: письмо,
/// мысль, кусок кода. Промах здесь — единственный способ потерять диктовку
/// безвозвратно, потому что запись голоса к этому моменту уже удалена.
/// Обратная крайность не лучше: папка не должна превращаться в бессрочный
/// архив всего сказанного за годы.
final class RecoveryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func savedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
    }

    private func makeAgedFile(in directory: URL, name: String, daysOld: Double) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try Data("старое".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysOld * 24 * 3600)],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - Сохранение

    func testSavedTextComesBackUnchanged() async throws {
        let directory = root.appending(path: "Recovered", directoryHint: .isDirectory)
        let store = RecoveryStore(directory: directory)

        let url = try await store.save("Важная мысль про 3.14 и «кавычки»")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Важная мысль про 3.14 и «кавычки»")
    }

    func testCreatesItsDirectoryOnFirstUse() async throws {
        // Папка появляется только в момент первой неудачи — а неудача случается
        // тогда, когда её меньше всего ждут.
        let directory = root.appending(path: "глубоко/внутри/Recovered", directoryHint: .isDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let store = RecoveryStore(directory: directory)
        _ = try await store.save("текст")

        XCTAssertEqual(try savedFiles(in: directory).count, 1)
    }

    func testTwoFailuresWithinOneSecondKeepBothTexts() async throws {
        // Две неудачные вставки подряд — это не выдумка: пока активен
        // защищённый ввод, не вставится ни одна диктовка. Имя файла раньше
        // состояло из отметки времени с точностью до секунды, и вторая запись
        // молча затирала первую вместе с текстом, ради спасения которого
        // всё и делалось.
        let directory = root.appending(path: "Recovered", directoryHint: .isDirectory)
        let store = RecoveryStore(directory: directory)

        let first = try await store.save("первая мысль")
        let second = try await store.save("вторая мысль")

        XCTAssertNotEqual(first, second, "Второе спасение не должно занимать имя первого")
        XCTAssertEqual(try savedFiles(in: directory).count, 2)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "первая мысль")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "вторая мысль")
    }

    func testFileNameTellsNothingAboutWhatWasDictated() async throws {
        // Список файлов виден и в Finder, и в резервных копиях. Продиктованное
        // не должно читаться по именам.
        let directory = root.appending(path: "Recovered", directoryHint: .isDirectory)
        let store = RecoveryStore(directory: directory)

        let url = try await store.save("пароль от сейфа лежит в верхнем ящике")

        XCTAssertFalse(url.lastPathComponent.contains("пароль"))
        XCTAssertFalse(url.lastPathComponent.contains("сейф"))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("dictation-"))
        XCTAssertEqual(url.pathExtension, "txt")
    }

    func testFailureToCreateTheDirectoryIsReported() async throws {
        // На месте папки лежит файл. Вернуть адрес, по которому ничего нет,
        // нельзя: человеку скажут «текст сохранён», а сохранять было некуда.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appending(path: "Recovered", directoryHint: .notDirectory)
        try Data("занято".utf8).write(to: blocker)

        let store = RecoveryStore(directory: blocker)

        do {
            _ = try await store.save("текст")
            XCTFail("Ожидалась ошибка: сохранять было некуда")
        } catch {
            // Любая ошибка годится — важно, что она есть.
        }
    }

    // MARK: - Ротация

    func testKeepsOnlyTheTwentyNewestEntries() async throws {
        // Двадцать — обещание продукта: приватный инструмент не копит архив
        // всего сказанного. При этом самое свежее обязано пережить уборку:
        // именно за ним человек и придёт.
        let directory = root.appending(path: "Recovered", directoryHint: .isDirectory)
        let store = RecoveryStore(directory: directory)

        var last: URL?
        for index in 0..<25 {
            last = try await store.save("мысль номер \(index)")
        }

        XCTAssertEqual(try savedFiles(in: directory).count, 20)
        let survivor = try XCTUnwrap(last)
        XCTAssertEqual(try String(contentsOf: survivor, encoding: .utf8), "мысль номер 24")
    }

    func testForgetsEntriesOlderThanAWeek() async throws {
        // Неделя — срок, за который человек либо забрал текст, либо он ему уже
        // не нужен. Держать его дольше — хранить чужую речь без причины.
        let directory = root.appending(path: "Recovered", directoryHint: .isDirectory)
        let ancient = try makeAgedFile(in: directory, name: "dictation-старое.txt", daysOld: 8)
        let recent = try makeAgedFile(in: directory, name: "dictation-свежее.txt", daysOld: 6)

        let store = RecoveryStore(directory: directory)
        _ = try await store.save("сегодняшняя мысль")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ancient.path),
            "Запись старше недели должна быть удалена"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recent.path),
            "Запись моложе недели удалять рано"
        )
    }

    func testDoesNotTouchForeignFilesInTheSameFolder() async throws {
        // В папку мог что-то положить пользователь. Чужое не наше дело.
        let directory = root.appending(path: "Recovered", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appending(path: "заметки.md", directoryHint: .notDirectory)
        try Data("моё".utf8).write(to: foreign)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)],
            ofItemAtPath: foreign.path
        )

        let store = RecoveryStore(directory: directory)
        for index in 0..<22 { _ = try await store.save("мысль \(index)") }

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }
}

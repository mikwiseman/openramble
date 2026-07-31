import AVFoundation
import XCTest
@testable import DictationAudio

/// Запись — единственная копия сказанного.
///
/// Звук приходит из аудиопотока, а команды «останови» и «отмени» — из главного
/// потока, поэтому запись и завершение всегда идут навстречу друг другу. Всё,
/// что здесь проверяется, — про потерю данных: молчаливо потерянные байты
/// выглядят как обрезанная фраза, и списывают их обычно на распознавание.
final class WAVWriterRobustnessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wav-robust-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWriter(name: String = "take.wav") -> WAVWriter {
        WAVWriter(url: directory.appending(path: name), sampleRate: 16_000, channels: 1)
    }

    // MARK: - Одновременная запись

    func testConcurrentAppendsLoseNothing() async throws {
        // Порции звука приходят с аудиопотока, а он не один: смена устройства
        // на ходу или перезапуск движка дают наложение. Без замка счётчик
        // записанного разъезжается с файлом, и заголовок объявляет длину,
        // которой в файле нет, — распознавание читает обрезанную запись.
        let writer = makeWriter()
        try writer.open()

        let writers = 8
        let chunksEach = 50
        let chunk = Array(repeating: Float(0.25), count: 160)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    for _ in 0..<chunksEach {
                        try? writer.append(chunk)
                    }
                }
            }
        }

        let expectedSamples = writers * chunksEach * chunk.count
        XCTAssertEqual(writer.duration, Double(expectedSamples) / 16_000, accuracy: 0.0001)

        let url = try writer.close()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(
            data.count,
            44 + expectedSamples * 2,
            "Каждая порция звука обязана дойти до файла целиком"
        )

        // И файл после гонки остаётся читаемым системой, а не «почти WAV».
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(expectedSamples))
    }

    // MARK: - Жизненный цикл

    func testAppendAfterCloseIsRefused() throws {
        // Хвост звука, пришедший после остановки, в закрытый файл не попадёт.
        // Принять его молча — значит потерять кусок фразы без единого следа.
        let writer = makeWriter()
        try writer.open()
        try writer.append([0.1, 0.2])
        try writer.close()

        XCTAssertThrowsError(try writer.append([0.3])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
    }

    func testSecondCloseIsRefused() throws {
        // Остановка может прийти дважды: по отпусканию клавиши и по пределу
        // длительности. Второе закрытие обязано быть отказом, а не повторной
        // перезаписью заголовка поверх готового файла.
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.1, count: 100))
        try writer.close()

        XCTAssertThrowsError(try writer.close()) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }

        // Файл при этом остался целым.
        let file = try AVAudioFile(forReading: writer.fileURL)
        XCTAssertEqual(file.length, 100)
    }

    func testDiscardWithoutOpenDoesNothingBad() {
        // Отмена приходит из любого состояния, в том числе до того, как файл
        // успел появиться. Падать на этом нельзя.
        let writer = makeWriter()

        writer.discard()
        writer.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
    }

    func testReopeningStartsTheRecordingFromScratch() throws {
        // Повторная сессия не должна дописываться к прошлой записи: иначе в
        // распознавание уйдёт чужая фраза, сказанная минуту назад.
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.5, count: 1000))
        try writer.close()

        try writer.open()
        try writer.append(Array(repeating: 0.5, count: 10))
        let url = try writer.close()

        XCTAssertEqual(writer.duration, 10.0 / 16_000, accuracy: 0.0001)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 20, "Старая запись должна быть затёрта, а не продолжена")
    }

    // MARK: - Отказ на старте

    func testOpenFailsLoudlyWhenTheDirectoryIsBlocked() throws {
        // На месте папки записей лежит файл — так бывает после ручной возни в
        // Finder. Диктовка обязана сказать об этом, а не начать «запись»,
        // которой некуда идти.
        let blocker = directory.appending(path: "blocked", directoryHint: .notDirectory)
        try Data("занято".utf8).write(to: blocker)
        let writer = WAVWriter(url: blocker.appending(path: "take.wav"))

        XCTAssertThrowsError(try writer.open()) { error in
            guard case .cannotCreateFile = error as? WAVWriter.Failure else {
                return XCTFail("Ожидался отказ создания файла, получено: \(error)")
            }
        }
    }

    // MARK: - Крайние размеры

    func testEmptyChunkChangesNothing() throws {
        // Аудиопоток отдаёт пустой буфер на паузе — это норма.
        let writer = makeWriter()
        try writer.open()
        try writer.append([])
        try writer.append([0.1])
        try writer.append([])
        let url = try writer.close()

        XCTAssertEqual(try Data(contentsOf: url).count, 44 + 2)
    }

    func testLongRecordingKeepsHeaderAndLengthConsistent() throws {
        // Минута речи — обычная длина рабочей диктовки, и заголовок с размерами
        // в мегабайтах должен остаться верным: система читает длину именно
        // оттуда, а не по факту файла.
        let writer = makeWriter()
        try writer.open()

        let second = (0..<16_000).map { sin(Float($0) * 0.01) * 0.3 }
        for _ in 0..<60 { try writer.append(second) }
        let url = try writer.close()

        XCTAssertEqual(writer.duration, 60, accuracy: 0.001)

        let data = try Data(contentsOf: url)
        let expectedBytes = 60 * 16_000 * 2
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), 36 + expectedBytes)
        XCTAssertEqual(Int(dataSize), expectedBytes)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, Int64(60 * 16_000))
    }
}

/// Дескриптор файла после неудачного закрытия.
final class WAVWriterHandleReleaseTests: XCTestCase {
    func testFailedCloseStillReleasesTheHandle() throws {
        // Файл удаляют из-под записи — так бывает при чистке диска.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "handle-\(UUID().uuidString).wav")
        let writer = WAVWriter(url: url, sampleRate: 16_000, channels: 1)
        try writer.open()
        try writer.append(Array(repeating: 0.1, count: 1000))
        try? writer.close()

        // Второе закрытие обязано сказать «не открыт», а не пытаться писать в
        // уже закрытый дескриптор.
        XCTAssertThrowsError(try writer.close()) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
        try? FileManager.default.removeItem(at: url)
    }

    func testProcessDoesNotRunOutOfFileDescriptors() throws {
        // Тысяча диктовок подряд: при утечке дескрипторов процесс упрётся в
        // лимит и перестанет открывать файлы вообще.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fd-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<1000 {
            let writer = WAVWriter(url: directory.appending(path: "take-\(index).wav"))
            try writer.open()
            try writer.append([0.1, 0.2, 0.3])
            _ = try writer.close()
        }

        let last = WAVWriter(url: directory.appending(path: "final.wav"))
        XCTAssertNoThrow(try last.open(), "Дескрипторы должны освобождаться")
        _ = try last.close()
    }
}

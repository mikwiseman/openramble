import AVFoundation
import XCTest
@testable import DictationAudio

final class WAVWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wav-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWriter(name: String = "take.wav") -> WAVWriter {
        WAVWriter(url: directory.appending(path: name), sampleRate: 16_000, channels: 1)
    }

    func testProducesFileReadableByTheSystem() throws {
        let writer = makeWriter()
        try writer.open()
        // Полсекунды синусоиды.
        let samples = (0..<8000).map { sin(Float($0) * 0.05) * 0.5 }
        try writer.append(samples)
        let url = try writer.close()

        // Главная проверка: файл должен открываться штатными средствами системы,
        // иначе распознавание его не прочтёт.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.length, 8000)
    }

    func testHeaderSizesAreFixedUpOnClose() throws {
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.1, count: 1600))
        let url = try writer.close()

        let data = try Data(contentsOf: url)
        // 44 байта заголовка плюс 1600 отсчётов по два байта.
        XCTAssertEqual(data.count, 44 + 3200)

        // В заголовке должны стоять настоящие размеры, а не нули заготовки.
        let riffSize = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(riffSize), 36 + 3200)
        XCTAssertEqual(Int(dataSize), 3200)
    }

    func testDurationTracksWhatWasWritten() throws {
        let writer = makeWriter()
        try writer.open()

        XCTAssertEqual(writer.duration, 0)
        try writer.append(Array(repeating: 0, count: 16_000))
        XCTAssertEqual(writer.duration, 1.0, accuracy: 0.001)
        try writer.append(Array(repeating: 0, count: 8_000))
        XCTAssertEqual(writer.duration, 1.5, accuracy: 0.001)

        try writer.close()
    }

    func testDiscardRemovesFile() throws {
        let writer = makeWriter()
        try writer.open()
        try writer.append(Array(repeating: 0.2, count: 1000))
        let url = writer.fileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        writer.discard()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.path),
            "Отменённая диктовка не должна оставлять запись голоса на диске"
        )
    }

    func testAppendWithoutOpenFails() {
        let writer = makeWriter()

        XCTAssertThrowsError(try writer.append([0.1])) { error in
            XCTAssertEqual(error as? WAVWriter.Failure, .notOpen)
        }
    }

    func testClampsSamplesOutOfRange() throws {
        // Слишком громкий вход не должен переполнять шкалу и превращаться в треск.
        let writer = makeWriter()
        try writer.open()
        try writer.append([2.0, -2.0])
        let url = try writer.close()

        let data = try Data(contentsOf: url)
        let first = data.subdata(in: 44..<46).withUnsafeBytes { $0.load(as: Int16.self) }
        let second = data.subdata(in: 46..<48).withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(first, 32767)
        XCTAssertEqual(second, -32767)
    }

    func testEmptyRecordingStillProducesValidFile() throws {
        // Пользователь нажал и сразу отпустил — файл должен быть корректным,
        // просто пустым, а не битым.
        let writer = makeWriter()
        try writer.open()
        let url = try writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 0)
    }
}

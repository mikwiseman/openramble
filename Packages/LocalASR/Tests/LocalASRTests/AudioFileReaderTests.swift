import AVFoundation
import XCTest
@testable import LocalASR

/// Читатель звука — узкое место между записью и распознаванием.
///
/// Распознавание умеет ровно один формат: моно, 16 кГц, Float32. Микрофоны
/// пользователей отдают что угодно: гарнитура — 8 кГц, встроенный вход — 44,1,
/// внешний интерфейс — 48, а стерео приходит с любой USB-камеры. Ошибка
/// приведения не выглядит ошибкой: речь просто распознаётся как невнятица
/// или получается вдвое длиннее, чем была.
final class AudioFileReaderTests: XCTestCase {
    private var directory: URL!
    private let reader = AudioFileReader()

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Записать WAV нужной частоты и числа каналов.
    ///
    /// Запись обёрнута в `autoreleasepool` намеренно: `AVAudioFile` дописывает
    /// данные при освобождении, и файл, прочитанный при живом объекте записи,
    /// окажется пустым.
    private func writeWAV(
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        name: String = "take"
    ) throws -> URL {
        let url = directory.appending(path: "\(name)-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: false
            )
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)

        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<Int(channels) {
                for index in 0..<Int(frames) {
                    // Синусоида, а не тишина: иначе «прочитал» и «прочитал нули»
                    // выглядели бы одинаково.
                    buffer.floatChannelData?[channel][index] = sin(Float(index) * 0.03) * 0.4
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func assertRoughly(_ actual: Int, _ expected: Int, tolerance: Int, _ message: String) {
        XCTAssertEqual(Double(actual), Double(expected), accuracy: Double(tolerance), message)
    }

    // MARK: - Частоты

    func testReadsOwnRecordingWithoutTouchingIt() throws {
        // Собственная запись диктовки уже в целевом формате: приведение здесь
        // не нужно, и число отсчётов обязано совпасть точно.
        let url = try writeWAV(seconds: 0.5, sampleRate: 16_000, channels: 1)

        let samples = try reader.samples(from: url)

        XCTAssertEqual(samples.count, 8000)
        XCTAssertTrue(samples.contains { $0 != 0 }, "Прочитана тишина вместо синусоиды")
    }

    func testUpsamplesNarrowbandHeadset() throws {
        // Bluetooth-гарнитура в режиме разговора даёт 8 кГц. Без приведения
        // распознавание получило бы вдвое более короткую запись.
        let url = try writeWAV(seconds: 1.0, sampleRate: 8_000, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "8 кГц должны стать 16 кГц")
    }

    func testDownsamplesBuiltInMicrophone() throws {
        // Встроенный вход Mac — 44,1 кГц.
        let url = try writeWAV(seconds: 1.0, sampleRate: 44_100, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "44,1 кГц должны стать 16 кГц")
    }

    func testDownsamplesExternalInterface() throws {
        // Внешний звуковой интерфейс — 48 кГц.
        let url = try writeWAV(seconds: 1.0, sampleRate: 48_000, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "48 кГц должны стать 16 кГц")
    }

    // MARK: - Каналы

    func testMixesStereoDownToMono() throws {
        // USB-камеры и большинство интерфейсов отдают два канала. Движок ждёт
        // один: если отдать ему стерео как есть, каналы склеятся встык и речь
        // превратится в ускоренную кашу.
        let url = try writeWAV(seconds: 1.0, sampleRate: 44_100, channels: 2)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 16_000, tolerance: 400, "Стерео должно свернуться в моно")
        XCTAssertTrue(samples.contains { $0 != 0 }, "Свёртка каналов не должна давать тишину")
    }

    // MARK: - Длинные записи

    func testReadsRecordingLongerThanOneConversionChunk() throws {
        // Приведение идёт кусками по 16 384 кадра, и склейка кусков — самое
        // хрупкое место: ошибка там срезает конец длинной диктовки.
        let url = try writeWAV(seconds: 3.0, sampleRate: 48_000, channels: 1)

        let samples = try reader.samples(from: url)

        assertRoughly(samples.count, 48_000, tolerance: 800, "Три секунды не должны потерять хвост")
    }

    // MARK: - Битые входы

    func testBrokenHeaderIsReportedNotGuessed() throws {
        // Файл с расширением .wav, но не звук: так выглядит оборванная запись
        // после падения приложения. Молча вернуть пустой массив нельзя —
        // получилась бы «диктовка распознала тишину» вместо честной ошибки.
        let url = directory.appending(path: "broken.wav", directoryHint: .notDirectory)
        try Data("RIFF это не звук, а обрывок".utf8).write(to: url)

        XCTAssertThrowsError(try reader.samples(from: url)) { error in
            guard case .unreadable = error as? AudioFileReader.Failure else {
                return XCTFail("Ожидалась ошибка чтения, получено: \(error)")
            }
        }
    }

    func testMissingFileIsReported() throws {
        let url = directory.appending(path: "нет-такого.wav", directoryHint: .notDirectory)

        XCTAssertThrowsError(try reader.samples(from: url)) { error in
            guard case .unreadable = error as? AudioFileReader.Failure else {
                return XCTFail("Ожидалась ошибка чтения, получено: \(error)")
            }
        }
    }

    func testEmptyRecordingIsReportedSeparately() throws {
        // Нажал и сразу отпустил: файл корректный, но пустой. Это отдельный
        // случай, а не поломка формата — и различать их нужно, чтобы не пугать
        // человека сообщением о битом звуке.
        let url = try writeWAV(seconds: 0, sampleRate: 16_000, channels: 1, name: "empty")

        XCTAssertThrowsError(try reader.samples(from: url)) { error in
            XCTAssertEqual(error as? AudioFileReader.Failure, .emptyFile)
        }
    }
}

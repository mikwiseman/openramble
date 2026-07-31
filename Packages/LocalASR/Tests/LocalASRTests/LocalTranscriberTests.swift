import AVFoundation
import DictationCore
import XCTest
@testable import LocalASR

/// Подставной движок: позволяет проверить поведение транскрайбера,
/// не загружая 483 МБ модели.
actor StubEngine: ASREngineAdapting {
    private(set) var loadCount = 0
    private(set) var transcribeCount = 0
    private(set) var lastSampleCount = 0
    /// Все буферы, которые движок получил, — по ним видно, резали ли запись.
    private(set) var receivedBatches: [[Float]] = []
    private var loaded = false
    private var error: ASREngineError?
    private var result = ASRResult(text: "распознано", audioDuration: 1, processingDuration: 0.1)

    func setError(_ error: ASREngineError?) { self.error = error }
    func setResult(_ result: ASRResult) { self.result = result }

    func loadModels(from directory: URL) async throws {
        if let error { throw error }
        loadCount += 1
        loaded = true
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        transcribeCount += 1
        lastSampleCount = samples.count
        receivedBatches.append(samples)
        if let error { throw error }
        guard loaded else { throw ASREngineError.modelsNotLoaded }
        return result
    }

    func unload() async { loaded = false }
}

final class LocalTranscriberTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "transcriber-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Записать короткий WAV: моно, 16 кГц — ровно то, что пишет диктовка.
    ///
    /// Запись вынесена в отдельный блок намеренно: `AVAudioFile` дописывает данные
    /// на диск при освобождении, и если читать файл, пока объект записи жив,
    /// он окажется пустым.
    private func writeWAV(seconds: Double = 0.5, sampleRate: Double = 16_000) throws -> URL {
        let url = directory.appending(path: "take-\(UUID().uuidString).wav", directoryHint: .notDirectory)
        let format = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)

        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            // Синусоида, чтобы файл не был тишиной.
            for index in 0..<Int(frames) {
                buffer.floatChannelData?[0][index] = sin(Float(index) * 0.05) * 0.3
            }
            try file.write(from: buffer)
        }

        let written = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(written.length, 0, "Фикстура записалась пустой")
        return url
    }

    func testTranscribeBeforePrepareFails() async throws {
        let transcriber = LocalTranscriber(engine: StubEngine())
        let url = try writeWAV()

        do {
            _ = try await transcriber.transcribe(fileURL: url)
            XCTFail("Распознавание без подготовленной модели должно падать")
        } catch let error as ASREngineError {
            XCTAssertEqual(error, .modelsNotLoaded)
        }
    }

    func testPrepareIsIdempotent() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)

        try await transcriber.prepare(modelDirectory: directory)
        try await transcriber.prepare(modelDirectory: directory)

        let loads = await engine.loadCount
        XCTAssertEqual(loads, 1, "Повторная подготовка той же модели не должна грузить её заново")
    }

    func testReadsWavAndPassesSamplesToEngine() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let url = try writeWAV(seconds: 0.5)

        let result = try await transcriber.transcribe(fileURL: url)

        XCTAssertEqual(result.text, "распознано")
        let sampleCount = await engine.lastSampleCount
        // Полсекунды на 16 кГц — около 8000 отсчётов.
        XCTAssertEqual(Double(sampleCount), 8000, accuracy: 200)
    }

    func testResamplesFileRecordedAtOtherRate() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        // Внешний микрофон вполне может дать 48 кГц — приводим к 16 кГц сами.
        let url = try writeWAV(seconds: 1.0, sampleRate: 48_000)

        _ = try await transcriber.transcribe(fileURL: url)

        let sampleCount = await engine.lastSampleCount
        XCTAssertEqual(Double(sampleCount), 16_000, accuracy: 800)
    }

    func testEmptyFileIsRejectedWithClearError() async throws {
        let transcriber = LocalTranscriber(engine: StubEngine())
        try await transcriber.prepare(modelDirectory: directory)
        let url = directory.appending(path: "broken.wav")
        try Data("не звук".utf8).write(to: url)

        do {
            _ = try await transcriber.transcribe(fileURL: url)
            XCTFail("Битый файл должен давать явную ошибку, а не пустой текст")
        } catch let error as ASREngineError {
            guard case .unsupportedAudioFormat = error else {
                return XCTFail("Ожидалась ошибка формата, получено: \(error)")
            }
        }
    }

    // MARK: - Длинная запись уходит в движок целиком

    /// Раньше запись длиннее двенадцати секунд резалась здесь по паузам. Резало
    /// посреди фразы, вдвое замедляло разбор и на смешанной речи теряло больше
    /// текста, чем движок со своей склейкой окон (замеры — в docs/benchmarks.md).
    /// Тест сторожит, чтобы нарезка не вернулась незаметно.
    func testLongRecordingGoesToEngineInOnePiece() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        // Минута: впятеро длиннее прежнего порога нарезки.
        let samples = (0..<(60 * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }

        _ = try await transcriber.transcribe(samples: samples)

        let batches = await engine.receivedBatches
        XCTAssertEqual(batches.count, 1, "Запись обязана уходить в движок одним куском")
        XCTAssertEqual(batches.first?.count, samples.count, "Из буфера пропали отсчёты")
    }

    /// Самый опасный случай прежней нарезки: короткий хвост после разреза
    /// отбрасывался молча — человек говорил «да», и это «да» исчезало.
    func testShortTailAfterCutIsNotDropped() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)

        // 12,0 с речи и 0,2 с в самом конце. Прежняя нарезка резала ровно по
        // порогу в двенадцать секунд, а остаток короче 0,35 с не отдавала
        // движку вовсе — «да» в конце фразы исчезало без следа.
        var samples = (0..<Int(12.0 * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }
        let tailMarker: Float = 0.42
        samples += Array(repeating: tailMarker, count: Int(0.2 * 16_000))

        _ = try await transcriber.transcribe(samples: samples)

        let batches = await engine.receivedBatches
        let delivered = batches.flatMap { $0 }
        XCTAssertEqual(delivered.count, samples.count, "Часть записи не дошла до движка")
        XCTAssertEqual(delivered.last, tailMarker, "Хвост записи потерян")
    }

    /// Тайминги слов приходят от движка и не должны по дороге сдвигаться:
    /// прежняя склейка кусков прибавляла к ним смещение сегмента.
    func testWordTimingsArePassedThroughUnchanged() async throws {
        let engine = StubEngine()
        await engine.setResult(
            ASRResult(
                text: "раз два",
                words: [
                    .init(text: "раз", start: 0.2, end: 0.6, confidence: 0.9),
                    .init(text: "два", start: 40.0, end: 40.5, confidence: 0.8),
                ],
                audioDuration: 60,
                processingDuration: 0.5
            )
        )
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let samples = (0..<(60 * 16_000)).map { sin(Float($0) * 0.05) * 0.3 }

        let result = try await transcriber.transcribe(samples: samples)

        XCTAssertEqual(result.text, "раз два")
        XCTAssertEqual(result.words.map(\.start), [0.2, 40.0])
        XCTAssertEqual(result.words.map(\.end), [0.6, 40.5])
    }

    func testEmptyBufferIsRejected() async throws {
        let transcriber = LocalTranscriber(engine: StubEngine())
        try await transcriber.prepare(modelDirectory: directory)

        do {
            _ = try await transcriber.transcribe(samples: [])
            XCTFail("Пустая запись должна давать явную ошибку")
        } catch let error as ASREngineError {
            guard case .unsupportedAudioFormat = error else {
                return XCTFail("Ожидалась ошибка формата, получено: \(error)")
            }
        }
    }

    func testUnloadRequiresPrepareAgain() async throws {
        let engine = StubEngine()
        let transcriber = LocalTranscriber(engine: engine)
        try await transcriber.prepare(modelDirectory: directory)
        let prepared = await transcriber.isPrepared
        XCTAssertTrue(prepared)

        await transcriber.unload()

        let stillPrepared = await transcriber.isPrepared
        XCTAssertFalse(stillPrepared)
    }
}

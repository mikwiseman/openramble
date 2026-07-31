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
    private var loaded = false
    private var error: ASREngineError?

    func setError(_ error: ASREngineError?) { self.error = error }

    func loadModels(from directory: URL) async throws {
        if let error { throw error }
        loadCount += 1
        loaded = true
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        transcribeCount += 1
        lastSampleCount = samples.count
        if let error { throw error }
        guard loaded else { throw ASREngineError.modelsNotLoaded }
        return ASRResult(text: "распознано", audioDuration: 1, processingDuration: 0.1)
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

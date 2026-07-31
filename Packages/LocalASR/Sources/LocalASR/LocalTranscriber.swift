import DictationCore
import Foundation

/// Локальное распознавание речи.
///
/// Держит модель загруженной, распознаёт файлы и умеет отпускать память.
/// Одновременно выполняется не больше одного распознавания — это гарантирует
/// актор, и на этом же держится отсутствие гонок с отменой.
public actor LocalTranscriber {
    private let engine: any ASREngineAdapting
    private let reader: AudioFileReader
    private let segmenter: SpeechSegmenter
    private var loadedDirectory: URL?

    public init(
        engine: any ASREngineAdapting = FluidAudioAdapter(),
        reader: AudioFileReader = AudioFileReader(),
        segmenter: SpeechSegmenter = SpeechSegmenter()
    ) {
        self.engine = engine
        self.reader = reader
        self.segmenter = segmenter
    }

    public var isPrepared: Bool { loadedDirectory != nil }

    /// Загрузить модель заранее.
    ///
    /// Первый вызов после установки компилирует модель под нейромодуль и потому
    /// заметно дольше последующих — это стоит делать не в момент, когда
    /// пользователь ждёт текст.
    public func prepare(modelDirectory: URL) async throws {
        if loadedDirectory == modelDirectory { return }
        try await engine.loadModels(from: modelDirectory)
        loadedDirectory = modelDirectory
    }

    /// Распознать записанный файл.
    public func transcribe(fileURL: URL) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }

        let samples: [Float]
        do {
            samples = try reader.samples(from: fileURL)
        } catch let failure as AudioFileReader.Failure {
            throw ASREngineError.unsupportedAudioFormat(String(describing: failure))
        }

        try Task.checkCancellation()
        return try await transcribe(samples: samples)
    }

    /// Распознать готовый буфер.
    ///
    /// Длинные записи идут кусками: движок обрабатывает звук окнами по 15 секунд
    /// и на склейке окон умеет **молча терять речь** — на проверке пропало целое
    /// предложение. Разрезав запись заранее по паузам, мы этого избегаем, а
    /// тексты кусков просто склеиваем.
    public func transcribe(samples: [Float]) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("пустая запись")
        }

        let segments = segmenter.segments(for: samples)
        guard segments.count > 1 else {
            return try await engine.transcribe(samples: samples)
        }

        var texts: [String] = []
        var words: [ASRResult.Word] = []
        var processing: TimeInterval = 0
        var offset: TimeInterval = 0

        for segment in segments {
            try Task.checkCancellation()

            // Совсем короткий хвост движок отвергает — пропускаем его молча,
            // речи там нет.
            guard segment.duration >= 0.35 else {
                offset += segment.duration
                continue
            }

            let piece = try await engine.transcribe(samples: Array(samples[segment.range]))
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(text) }

            // Тайминги сдвигаем, чтобы они оставались верными для всей записи.
            words.append(
                contentsOf: piece.words.map {
                    ASRResult.Word(
                        text: $0.text,
                        start: $0.start + offset,
                        end: $0.end + offset,
                        confidence: $0.confidence
                    )
                }
            )
            processing += piece.processingDuration
            offset += segment.duration
        }

        return ASRResult(
            text: texts.joined(separator: " "),
            words: words,
            audioDuration: Double(samples.count) / AudioFileReader.targetSampleRate,
            processingDuration: processing
        )
    }

    /// Освободить память под моделью.
    public func unload() async {
        await engine.unload()
        loadedDirectory = nil
    }
}

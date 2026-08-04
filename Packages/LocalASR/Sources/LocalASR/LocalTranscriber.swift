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
    private var loadedDirectory: URL?

    public init(
        engine: any ASREngineAdapting = FluidAudioAdapter(),
        reader: AudioFileReader = AudioFileReader()
    ) {
        self.engine = engine
        self.reader = reader
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

    /// Загрузить акустический подсказчик терминов.
    ///
    /// Отдельно от `prepare`, потому что это отдельная модель с отдельной
    /// судьбой: без неё распознавание полноценно работает, а с ней термины
    /// узнаются на уровне звука, а не пост-обработкой.
    public func prepareVocabulary(modelDirectory: URL, boost: VocabularyBoost) async throws {
        guard let capable = engine as? VocabularyBoostCapable else {
            throw ASREngineError.modelsUnavailable("the engine doesn't support vocabulary hints")
        }
        try await capable.loadVocabularyModels(from: modelDirectory, boost: boost)
    }

    /// Распознать записанный файл.
    ///
    /// `languageHint` — код BCP-47 либо `nil` для автоопределения; см.
    /// `ASREngineAdapting.transcribe(samples:languageHint:)`.
    public func transcribe(fileURL: URL, languageHint: String? = nil) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }

        let samples: [Float]
        do {
            samples = try reader.samples(from: fileURL)
        } catch let failure as AudioFileReader.Failure {
            throw ASREngineError.unsupportedAudioFormat(String(describing: failure))
        }

        try Task.checkCancellation()
        return try await transcribe(samples: samples, languageHint: languageHint)
    }

    /// Распознать готовый буфер.
    ///
    /// Запись уходит в движок целиком, какой бы длинной она ни была: склейку
    /// пятнадцатисекундных окон он делает сам, с перекрытием и дедупликацией
    /// токенов. Раньше здесь стояла собственная нарезка по паузам — она была
    /// написана против молчаливой потери речи на стыке окон. Замер показал, что
    /// причина потери была не в длине куска, а во флаге `melChunkContext`
    /// библиотеки; нарезка же резала фразы посередине, вдвое замедляла разбор и
    /// на главном сценарии (русская речь с английскими вставками) теряла втрое
    /// больше слов, чем правильно настроенный движок. Подробности и цифры — в
    /// `docs/benchmarks.md`.
    public func transcribe(samples: [Float], languageHint: String? = nil) async throws -> ASRResult {
        guard loadedDirectory != nil else { throw ASREngineError.modelsNotLoaded }
        guard !samples.isEmpty else {
            throw ASREngineError.unsupportedAudioFormat("empty recording")
        }

        try Task.checkCancellation()
        return try await engine.transcribe(samples: samples, languageHint: languageHint)
    }

    /// Освободить память под моделью.
    public func unload() async {
        await engine.unload()
        loadedDirectory = nil
    }
}

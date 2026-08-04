import DictationCore
import Foundation

/// Локальное распознавание речи.
///
/// Держит модель загруженной, распознаёт файлы и умеет отпускать память.
///
/// Актор здесь защищает состояние, но **не** очерёдность: акторы реентерабельны,
/// и на каждом `await` внутрь пускается следующий вызов. Правило «одна диктовка
/// за раз» держит машина состояний `DictationController` уровнем выше — она
/// просто не начинает вторую, пока первая не закончилась. Здесь на это
/// полагаться нельзя: если кто-то позовёт `transcribe` дважды, оба разбора
/// пойдут вперемежку, и это будет корректно, но вдвое медленнее.
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

    /// Загрузить или пересобрать акустический подсказчик терминов.
    ///
    /// Отдельно от `prepare`, потому что это отдельная модель с отдельной
    /// судьбой: без неё распознавание полноценно работает, а с ней термины
    /// узнаются на уровне звука, а не пост-обработкой.
    ///
    /// **Зовите это каждый раз, когда изменился словарь пользователя** — не
    /// только при прогреве. Повторный вызов пересобирает набор терминов на
    /// живом движке; веса CTC-модели при этом остаются загруженными, так что
    /// пересборка стоит доли секунды, а не тринадцати. Пустой набор снимает
    /// подсказчик и отпускает его веса.
    ///
    /// Ошибки различаются намеренно: `VocabularyBoostError` — беда со списком
    /// терминов, то есть с данными человека, и восстановление модели её не
    /// лечит; `ASREngineError.modelsUnavailable` — беда с весами, и вот там
    /// перекачка уместна. Ловите их порознь.
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

    /// Живой предпросмотр: старт, поток отсчётов, стоп.
    ///
    /// Молча пропускается, если движок не умеет предпросмотр: это украшение
    /// поверх диктовки, а не её часть — контракт тот же, что у подсказки языка.
    public func startPreview(
        onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
    ) async throws {
        guard let capable = engine as? LivePreviewCapable else { return }
        try await capable.startPreview(onUpdate: onUpdate)
    }

    public func feedPreview(samples: [Float]) async {
        guard let capable = engine as? LivePreviewCapable else { return }
        await capable.feedPreview(samples: samples)
    }

    public func stopPreview() async {
        guard let capable = engine as? LivePreviewCapable else { return }
        await capable.stopPreview()
    }

    /// Освободить память под моделью.
    public func unload() async {
        await engine.unload()
        loadedDirectory = nil
    }
}

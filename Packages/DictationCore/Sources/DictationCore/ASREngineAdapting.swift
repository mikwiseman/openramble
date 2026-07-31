import Foundation

/// Результат распознавания одного фрагмента речи.
///
/// Тип объявлен здесь, а не в LocalASR, намеренно: чистая логика должна уметь
/// работать с результатом, ничего не зная о том, какой движок его произвёл.
public struct ASRResult: Sendable, Equatable {
    /// Одно слово с временными границами относительно начала фрагмента.
    public struct Word: Sendable, Equatable {
        public let text: String
        public let start: TimeInterval
        public let end: TimeInterval
        public let confidence: Double?

        public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    /// Готовый текст без пост-обработки — ровно то, что услышал движок.
    public let text: String
    /// Пословные тайминги. Пустой массив допустим: не всякий движок их отдаёт.
    public let words: [Word]
    /// Длительность распознанного аудио.
    public let audioDuration: TimeInterval
    /// Сколько заняло само распознавание — для замеров и для показа в диагностике.
    public let processingDuration: TimeInterval

    public init(
        text: String,
        words: [Word] = [],
        audioDuration: TimeInterval,
        processingDuration: TimeInterval
    ) {
        self.text = text
        self.words = words
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
    }
}

/// Ошибки движка распознавания.
///
/// Ни один случай не молчаливый: каждая ветка обязана дойти до пользователя.
public enum ASREngineError: Error, Sendable, Equatable {
    /// Модель не загружена — вызов `transcribe` без `prepare`.
    case modelsNotLoaded
    /// Файлы модели отсутствуют или повреждены.
    case modelsUnavailable(String)
    /// Аудио не в том формате, который ожидает движок.
    case unsupportedAudioFormat(String)
    /// Движок отработал, но упал внутри.
    case inferenceFailed(String)
    /// Распознавание отменено пользователем.
    case cancelled
}

/// Контракт движка распознавания.
///
/// Единственная реализация в проекте — `FluidAudioAdapter` в пакете LocalASR,
/// и это единственное место, где импортируется FluidAudio. Всё остальное — включая
/// тесты чистой логики — работает через этот протокол и обходится моком.
public protocol ASREngineAdapting: Sendable {
    /// Загрузить модель из подготовленной директории. Идемпотентно.
    func loadModels(from directory: URL) async throws

    /// Распознать фрагмент. Ожидается моно 16 кГц Float32 — ровно то, что отдаёт захват.
    func transcribe(samples: [Float]) async throws -> ASRResult

    /// Освободить память под моделью.
    func unload() async
}

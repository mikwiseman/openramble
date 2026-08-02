import AVFoundation
import DictationCore
import Foundation

// Подставными в сквозных тестах остаются ровно два края, которых в тесте быть
// не может: микрофон и чужое приложение. Всё между ними — контроллер, чтение
// файла, модель, словарь, доводка текста — настоящее.

/// Захват, который вместо микрофона отдаёт заранее записанный файл.
///
/// Файл настоящий, формат тот же, что пишет `WAVWriter` (моно, 16 кГц, 16 бит),
/// длительность читается из файла, а не назначается: иначе проверка «слишком
/// короткая запись не доходит до распознавания» проверяла бы выдуманное число.
///
/// Каждая сессия получает свою копию фикстуры — контроллер удаляет запись после
/// распознавания, и без копии второй тест не нашёл бы исходника.
actor FixturePlaybackCapture: AudioCapturing {
    private let directory: URL
    private var queue: [URL] = []
    private var lastFixture: URL?
    private var currentTake: URL?

    private(set) var isRecording = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// Все файлы, которые захват отдал контроллеру, — по ним видно, убрал ли он за собой.
    private(set) var takes: [URL] = []
    /// Момент, когда файл записи готов: начало отсчёта «файл готов → текст у вставки».
    private(set) var fileReadyAt: ContinuousClock.Instant?

    init(directory: URL) {
        self.directory = directory
    }

    /// Что «наговорить» в следующих сессиях. Кончится очередь — повторится последняя.
    func enqueue(_ fixtures: [URL]) {
        queue.append(contentsOf: fixtures)
    }

    var leftoverTakes: [URL] {
        takes.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func startRecording() async throws -> URL {
        startCount += 1
        guard !isRecording else { throw AudioCaptureError.engineUnavailable("запись уже идёт") }

        let fixture = queue.isEmpty ? lastFixture : queue.removeFirst()
        guard let fixture else { throw AudioCaptureError.engineUnavailable("нечего проигрывать") }
        lastFixture = fixture

        let take = directory.appending(
            path: "take-\(UUID().uuidString).wav",
            directoryHint: .notDirectory
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixture, to: take)
        } catch {
            throw AudioCaptureError.writeFailed(String(describing: error))
        }

        currentTake = take
        takes.append(take)
        isRecording = true
        return take
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        guard isRecording, let take = currentTake else { throw AudioCaptureError.notRecording }
        isRecording = false
        currentTake = nil

        let duration: TimeInterval
        do {
            let file = try AVAudioFile(forReading: take)
            duration = Double(file.length) / file.fileFormat.sampleRate
        } catch {
            throw AudioCaptureError.writeFailed(String(describing: error))
        }

        fileReadyAt = .now
        return (take, duration)
    }

    /// Гасит «микрофон» и убирает файл — так же, как это делает `MicrophoneCapture`.
    func abortRecording() async {
        abortCount += 1
        isRecording = false
        if let take = currentTake {
            try? FileManager.default.removeItem(at: take)
            currentTake = nil
        }
    }
}

/// Вставка, которая вместо чужого приложения запоминает текст.
actor RecordingInserter: TextInserting {
    struct Insertion: Sendable {
        let text: String
        let target: TargetApplication?
        /// Момент, когда текст дошёл до вставки, — конец отсчёта задержки.
        let at: ContinuousClock.Instant
    }

    private let target: TargetApplication?
    private(set) var insertions: [Insertion] = []
    private(set) var returnPresses = 0

    init(
        target: TargetApplication? = TargetApplication(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 501,
            localizedName: "TextEdit"
        )
    ) {
        self.target = target
    }

    var texts: [String] { insertions.map(\.text) }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        insertions.append(Insertion(text: text, target: target, at: .now))
    }

    func pressReturn() async throws {
        returnPresses += 1
    }

    nonisolated func frontmostApplication() -> TargetApplication? { target }
}

/// Индикатор, который ничего не рисует, но всё помнит.
actor RecordingOverlay: OverlayPresenting {
    private(set) var states: [DictationState] = []
    private(set) var notices: [DictationNotice] = []
    private(set) var dismissCount = 0

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        states.append(state)
    }

    func dismiss() async { dismissCount += 1 }

    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

/// Звуки начала и конца — считаем, но не играем.
actor CountingSounds: Sounding {
    private(set) var startPlays = 0
    private(set) var stopPlays = 0

    func playStart() async { startPlays += 1 }
    func playStop() async { stopPlays += 1 }
}

/// Наблюдатель за настоящим распознаванием.
///
/// Единственная вставка в боевую цепочку, и она ничего не меняет: считает
/// обращения, запоминает поданный файл и сырой ответ модели. Нужна тесту
/// отмены — по счётчику видно, что отмена пришла ПОСЛЕ начала распознавания, —
/// и тесту тишины, где проверяется именно сырой ответ, до словаря и доводки.
actor TranscriptionProbe {
    private(set) var calls = 0
    private(set) var files: [URL] = []
    /// Ответы модели целиком: в них есть и текст, и время разбора.
    private(set) var results: [ASRResult] = []
    private(set) var failures: [String] = []

    /// Сырой текст — до словаря и до доводки.
    var rawTexts: [String] { results.map(\.text) }

    func willStart(_ url: URL) {
        calls += 1
        files.append(url)
    }

    func didFinish(_ result: ASRResult) {
        results.append(result)
    }

    func didFail(_ error: any Error) {
        failures.append(String(describing: error))
    }
}

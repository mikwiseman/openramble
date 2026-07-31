import Foundation

/// Что делать с распознанным текстом, если вставить его не удалось.
public struct RecoveredDictation: Sendable, Equatable {
    public let text: String
    public let file: URL?
}

/// Сохранение текста, который не удалось вставить.
public protocol RecoveryStoring: Sendable {
    /// Записать текст на диск и вернуть адрес файла.
    func save(_ text: String) async throws -> URL
}

/// Ядро диктовки.
///
/// Держит состояние сессии и проводит её от нажатия клавиши до вставки текста.
/// Ничего не знает ни про AppKit, ни про микрофон, ни про модель — всё это
/// приходит снаружи через протоколы, поэтому здесь же и тестируется.
///
/// Инварианты, без которых продукт ломается на первых же пользователях,
/// собраны в отдельных проверках по ходу кода: каждый из них пришёл из
/// реального бага в предшествующем продукте.
@MainActor
public final class DictationController {
    // MARK: - Наблюдаемое состояние

    public private(set) var state: DictationState = .idle {
        didSet {
            // Равенство проверяем намеренно: интерфейс подписан на изменения,
            // а разрешения опрашиваются раз в секунду. Без этой проверки окно
            // настроек перерисовывалось бы каждую секунду.
            guard oldValue != state else { return }
            onStateChange?(state)
        }
    }

    public private(set) var lastError: DictationError?
    public private(set) var pendingRecovery: RecoveredDictation?

    public var onStateChange: (@MainActor (DictationState) -> Void)?
    public var onNotice: (@MainActor (DictationNotice) -> Void)?

    // MARK: - Зависимости

    private let capture: any AudioCapturing
    private let transcribe: @Sendable (URL) async throws -> ASRResult
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let sounds: any Sounding
    private let recovery: any RecoveryStoring
    private let pipeline: () -> TextPipeline

    // MARK: - Состояние сессии

    /// Приложение, в которое вставим текст.
    ///
    /// Снимается в момент нажатия клавиши, а не в конце: пока идёт
    /// распознавание, фокус мог уйти, а текст обязан попасть туда, где диктовали.
    private var targetApplication: TargetApplication?

    /// Отпускание клавиши, пришедшее раньше, чем началась запись.
    ///
    /// Сбрасывается ровно в трёх местах: при старте сессии, при её отмене и в
    /// завершающей уборке. Потерянный флаг оставляет запись включённой.
    private var deferredStopRequested = false

    private var cancellationRequested = false
    private var isHandsFree = false
    private var finalizationTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    public init(
        capture: any AudioCapturing,
        transcribe: @escaping @Sendable (URL) async throws -> ASRResult,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        sounds: any Sounding,
        recovery: any RecoveryStoring,
        pipeline: @escaping () -> TextPipeline = { TextPipeline() }
    ) {
        self.capture = capture
        self.transcribe = transcribe
        self.inserter = inserter
        self.overlay = overlay
        self.sounds = sounds
        self.recovery = recovery
        self.pipeline = pipeline
    }

    // MARK: - Начало

    /// Нажата горячая клавиша.
    public func begin(handsFree: Bool, isEnabled: Bool, isModelReady: Bool) {
        // Первая проверка — синхронная, до всякого ожидания. Между ней и
        // асинхронным стартом успевает пройти повторное нажатие.
        guard DictationStopPolicy.canStart(
            state: state,
            isEnabled: isEnabled,
            isModelReady: isModelReady
        ) else { return }

        isHandsFree = handsFree
        cancellationRequested = false
        deferredStopRequested = false
        lastError = nil
        // Цель запоминаем сразу: потом фокус уйдёт.
        targetApplication = inserter.frontmostApplication()
        state = .preparing

        Task { await startCapture() }
    }

    private func startCapture() async {
        // Вторая проверка того же условия: между синхронной частью и этой
        // строкой прошёл переход между задачами, за который сессию могли отменить.
        guard state == .preparing, !cancellationRequested else {
            await finishWithoutInsertion()
            return
        }

        do {
            _ = try await capture.startRecording()
        } catch {
            await fail(with: .capture(String(describing: error)))
            return
        }

        // После ожидания состояние проверяется снова — отмена могла прийти
        // ровно в момент запуска движка.
        guard state == .preparing, !cancellationRequested else {
            await capture.abortRecording()
            await finishWithoutInsertion()
            return
        }

        recordingStartedAt = Date()
        state = .listening
        // Звук играем только теперь, когда запись реально идёт. Если играть его
        // раньше, пользователь начнёт говорить в ещё не поднятый микрофон и
        // потеряет первое слово.
        await sounds.playStart()
        await overlay.present(.listening, elapsed: 0)

        // Отпускание, пришедшее пока поднимался движок, обрабатываем здесь —
        // ровно один раз.
        if deferredStopRequested {
            deferredStopRequested = false
            finish()
        }
    }

    // MARK: - Остановка

    /// Отпущена горячая клавиша (или нажата второй раз в режиме громкой связи).
    public func stop() {
        switch DictationStopPolicy.decideStop(state: state, isHandsFree: isHandsFree) {
        case .stopNow:
            finish()
        case .deferUntilListening:
            deferredStopRequested = true
        case .ignore, .noSession:
            break
        }
    }

    /// Остановка в режиме громкой связи — вторым нажатием клавиши.
    public func stopHandsFree() {
        guard isHandsFree, state == .listening else { return }
        finish()
    }

    private func finish() {
        // Финализация запускается ровно один раз: иначе текст вставится дважды.
        guard finalizationTask == nil, state == .listening else { return }

        state = .transcribing
        let task = Task { [weak self] in
            await self?.finalize()
            await MainActor.run { self?.finalizationTask = nil }
        }
        finalizationTask = task
    }

    private func finalize() async {
        await overlay.present(.transcribing, elapsed: elapsedSeconds())

        let recording: (url: URL, duration: TimeInterval)
        do {
            recording = try await capture.stopRecording()
        } catch {
            await fail(with: .capture(String(describing: error)))
            return
        }
        await sounds.playStop()

        guard shouldContinue() else {
            await finishWithoutInsertion()
            return
        }

        let recognized: ASRResult
        do {
            recognized = try await transcribe(recording.url)
        } catch is CancellationError {
            await finishWithoutInsertion()
            return
        } catch {
            await fail(with: .recognition(String(describing: error)))
            return
        }

        // Проверка после каждого ожидания: пока шло распознавание, пользователь
        // мог нажать отмену.
        guard shouldContinue() else {
            await finishWithoutInsertion()
            return
        }

        let processed = pipeline().process(recognized.text)
        guard !processed.text.isEmpty else {
            // Пустой результат — не ошибка: человек мог передумать и промолчать.
            await finishWithoutInsertion()
            return
        }

        await insert(processed)
    }

    private func insert(_ output: TextPipeline.Output) async {
        state = .inserting
        await overlay.present(.inserting, elapsed: elapsedSeconds())

        // Последняя точка, где отмена ещё возможна. Дальше событие уходит в
        // чужое приложение и не отзывается.
        guard shouldContinue() else {
            await finishWithoutInsertion()
            return
        }

        do {
            try await inserter.insert(output.text, into: targetApplication)
            if output.command == .pressReturn {
                try await inserter.pressReturn()
            }
            await cleanup()
        } catch {
            await handleInsertionFailure(error, text: output.text)
        }
    }

    /// Текст распознан, но вставить не удалось — сохраняем, чтобы он не пропал.
    private func handleInsertionFailure(_ error: Error, text: String) async {
        let file = try? await recovery.save(text)
        pendingRecovery = RecoveredDictation(text: text, file: file)

        let message: String
        if let insertion = error as? TextInsertionError, insertion == .secureInputActive {
            // Не сбой, а нормальная ситуация: активно поле пароля.
            message = "Текст не вставлен: активен защищённый ввод. Он сохранён."
        } else {
            message = "Текст не удалось вставить. Он сохранён."
        }

        let notice = DictationNotice(kind: .warning, message: message, recoveryFile: file)
        onNotice?(notice)
        await overlay.presentNotice(notice)
        await cleanup()
    }

    // MARK: - Отмена

    /// Отменить диктовку.
    public func cancel() {
        guard DictationStopPolicy.canCancel(state: state) else { return }

        // Порядок важен: сначала флаг, потом отмена задачи. Отмена задачи не
        // прерывает уже идущее ожидание, а флаг проверяется после каждого из них.
        cancellationRequested = true
        finalizationTask?.cancel()

        Task { [weak self] in
            await self?.capture.abortRecording()
            await self?.finishWithoutInsertion()
        }
    }

    // MARK: - Завершение

    private func shouldContinue() -> Bool {
        DictationFinalizationPolicy.shouldContinue(
            state: state,
            cancellationRequested: cancellationRequested,
            taskCancelled: Task.isCancelled
        )
    }

    private func fail(with error: DictationError) async {
        lastError = error
        let notice = DictationNotice(kind: .failure, message: error.userMessage)
        onNotice?(notice)
        await overlay.presentNotice(notice)
        await cleanup()
    }

    private func finishWithoutInsertion() async {
        await cleanup()
    }

    /// Уборка после сессии — в строгом порядке.
    ///
    /// Микрофон гасится здесь и только здесь: обещание «индикатор записи не
    /// горит, пока мы не слушаем» держится на том, что этот метод вызывается
    /// на каждом пути завершения, включая ошибки и отмену.
    private func cleanup() async {
        finalizationTask = nil
        deferredStopRequested = false
        cancellationRequested = false
        isHandsFree = false
        targetApplication = nil
        recordingStartedAt = nil
        state = .idle
        await overlay.dismiss()
    }

    private func elapsedSeconds() -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    /// Достигнут ли предел длительности — проверяется таймером снаружи.
    public func checkDurationLimit() {
        guard state == .listening else { return }
        if DictationDurationPolicy.action(elapsed: elapsedSeconds()) == .stopAndTranscribe {
            onNotice?(
                DictationNotice(
                    kind: .info,
                    message: "Достигнут предел в час. Распознаю записанное."
                )
            )
            finish()
        }
    }
}

/// Ошибки, которые видит пользователь.
public enum DictationError: Error, Sendable, Equatable {
    case capture(String)
    case recognition(String)
    case insertion(String)

    public var userMessage: String {
        switch self {
        case .capture:
            return "Не удалось записать звук."
        case .recognition:
            return "Не удалось распознать речь."
        case .insertion:
            return "Не удалось вставить текст."
        }
    }
}

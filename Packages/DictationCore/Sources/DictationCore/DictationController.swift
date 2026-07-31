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
    /// Сообщает, идёт ли запись без удержания: от этого зависит, как
    /// истолковать следующее нажатие клавиши.
    public var onHandsFreeChange: (@MainActor (Bool) -> Void)?

    /// Идёт ли запись без удержания клавиши.
    public private(set) var isHandsFreeActive = false {
        didSet {
            guard oldValue != isHandsFreeActive else { return }
            onHandsFreeChange?(isHandsFreeActive)
        }
    }

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

    /// Номер текущей сессии — растёт на каждом старте.
    ///
    /// Отмена не прерывает уже начатое ожидание, а только помечает его:
    /// распознавание дочитывает свой буфер и просыпается позже — когда человек
    /// успел начать следующую диктовку. Без номера такой хвост доводил уборку до
    /// конца и гасил ЧУЖУЮ, живую сессию: состояние показывало «свободно», а
    /// микрофон оставался включённым, и выйти из этого было нечем.
    private var currentSession = 0

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

        currentSession += 1
        let session = currentSession
        isHandsFree = handsFree
        isHandsFreeActive = handsFree
        cancellationRequested = false
        deferredStopRequested = false
        lastError = nil
        // Цель запоминаем сразу: потом фокус уйдёт.
        targetApplication = inserter.frontmostApplication()
        state = .preparing

        Task { await startCapture(session: session) }
    }

    private func startCapture(session: Int) async {
        // Вторая проверка того же условия: между синхронной частью и этой
        // строкой прошёл переход между задачами, за который сессию могли отменить.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            await finishWithoutInsertion(session: session)
            return
        }

        do {
            _ = try await capture.startRecording()
        } catch {
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }

        // После ожидания состояние проверяется снова — отмена могла прийти
        // ровно в момент запуска движка.
        guard isCurrent(session), state == .preparing, !cancellationRequested else {
            // Запись успела пойти, а сессии уже нет. Свой микрофон гасим —
            // иначе он останется включённым, и остановить его будет нечем, —
            // но уборку не делаем: она принадлежит той сессии, что идёт сейчас.
            await capture.abortRecording()
            await finishWithoutInsertion(session: session)
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

    /// Остановка в режиме без удержания — вторым нажатием клавиши.
    public func stopHandsFree() {
        guard isHandsFree else { return }

        switch state {
        case .listening:
            finish()
        case .preparing:
            // То же самое, что и с отпусканием клавиши, только нажатием: второе
            // нажатие успело прийти раньше, чем поднялся движок. Потерять его
            // нельзя — в этом режиме клавишу не держат, и остановить запись
            // больше нечем: микрофон работал бы до часового предела.
            deferredStopRequested = true
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// Перевести идущую сессию в режим без удержания.
    ///
    /// Двойное нажатие приходит уже после того, как первое запустило сессию, а
    /// первое отпускание попыталось её закончить. Начать новую в этот момент
    /// нельзя — она бы не прошла проверку на свободное состояние, и режим
    /// оставался бы недостижимым. Поэтому переключаем текущую.
    ///
    /// Отложенное отпускание сбрасывается: оно относилось к прошлому жесту, а в
    /// новом режиме клавишу и положено отпускать.
    public func promoteToHandsFree() {
        guard state == .preparing || state == .listening else { return }
        isHandsFree = true
        isHandsFreeActive = true
        deferredStopRequested = false
    }

    private func finish() {
        // Финализация запускается ровно один раз: иначе текст вставится дважды.
        guard finalizationTask == nil, state == .listening else { return }

        let session = currentSession
        state = .transcribing
        let task = Task { [weak self] in
            await self?.finalize(session: session)
            await MainActor.run { self?.forgetFinalization(session: session) }
        }
        finalizationTask = task
    }

    /// Забыть завершившуюся задачу — но только если это всё ещё наша сессия.
    private func forgetFinalization(session: Int) {
        guard isCurrent(session) else { return }
        finalizationTask = nil
    }

    private func finalize(session: Int) async {
        await overlay.present(.transcribing, elapsed: elapsedSeconds())

        let recording: (url: URL, duration: TimeInterval)
        do {
            recording = try await capture.stopRecording()
        } catch {
            await fail(session: session, with: .capture(String(describing: error)))
            return
        }

        // Запись удаляется, чем бы дело ни кончилось, — поэтому удаление стоит
        // сразу за её получением, до всех проверок. Она нужна только на время
        // распознавания: хранить голос пользователя дольше — и лишний расход
        // диска, и совсем не то, чего от приватного продукта ждут.
        defer { discard(recording.url) }

        await sounds.playStop()

        guard shouldContinue(session) else {
            await finishWithoutInsertion(session: session)
            return
        }

        // Нажал и сразу отпустил — распознавать нечего. Движок на таких
        // записях отказывается работать, но показывать из-за этого ошибку
        // неправильно: человек просто передумал.
        guard DictationDurationPolicy.isWorthTranscribing(duration: recording.duration) else {
            await finishWithoutInsertion(session: session)
            return
        }

        let recognized: ASRResult
        do {
            recognized = try await transcribe(recording.url)
        } catch is CancellationError {
            await finishWithoutInsertion(session: session)
            return
        } catch let error as ASREngineError where error == .cancelled {
            // Отмена, дошедшая через движок: это не сбой, сообщать не о чем.
            await finishWithoutInsertion(session: session)
            return
        } catch {
            await fail(session: session, with: .recognition(String(describing: error)))
            return
        }

        // Проверка после каждого ожидания: пока шло распознавание, пользователь
        // мог нажать отмену.
        guard shouldContinue(session) else {
            await finishWithoutInsertion(session: session)
            return
        }

        let processed = pipeline().process(recognized.text)
        guard !processed.text.isEmpty else {
            // Пустой результат — не ошибка: человек мог передумать и промолчать.
            await finishWithoutInsertion(session: session)
            return
        }

        await insert(processed, session: session)
    }

    private func insert(_ output: TextPipeline.Output, session: Int) async {
        state = .inserting
        await overlay.present(.inserting, elapsed: elapsedSeconds())

        // Последняя точка, где отмена ещё возможна. Дальше событие уходит в
        // чужое приложение и не отзывается.
        guard shouldContinue(session) else {
            await finishWithoutInsertion(session: session)
            return
        }

        do {
            try await inserter.insert(output.text, into: targetApplication)
        } catch {
            await handleInsertionFailure(error, text: output.text, session: session)
            return
        }

        // Нажатие разбирается отдельно от вставки намеренно. Это разные
        // системные вызовы, и второй отказывает при живом первом — например,
        // когда пользователь так и не отпустил модификатор.
        if output.command == .pressReturn {
            do {
                try await inserter.pressReturn()
            } catch {
                await reportReturnFailure(session: session)
                return
            }
        }
        await cleanup(session: session)
    }

    /// Текст вставлен, а Return нажать не вышло.
    ///
    /// Общая ветка отказа здесь соврала бы дважды: сказала бы «текст не
    /// вставлен», когда он на месте, и сохранила бы вторую копию продиктованного
    /// на диск. Приватный инструмент не складывает сказанное без причины.
    private func reportReturnFailure(session: Int) async {
        let notice = DictationNotice(
            kind: .warning,
            message: "Текст вставлен, но нажать Return не удалось."
        )
        onNotice?(notice)
        await overlay.presentNotice(notice)
        await cleanup(session: session)
    }

    /// Текст распознан, но вставить не удалось — сохраняем, чтобы он не пропал.
    private func handleInsertionFailure(_ error: Error, text: String, session: Int) async {
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
        await cleanup(session: session)
    }

    // MARK: - Отмена

    /// Отменить диктовку.
    public func cancel() {
        guard DictationStopPolicy.canCancel(state: state) else { return }

        // Порядок важен: сначала флаг, потом отмена задачи. Отмена задачи не
        // прерывает уже идущее ожидание, а флаг проверяется после каждого из них.
        cancellationRequested = true
        finalizationTask?.cancel()

        let session = currentSession
        Task { [weak self] in
            await self?.capture.abortRecording()
            await self?.finishWithoutInsertion(session: session)
        }
    }

    /// Запись сорвалась сама — например, на диске кончилось место.
    ///
    /// Это не отмена: пользователь ничего не нажимал и продолжает говорить.
    /// Поэтому останавливаемся сразу и объясняем причину, а не ждём, пока он
    /// договорит фразу, которую уже некуда записывать.
    public func interrupt(reason message: String) {
        guard state == .preparing || state == .listening else { return }

        cancellationRequested = true
        finalizationTask?.cancel()

        let notice = DictationNotice(kind: .failure, message: message)
        onNotice?(notice)

        let session = currentSession
        Task { [weak self] in
            guard let self else { return }
            await self.overlay.presentNotice(notice)
            await self.capture.abortRecording()
            await self.finishWithoutInsertion(session: session)
        }
    }

    // MARK: - Завершение

    /// Идёт ли ещё та сессия, ради которой начиналось ожидание.
    private func isCurrent(_ session: Int) -> Bool { session == currentSession }

    private func shouldContinue(_ session: Int) -> Bool {
        guard isCurrent(session) else { return false }
        return DictationFinalizationPolicy.shouldContinue(
            state: state,
            cancellationRequested: cancellationRequested,
            taskCancelled: Task.isCancelled
        )
    }

    private func fail(session: Int, with error: DictationError) async {
        // Сбой отменённой сессии показывать не за что: человек её уже закрыл, а
        // сообщение упало бы поверх той, что идёт сейчас.
        guard isCurrent(session) else { return }

        lastError = error
        let notice = DictationNotice(kind: .failure, message: error.userMessage)
        onNotice?(notice)
        await overlay.presentNotice(notice)
        await cleanup(session: session)
    }

    private func finishWithoutInsertion(session: Int) async {
        await cleanup(session: session)
    }

    /// Уборка после сессии — в строгом порядке.
    ///
    /// Микрофон гасится здесь и только здесь: обещание «индикатор записи не
    /// горит, пока мы не слушаем» держится на том, что этот метод вызывается
    /// на каждом пути завершения, включая ошибки и отмену.
    ///
    /// Убирать разрешено только за собственной сессией: хвост предыдущей,
    /// проснувшийся после отмены, иначе погасил бы уже идущую новую.
    private func cleanup(session: Int) async {
        guard isCurrent(session) else { return }

        finalizationTask = nil
        deferredStopRequested = false
        cancellationRequested = false
        isHandsFree = false
        isHandsFreeActive = false
        targetApplication = nil
        recordingStartedAt = nil
        state = .idle
        await overlay.dismiss()
    }

    private func elapsedSeconds() -> TimeInterval {
        guard let recordingStartedAt else { return 0 }
        return Date().timeIntervalSince(recordingStartedAt)
    }

    /// Убрать запись с диска.
    ///
    /// Отдельным методом, чтобы удаление нельзя было случайно пропустить на
    /// одной из веток завершения: голос пользователя не должен оставаться в
    /// файлах после того, как текст распознан.
    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
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

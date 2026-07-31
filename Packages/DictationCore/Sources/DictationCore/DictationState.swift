import Foundation

/// Состояние сессии диктовки.
///
/// Порядок строгий: `idle → preparing → listening → transcribing → inserting → idle`.
/// Отмена возможна из любого состояния до `inserting` — начиная с него текст уже
/// уходит в чужое приложение, и отматывать нечего.
public enum DictationState: Sendable, Equatable {
    /// Ничего не происходит, микрофон выключен, индикатор записи погашен.
    case idle
    /// Клавиша нажата, поднимаем звуковой движок. Занимает десятки миллисекунд.
    case preparing
    /// Идёт запись.
    case listening
    /// Клавиша отпущена, распознаём записанное.
    case transcribing
    /// Вставляем готовый текст в активное приложение.
    case inserting

    /// Занята ли сессия — новую в это время начинать нельзя.
    public var isBusy: Bool { self != .idle }

    /// Слышит ли микрофон прямо сейчас.
    ///
    /// От этого зависит честность обещания «индикатор гаснет, когда мы не слушаем»:
    /// звуковой движок обязан быть выключен во всех остальных состояниях.
    public var isCapturing: Bool { self == .listening }
}

/// Что делать с отпусканием клавиши, пришедшим раньше, чем сессия успела начаться.
///
/// Пользователь нажимает и отпускает быстрее, чем поднимается звуковой движок —
/// это норма для короткой фразы. Отпускание нельзя потерять, иначе диктовка
/// «залипнет» в режиме записи.
public enum DeferredStopDecision: Sendable, Equatable {
    /// Обычная остановка: запись уже идёт.
    case stopNow
    /// Запомнить и остановиться, как только запись начнётся.
    case deferUntilListening
    /// Игнорировать: в режиме громкой связи отпускание клавиши ничего не значит.
    case ignore
    /// Сессии нет — реагировать не на что.
    case noSession
}

public enum DictationStopPolicy {
    /// Решить, что делать с отпусканием горячей клавиши.
    public static func decideStop(
        state: DictationState,
        isHandsFree: Bool
    ) -> DeferredStopDecision {
        // В режиме громкой связи запись останавливается вторым нажатием,
        // а не отпусканием — иначе она обрывалась бы сразу после старта.
        if isHandsFree { return .ignore }

        switch state {
        case .idle:
            return .noSession
        case .preparing:
            // Главный случай, ради которого всё это существует: клавишу успели
            // отпустить, пока поднимался движок.
            return .deferUntilListening
        case .listening:
            return .stopNow
        case .transcribing, .inserting:
            // Финализация уже идёт — второй раз её запускать нельзя.
            return .ignore
        }
    }

    /// Можно ли начинать новую сессию.
    public static func canStart(state: DictationState, isEnabled: Bool, isModelReady: Bool) -> Bool {
        isEnabled && isModelReady && state == .idle
    }

    /// Можно ли ещё отменить происходящее.
    ///
    /// После начала вставки отменять нечего: событие клавиатуры уже отправлено
    /// в другое приложение и не отзывается.
    public static func canCancel(state: DictationState) -> Bool {
        switch state {
        case .idle, .inserting:
            return false
        case .preparing, .listening, .transcribing:
            return true
        }
    }
}

/// Продолжать ли доводить сессию до вставки.
///
/// Проверяется после каждого ожидания в цепочке завершения: пользователь мог
/// нажать отмену, пока шло распознавание.
public enum DictationFinalizationPolicy {
    public static func shouldContinue(
        state: DictationState,
        cancellationRequested: Bool,
        taskCancelled: Bool
    ) -> Bool {
        guard !cancellationRequested, !taskCancelled else { return false }
        switch state {
        case .transcribing, .inserting:
            return true
        case .idle, .preparing, .listening:
            return false
        }
    }
}

/// Ограничение длительности одной диктовки.
public enum DictationDurationPolicy {
    /// Короче этого распознавать нечего.
    ///
    /// Движок отказывается работать с записями меньше 300 мс, но дело не только
    /// в нём: человек, нажавший и сразу отпустивший клавишу, просто передумал.
    /// Показывать ему ошибку распознавания — значит пугать на ровном месте.
    public static let minimum: TimeInterval = 0.35

    /// Есть ли что распознавать.
    public static func isWorthTranscribing(duration: TimeInterval) -> Bool {
        duration >= minimum
    }

    /// Час — предел одной сессии.
    ///
    /// Ограничение не продуктовое, а инженерное: запись копится в памяти и на
    /// диске, а распознавание часовой записи занимает заметное время. По
    /// достижении предела запись останавливается сама и распознаётся — сказанное
    /// не теряется.
    public static let maximum: TimeInterval = 3600

    public enum Action: Sendable, Equatable {
        case keepRecording
        case stopAndTranscribe
    }

    public static func action(elapsed: TimeInterval) -> Action {
        elapsed >= maximum ? .stopAndTranscribe : .keepRecording
    }
}

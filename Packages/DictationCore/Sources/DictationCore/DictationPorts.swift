import Foundation

/// Границы между чистой логикой диктовки и системой.
///
/// Всё, что требует AppKit, микрофона или чужих приложений, живёт за этими
/// протоколами. Благодаря им контроллер тестируется обычным `swift test`
/// за миллисекунды и не трогает ни звуковой движок, ни чужие окна.

// MARK: - Захват звука

/// Запись с микрофона в файл.
public protocol AudioCapturing: Sendable {
    /// Начать запись. Возвращает адрес файла, в который она идёт.
    ///
    /// Реализация обязана поднять движок синхронно: любая задержка здесь — это
    /// срезанное первое слово.
    func startRecording() async throws -> URL

    /// Остановить запись и дописать файл на диск.
    ///
    /// Возвращает адрес готового файла и длительность записанного.
    func stopRecording() async throws -> (url: URL, duration: TimeInterval)

    /// Прервать запись и удалить файл — пользователь отменил диктовку.
    func abortRecording() async
}

public enum AudioCaptureError: Error, Sendable, Equatable {
    case microphonePermissionDenied
    case engineUnavailable(String)
    case diskFull
    case writeFailed(String)
    case notRecording
}

// MARK: - Вставка текста

/// Куда вставлять и как.
public protocol TextInserting: Sendable {
    /// Вставить текст туда, где стоял курсор в момент начала диктовки.
    func insert(_ text: String, into target: TargetApplication?) async throws

    /// Нажать Return — если пользователь закончил фразу командой «отправь».
    func pressReturn() async throws

    /// Приложение, которое было активно на момент нажатия горячей клавиши.
    ///
    /// Снимается в начале сессии, а не в конце: пока идёт распознавание, фокус
    /// мог уйти, а текст должен попасть туда, где его диктовали.
    func frontmostApplication() -> TargetApplication?
}

/// Приложение-получатель.
public struct TargetApplication: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32
    public let localizedName: String?

    public init(bundleIdentifier: String?, processIdentifier: Int32, localizedName: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
    }
}

public enum TextInsertionError: Error, Sendable, Equatable {
    case accessibilityPermissionDenied
    /// Активен защищённый ввод — поле пароля или терминал с защитой клавиатуры.
    /// Вставлять туда нельзя, и это не сбой, а нормальная ситуация.
    case secureInputActive
    case clipboardWriteFailed
    /// Пользователь не отпустил модификаторы, и нажатие превратилось бы в чужое сочетание.
    case modifiersStillHeld
    case targetUnavailable
}

// MARK: - Обратная связь

/// Индикатор состояния диктовки.
public protocol OverlayPresenting: Sendable {
    /// Показать состояние. Вызывается на каждом переходе.
    func present(_ state: DictationState, elapsed: TimeInterval) async

    /// Убрать индикатор.
    func dismiss() async

    /// Показать сообщение, которое нельзя пропустить — например, что текст
    /// не удалось вставить и он сохранён в файл.
    func presentNotice(_ notice: DictationNotice) async
}

/// Сообщение пользователю.
public struct DictationNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case info
        case warning
        case failure
    }

    public let kind: Kind
    public let message: String
    /// Файл, в который сохранён текст, если вставить не удалось.
    public let recoveryFile: URL?

    public init(kind: Kind, message: String, recoveryFile: URL? = nil) {
        self.kind = kind
        self.message = message
        self.recoveryFile = recoveryFile
    }
}

/// Звуковые подтверждения начала и конца.
public protocol Sounding: Sendable {
    /// Играется, когда запись реально пошла.
    ///
    /// Именно «когда пошла», а не «когда нажали»: иначе пользователь начнёт
    /// говорить в ещё не запущенный микрофон.
    func playStart() async
    func playStop() async
}

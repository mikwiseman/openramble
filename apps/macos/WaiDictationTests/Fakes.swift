import AppKit
import DictationAudio
import DictationCore
import Foundation

// Подставные края системы.
//
// Исходники приложения компилируются прямо в тестовый бандл, поэтому импорта
// приложения здесь нет: всё лежит в одном модуле.

/// Общий журнал вызовов.
///
/// Нужен там, где важен порядок между разными краями: например, фокус обязан
/// вернуться раньше, чем мы тронем буфер обмена.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(entry)
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Источник событий клавиатуры

@MainActor
final class FakeHotkeyEventSource: HotkeyEventSource {
    var isTrusted = true
    /// Отдавать ли токен подписки. `false` — система отказала.
    var grantsFlagsMonitor = true
    var grantsKeyMonitor = true

    private(set) var flagsMonitorCount = 0
    private(set) var keyMonitorCount = 0
    private(set) var removedTokens: [String] = []

    private var flagsHandler: (@MainActor (HotkeyEvent) -> Void)?
    private var keyHandler: (@MainActor (HotkeyEvent) -> Void)?

    /// Сколько подписок сейчас живо.
    var liveMonitorCount: Int {
        flagsMonitorCount + keyMonitorCount - removedTokens.count
    }

    func addFlagsMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        guard grantsFlagsMonitor else { return nil }
        flagsMonitorCount += 1
        flagsHandler = handler
        return "flags-\(flagsMonitorCount)"
    }

    func addKeyDownMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        guard grantsKeyMonitor else { return nil }
        keyMonitorCount += 1
        keyHandler = handler
        return "keys-\(keyMonitorCount)"
    }

    func removeMonitor(_ token: Any) {
        removedTokens.append(token as? String ?? "?")
    }

    /// Прислать событие модификаторов, как это сделала бы система.
    func sendFlags(_ event: HotkeyEvent) {
        flagsHandler?(event)
    }

    func sendKeyDown(_ event: HotkeyEvent) {
        keyHandler?(event)
    }
}

// MARK: - Края вставки текста

/// Подставные края системы для вставки.
///
/// Класс с замком, а не актор: методы `InputSystem` синхронные — так их и
/// вызывает вставка, — а синхронно к актору не обратиться.
final class FakeInputSystem: InputSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var secureInput = false
    private var trusted = true
    private var frontmost: TargetApplication?
    private var activateResult = true
    /// Что вернёт `heldModifiers()` на каждом обращении. Последний элемент
    /// повторяется дальше.
    private var heldPlan: [CGEventFlags] = [[]]
    private var heldCalls = 0
    private var postError: TextInsertionError?
    private var posted: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []

    let log: CallLog

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    // MARK: Настройка

    func setSecureInput(_ value: Bool) { withLock { secureInput = value } }
    func setTrusted(_ value: Bool) { withLock { trusted = value } }
    func setFrontmost(_ value: TargetApplication?) { withLock { frontmost = value } }
    func setActivateResult(_ value: Bool) { withLock { activateResult = value } }
    func setHeldPlan(_ plan: [CGEventFlags]) { withLock { heldPlan = plan.isEmpty ? [[]] : plan } }
    func setPostError(_ error: TextInsertionError?) { withLock { postError = error } }

    // MARK: Наблюдение

    var postedKeys: [(keyCode: CGKeyCode, flags: CGEventFlags)] { withLock { posted } }
    var heldModifiersCallCount: Int { withLock { heldCalls } }

    // MARK: InputSystem

    var isSecureInputEnabled: Bool { withLock { secureInput } }
    var isAccessibilityTrusted: Bool { withLock { trusted } }

    func frontmostApplication() -> TargetApplication? { withLock { frontmost } }

    func heldModifiers() -> CGEventFlags {
        withLock {
            let value = heldPlan[min(heldCalls, heldPlan.count - 1)]
            heldCalls += 1
            return value
        }
    }

    func activate(_ target: TargetApplication) async -> Bool {
        log.record("activate")
        return withLock { activateResult }
    }

    func post(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        log.record("post")
        if let error = withLock({ postError }) { throw error }
        withLock { posted.append((keyCode, flags)) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakePasteboard: DictationPasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var error: TextInsertionError?

    let log: CallLog

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    func setError(_ error: TextInsertionError?) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }

    var writtenTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func writeHostOnly(_ text: String) throws {
        log.record("pasteboard")
        lock.lock()
        let failure = error
        if failure == nil { written.append(text) }
        lock.unlock()
        if let failure { throw failure }
    }
}

// MARK: - Края диктовки

actor FakeCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    private let file = URL(fileURLWithPath: "/tmp/wai-dictation-test-take.wav")

    func startRecording() async throws -> URL {
        startCount += 1
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        return (file, 2.0)
    }

    func abortRecording() async { abortCount += 1 }
}

actor FakeInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    nonisolated(unsafe) var frontmost: TargetApplication?

    func insert(_ text: String, into target: TargetApplication?) async throws {
        insertedTexts.append(text)
    }

    func pressReturn() async throws { returnPresses += 1 }

    nonisolated func frontmostApplication() -> TargetApplication? { frontmost }
}

actor FakeOverlay: OverlayPresenting {
    private(set) var presentedStates: [DictationState] = []
    private(set) var notices: [DictationNotice] = []
    private(set) var dismissCount = 0

    func present(_ state: DictationState, elapsed: TimeInterval) async {
        presentedStates.append(state)
    }

    func dismiss() async { dismissCount += 1 }

    func presentNotice(_ notice: DictationNotice) async { notices.append(notice) }
}

// MARK: - Разрешения и монитор клавиши

@MainActor
final class FakePermissions: PermissionReading {
    var accessibilityGranted: Bool
    var microphoneGranted: Bool

    init(accessibility: Bool = true, microphone: Bool = true) {
        accessibilityGranted = accessibility
        microphoneGranted = microphone
    }
}

@MainActor
final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onSingleTapWhileHandsFree: (() -> Void)?
    var onEscape: (() -> Void)?

    var isHandsFreeActive = false
    private(set) var isRunning = false
    private(set) var hotkey: DictationHotkey?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func setHotkey(_ hotkey: DictationHotkey) { self.hotkey = hotkey }

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

import AppKit
import DictationAudio
import DictationCore
import Foundation
import LocalASR

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
    /// Слышит ли микрофон прямо сейчас.
    ///
    /// На этом держится обещание «индикатор записи гаснет, когда мы не слушаем»:
    /// проверять его надо не по состоянию на экране, а по тому, закрыт ли захват.
    private(set) var isRecording = false
    /// Что вернуть как длительность записи.
    ///
    /// Короче предела — и сессия закончится без распознавания. Так проверяется
    /// полный круг диктовки, не трогая настоящую модель.
    private var duration: TimeInterval = 2.0

    private let file = URL(fileURLWithPath: "/tmp/wai-dictation-test-take.wav")

    func setDuration(_ value: TimeInterval) { duration = value }

    func startRecording() async throws -> URL {
        startCount += 1
        isRecording = true
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        isRecording = false
        return (file, duration)
    }

    func abortRecording() async {
        abortCount += 1
        isRecording = false
    }
}

actor FakeInserter: TextInserting {
    private(set) var insertedTexts: [String] = []
    private(set) var returnPresses = 0
    nonisolated(unsafe) var frontmost: TargetApplication?
    /// Чем отказать. Отказ вставки — не редкость: защищённый ввод, отозванный
    /// доступ, закрывшееся окно получателя.
    private var error: TextInsertionError?

    func setError(_ error: TextInsertionError?) { self.error = error }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if let error { throw error }
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

// MARK: - Приложение целиком

/// Подставное окружение приложения.
///
/// Собрано в одном месте, чтобы разные наборы проверок не разъезжались в том,
/// каким приложение видит компьютер. Центры уведомлений здесь свои, не
/// системные: проверка не должна ни слышать настоящий сон машины, ни будить
/// чужих подписчиков.
@MainActor
final class AppHarness {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let permissions = FakePermissions()
    let monitor = FakeHotkeyMonitor()
    let overlay = FakeOverlay()
    let capture = FakeCapture()
    let inserter = FakeInserter()
    let workspaceNotifications = NotificationCenter()
    let notifications = NotificationCenter()
    let downloader = BlockingModelDownloader()

    /// Ноль — опрос разрешений выключен: в проверке они меняются нами, а не
    /// системой.
    var permissionPollInterval: TimeInterval = 0

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(
                path: "wai-dictation-harness-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        suiteName = "is.waiwai.dictation.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.defaults = defaults

        Self.sweepStaleTestDomains(except: suiteName)
    }

    /// Подмести файлы настроек, оставшиеся от прошлых прогонов.
    ///
    /// Уборка в конце теста забирает не всё: служба настроек выписывает
    /// опустевший файл на диск уже после того, как тест закончился, и успеть за
    /// ней нельзя. Поэтому подметаем в начале — к этому моменту всё прошлое уже
    /// дописано. Без этого каждый прогон оставлял по паре десятков файлов в
    /// личной папке разработчика, и за время работы их накопилось под тысячу.
    private static func sweepStaleTestDomains(except current: String) {
        guard let library = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }

        let preferences = library.appending(path: "Preferences", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: preferences,
            includingPropertiesForKeys: nil
        ) else { return }

        let prefix = "is.waiwai.dictation.tests."
        for entry in entries
        where entry.lastPathComponent.hasPrefix(prefix)
            && entry.lastPathComponent != "\(current).plist" {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        // Домен убран из настроек, но файл остаётся: служба настроек всё равно
        // выпишет опустевший plist на диск. Один прогон — один файл; за время
        // работы над проектом их накопилось под тысячу. Убираем и файл тоже.
        if let preferences = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let file = preferences
                .appending(path: "Preferences", directoryHint: .isDirectory)
                .appending(path: "\(suiteName).plist", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// Что «услышит» распознавание. Настоящей модели в тесте нет, а без ответа
    /// диктовка обрывалась бы на полпути и путь до вставки остался бы непроверенным.
    let transcription = FakeTranscription()

    func makeState() -> AppState {
        AppState(
            environment: AppEnvironment(
                defaults: defaults,
                paths: AppPaths(root: root),
                permissions: permissions,
                hotkeyMonitor: monitor,
                inserter: inserter,
                overlay: overlay,
                makeCapture: { [capture] _, _ in capture },
                transcribe: { [transcription] _ in
                    { _ in
                        if let error = transcription.error { throw error }
                        return ASRResult(
                            text: transcription.text,
                            audioDuration: 2,
                            processingDuration: 0.05
                        )
                    }
                },
                permissionPollInterval: permissionPollInterval,
                modelDownloader: downloader,
                workspaceNotifications: workspaceNotifications,
                notifications: notifications
            )
        )
    }

    /// Разложить на диске метку готовой модели.
    ///
    /// Настоящая установка — это 483 МБ по сети. Готовность же определяется
    /// одним файлом, и его достаточно, чтобы пройти путь «модель на месте».
    func installModelMarker() throws {
        let paths = AppPaths(root: root)
        let manifest = try ModelManifest.bundled()
        let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
        try FileManager.default.createDirectory(
            at: layout.installedDirectory,
            withIntermediateDirectories: true
        )
        let marker = ModelReadyMarker(manifest: manifest, verifiedAt: Date())
        try JSONEncoder().encode(marker).write(to: layout.readyMarker)
    }
}

// MARK: - Голос интерфейса

/// Подставной VoiceOver.
///
/// Настоящие объявления уходят в систему и обратно не возвращаются: без этой
/// подмены нельзя проверить ни одного из них, а для незрячего человека они и
/// есть весь интерфейс диктовки.
@MainActor
final class FakeAnnouncer: AccessibilityAnnouncing {
    private(set) var announcements: [(message: String, urgent: Bool)] = []

    var messages: [String] { announcements.map(\.message) }

    func announce(_ message: String, urgent: Bool) {
        announcements.append((message, urgent))
    }
}

// MARK: - Загрузка модели

/// Загрузчик, который никуда не идёт и не отпускает, пока не разрешат.
///
/// Нужен, чтобы поймать приложение в состоянии «идёт загрузка» и посмотреть,
/// что с ним в этот момент делают другие экраны.
final class BlockingModelDownloader: ModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false

    var hasStarted: Bool { lock.withLock { started } }

    func release() { lock.withLock { released = true } }

    func download(
        from url: URL,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        lock.withLock { started = true }

        onProgress(expectedBytes / 2)

        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(5))
        }

        // Отпущенная загрузка заканчивается отменой: доводить установку до
        // проверки сумм здесь не на чем — настоящих файлов модели нет.
        throw ModelDownloadError.cancelled
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


/// Заранее известный ответ распознавания.
final class FakeTranscription: @unchecked Sendable {
    var text = "Проверка связи"
    var error: (any Error)?
}

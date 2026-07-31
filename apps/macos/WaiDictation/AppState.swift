import AppKit
import DictationAudio
import DictationCore
import Foundation
import LocalASR
import SwiftUI

/// Края системы, из которых собирается приложение.
///
/// Здесь ровно то, что в тесте трогать нельзя: настройки пользователя, папки на
/// диске, выданные разрешения, микрофон, чужие приложения и экран. В приложении
/// подставляются настоящие реализации, в тесте — подставные.
@MainActor
public struct AppEnvironment {
    public var defaults: UserDefaults
    public var paths: AppPaths
    public var permissions: any PermissionReading
    public var hotkeyMonitor: any HotkeyMonitoring
    public var inserter: any TextInserting
    public var overlay: any OverlayPresenting
    public var makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void) -> any AudioCapturing
    /// Как часто опрашивать разрешения. Ноль — не опрашивать.
    public var permissionPollInterval: TimeInterval

    public init(
        defaults: UserDefaults,
        paths: AppPaths,
        permissions: any PermissionReading,
        hotkeyMonitor: any HotkeyMonitoring,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        makeCapture: @escaping (URL, @escaping @Sendable (AudioCaptureError) -> Void) -> any AudioCapturing,
        permissionPollInterval: TimeInterval
    ) {
        self.defaults = defaults
        self.paths = paths
        self.permissions = permissions
        self.hotkeyMonitor = hotkeyMonitor
        self.inserter = inserter
        self.overlay = overlay
        self.makeCapture = makeCapture
        self.permissionPollInterval = permissionPollInterval
    }

    /// Настоящие края — то, из чего собирается работающее приложение.
    public static func system() -> AppEnvironment {
        AppEnvironment(
            defaults: .standard,
            paths: .standard(),
            permissions: SystemPermissions(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            inserter: TextInserter(),
            overlay: DictationOverlay(),
            makeCapture: { MicrophoneCapture(directory: $0, onFailure: $1) },
            permissionPollInterval: 1
        )
    }
}

/// Всё состояние приложения в одном месте.
///
/// Связывает горячую клавишу, захват звука, распознавание и вставку. Сама
/// логика диктовки живёт в `DictationController` — здесь только подключение
/// системных краёв и то, что видит интерфейс.
@MainActor
public final class AppState: ObservableObject {
    // Показывается в интерфейсе.
    @Published public private(set) var dictationState: DictationState = .idle
    @Published public private(set) var modelState: ModelState = .notInstalled
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var lastNotice: DictationNotice?
    @Published public private(set) var isPreparingEngine = false
    /// Идёт ли запись без удержания клавиши — показывается в меню.
    @Published public private(set) var isHandsFreeActive = false

    /// Что не так со словарём. Пока не `nil`, словарь заблокирован на запись.
    @Published public private(set) var dictionaryProblem: ReplacementsStore.Problem?

    // Настройки.
    @Published public var hotkey: DictationHotkey {
        didSet {
            guard oldValue != hotkey else { return }
            defaults.set(hotkey.rawValue, forKey: Keys.hotkey)
            hotkeyMonitor.setHotkey(hotkey)
        }
    }

    @Published public var soundsEnabled: Bool {
        didSet {
            guard oldValue != soundsEnabled else { return }
            defaults.set(soundsEnabled, forKey: Keys.sounds)
        }
    }

    /// Словарь замен. Меняется только через методы ниже: прямая запись обошла
    /// бы проверку на то, что словарь вообще можно сохранять.
    @Published public private(set) var replacements: [DictionaryReplacement]

    private enum Keys {
        static let hotkey = "hotkey"
        static let sounds = "soundsEnabled"
        static let replacements = "replacements"
        /// Глобальная настройка macOS: что делает нажатие 🌐.
        static let fnUsage = "AppleFnUsageType"
    }

    private let defaults: UserDefaults
    private let paths: AppPaths
    private let permissions: any PermissionReading
    private let hotkeyMonitor: any HotkeyMonitoring
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void) -> any AudioCapturing
    private let permissionPollInterval: TimeInterval
    private let replacementsStore: ReplacementsStore

    /// Обновления. Отдельный объект со своими подписчиками: галочка
    /// автопроверки живёт в настройках Sparkle, а не в наших `defaults`.
    public let updater = SparkleUpdater()

    private var store: ModelStore?
    private var transcriber: LocalTranscriber?
    private var controller: DictationController?
    private var permissionTimer: Timer?
    private var durationTimer: Timer?

    public var isDictationReady: Bool {
        accessibilityGranted && microphoneGranted && modelState.isReady
    }

    /// Предупреждение о выбранной клавише, если оно есть.
    public var hotkeyWarning: String? {
        HotkeyAdvice.warning(
            for: hotkey,
            fnUsage: FnKeyUsage(rawValue: defaults.object(forKey: Keys.fnUsage) as? Int)
        )
    }

    public convenience init() {
        self.init(environment: .system())
    }

    public init(environment: AppEnvironment) {
        defaults = environment.defaults
        paths = environment.paths
        permissions = environment.permissions
        hotkeyMonitor = environment.hotkeyMonitor
        inserter = environment.inserter
        overlay = environment.overlay
        makeCapture = environment.makeCapture
        permissionPollInterval = environment.permissionPollInterval
        replacementsStore = ReplacementsStore(
            defaults: environment.defaults,
            key: Keys.replacements
        )

        hotkey = DictationHotkey(rawValue: environment.defaults.string(forKey: Keys.hotkey) ?? "")
            ?? .rightCommand
        soundsEnabled = environment.defaults.object(forKey: Keys.sounds) as? Bool ?? true

        let loaded = replacementsStore.load()
        replacements = loaded.replacements
        dictionaryProblem = loaded.problem

        setUp()

        // Сообщаем уже после сборки: до неё показывать сообщение было бы некуда.
        if let problem = loaded.problem {
            notify(DictationNotice(kind: .warning, message: problem.message))
        }
    }

    // MARK: - Сборка

    private func setUp() {
        let sounds = SystemSounds(enabled: { [weak self] in self?.soundsEnabled ?? true })

        do {
            let capture = makeCapture(try paths.takes()) { [weak self] _ in
                // Диск кончился или файл стал недоступен посреди речи. Ждать
                // остановки нельзя — человек говорит в пустоту.
                Task { @MainActor in
                    self?.controller?.interrupt(
                        reason: "Не удалось записать звук — проверьте свободное место на диске."
                    )
                }
            }
            let recovery = RecoveryStore(directory: try paths.recovery())

            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            let store = ModelStore(manifest: manifest, layout: layout)
            let transcriber = LocalTranscriber()
            self.store = store
            self.transcriber = transcriber

            let engineDirectory = layout.engineDirectory
            let controller = DictationController(
                capture: capture,
                transcribe: { url in
                    try await transcriber.prepare(modelDirectory: engineDirectory)
                    return try await transcriber.transcribe(fileURL: url)
                },
                inserter: inserter,
                overlay: overlay,
                sounds: sounds,
                recovery: recovery,
                pipeline: { [weak self] in
                    TextPipeline(replacements: self?.replacements ?? [])
                }
            )
            controller.onStateChange = { [weak self] state in
                self?.dictationState = state
                self?.updateDurationTimer(for: state)
            }
            controller.onNotice = { [weak self] notice in
                self?.lastNotice = notice
            }
            controller.onHandsFreeChange = { [weak self] active in
                // Монитору нужно знать режим: в нём одиночное нажатие означает
                // «останови», а не «начни новую диктовку».
                self?.hotkeyMonitor.isHandsFreeActive = active
                self?.isHandsFreeActive = active
            }
            self.controller = controller
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Не удалось подготовить рабочие папки: \(error.localizedDescription)"
                )
            )
        }

        wireHotkey()
        refreshPermissions()
        // Записи, уцелевшие после падения приложения: обычно каталог пуст, но
        // без уборки такой файл пролежал бы там навсегда.
        paths.sweepAbandonedTakes()
        Task { await refreshModelState() }

        // Разрешения выдаются в системных настройках, без уведомления приложению,
        // поэтому состояние приходится опрашивать.
        guard permissionPollInterval > 0 else { return }
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: permissionPollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    private func wireHotkey() {
        hotkeyMonitor.setHotkey(hotkey)
        hotkeyMonitor.onPress = { [weak self] in
            guard let self else { return }
            self.controller?.begin(
                handsFree: false,
                isEnabled: self.isDictationReady,
                isModelReady: self.modelState.isReady
            )
        }
        hotkeyMonitor.onRelease = { [weak self] in
            self?.controller?.stop()
        }
        hotkeyMonitor.onDoubleTap = { [weak self] in
            guard let self else { return }

            switch self.dictationState {
            case .preparing, .listening:
                // Сессия уже идёт — первое нажатие её запустило. Переводим её в
                // режим без удержания вместо того, чтобы начинать новую: новая
                // всё равно не началась бы, потому что эта ещё не закончилась.
                self.controller?.promoteToHandsFree()
            case .idle:
                self.controller?.begin(
                    handsFree: true,
                    isEnabled: self.isDictationReady,
                    isModelReady: self.modelState.isReady
                )
            case .transcribing, .inserting:
                break
            }
        }
        hotkeyMonitor.onSingleTapWhileHandsFree = { [weak self] in
            self?.controller?.stopHandsFree()
        }
        hotkeyMonitor.onEscape = { [weak self] in
            // Escape отменяет только идущую диктовку. В остальное время это
            // обычная клавиша, и перехватывать её нельзя.
            guard let self, self.dictationState != .idle else { return }
            self.controller?.cancel()
        }
    }

    /// Показать сообщение человеку.
    ///
    /// Через оверлей, а не только полем `lastNotice`: его ни одно окно не
    /// показывает, и сообщения вроде «сейчас идёт диктовка» не доходили вовсе.
    private func notify(_ notice: DictationNotice) {
        lastNotice = notice
        Task { await overlay.presentNotice(notice) }
    }

    // MARK: - Разрешения

    public func refreshPermissions() {
        let accessibility = permissions.accessibilityGranted
        let microphone = permissions.microphoneGranted

        // Проверяем на изменение: интерфейс подписан на эти поля, а опрос идёт
        // раз в секунду.
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if microphone != microphoneGranted { microphoneGranted = microphone }

        // Монитор регистрируется заново при каждой проверке: система начинает
        // отдавать ему события только после выдачи доступа, и без повторного
        // запуска клавиша молчала бы до перезапуска приложения.
        if accessibility {
            hotkeyMonitor.start()
        } else {
            hotkeyMonitor.stop()
        }
    }

    public func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    public func requestMicrophone() {
        Task {
            _ = await Permissions.requestMicrophone()
            refreshPermissions()
        }
    }

    // MARK: - Модель

    public func refreshModelState() async {
        guard let store else { return }
        modelState = await store.refreshState()
    }

    public func installModel() {
        guard let store else { return }
        Task {
            let states = await store.states()
            let monitor = Task { @MainActor in
                for await state in states { modelState = state }
            }
            await store.install()
            monitor.cancel()
            await refreshModelState()

            // Первая загрузка компилирует модель под нейромодуль и занимает
            // секунды. Делаем это сразу, чтобы пользователь не ждал в момент
            // первой диктовки.
            if modelState.isReady { await warmUpEngine() }
        }
    }

    public func deleteModel() {
        // Идёт диктовка — модель сейчас в работе. Удалять её из-под себя значит
        // потерять уже сказанное и показать вместо этого ошибку загрузки.
        //
        // Проверка стоит раньше остальных намеренно: человеку нужен ответ на
        // своё нажатие, а не молчание из-за того, что чего-то нет внутри.
        guard dictationState == .idle else {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Сейчас идёт диктовка. Дождитесь её окончания."
                )
            )
            return
        }
        guard let store else { return }
        Task {
            await transcriber?.unload()
            await store.delete()
            await refreshModelState()
        }
    }

    private func warmUpEngine() async {
        guard let transcriber, let store else { return }
        guard case .ready = await store.currentState() else { return }
        isPreparingEngine = true
        defer { isPreparingEngine = false }

        do {
            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
        } catch {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Модель установлена, но не загрузилась: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Предел длительности

    private func updateDurationTimer(for state: DictationState) {
        durationTimer?.invalidate()
        durationTimer = nil
        guard state == .listening else { return }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller?.checkDurationLimit() }
        }
    }

    // MARK: - Словарь

    /// Можно ли сейчас менять словарь.
    ///
    /// Нельзя ровно в одном случае: прежний словарь не прочитался. Тогда любая
    /// запись затёрла бы его целиком — и человек потерял бы всё накопленное.
    public var isDictionaryEditable: Bool { dictionaryProblem == nil }

    public func addReplacement(spoken: String, written: String) {
        let spoken = spoken.trimmingCharacters(in: .whitespaces)
        let written = written.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        updateReplacements(replacements + [DictionaryReplacement(spoken: spoken, written: written)])
    }

    public func removeReplacements(at offsets: IndexSet) {
        var updated = replacements
        updated.remove(atOffsets: offsets)
        updateReplacements(updated)
    }

    /// Добавить готовый набор терминов разработчика.
    ///
    /// Модель пишет англицизмы так, как слышит их в русской речи: «pull request»
    /// становится «пул реквест». Набор возвращает им обычный вид. Уже заведённые
    /// пользователем замены не трогаем — своё важнее заготовки.
    public func addStarterDictionary() {
        updateReplacements(replacements + StarterDictionary.missing(from: replacements))
    }

    /// Сколько заготовленных терминов ещё не добавлено.
    public var availableStarterCount: Int {
        StarterDictionary.missing(from: replacements).count
    }

    private func updateReplacements(_ updated: [DictionaryReplacement]) {
        guard let problem = dictionaryProblem else {
            do {
                try replacementsStore.save(updated)
            } catch {
                // Не сохранилось — значит и в памяти менять нельзя: список на
                // экране разошёлся бы с тем, что на диске, и человек узнал бы об
                // этом только после перезапуска.
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Словарь не сохранён: \(error.localizedDescription)"
                    )
                )
                return
            }
            replacements = updated
            return
        }

        notify(DictationNotice(kind: .warning, message: problem.message))
    }
}

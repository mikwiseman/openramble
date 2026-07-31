import AppKit
import DictationAudio
import DictationCore
import Foundation
import LocalASR
import SwiftUI

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

    @Published public var replacements: [DictionaryReplacement] {
        didSet { saveReplacements() }
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let sounds = "soundsEnabled"
        static let replacements = "replacements"
    }

    private let defaults = UserDefaults.standard
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private let overlay = DictationOverlay()

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

    public init() {
        hotkey = DictationHotkey(rawValue: defaults.string(forKey: Keys.hotkey) ?? "")
            ?? .rightCommand
        soundsEnabled = defaults.object(forKey: Keys.sounds) as? Bool ?? true
        replacements = Self.loadReplacements(from: defaults)

        setUp()
    }

    // MARK: - Сборка

    private func setUp() {
        let sounds = SystemSounds(enabled: { [weak self] in self?.soundsEnabled ?? true })

        do {
            let capture = MicrophoneCapture(directory: try AppPaths.takes())
            let recovery = RecoveryStore(directory: try AppPaths.recovery())

            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try AppPaths.models())
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
                inserter: TextInserter(),
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
            self.controller = controller
        } catch {
            lastNotice = DictationNotice(
                kind: .failure,
                message: "Не удалось подготовить рабочие папки: \(error.localizedDescription)"
            )
        }

        wireHotkey()
        refreshPermissions()
        // Записи, уцелевшие после падения приложения: обычно каталог пуст, но
        // без уборки такой файл пролежал бы там навсегда.
        AppPaths.sweepAbandonedTakes()
        Task { await refreshModelState() }

        // Разрешения выдаются в системных настройках, без уведомления приложению,
        // поэтому состояние приходится опрашивать.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
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
            // Второе быстрое нажатие включает режим громкой связи: клавишу
            // можно отпустить, запись продолжится до следующего нажатия.
            if self.dictationState == .listening {
                self.controller?.stopHandsFree()
            } else {
                self.controller?.begin(
                    handsFree: true,
                    isEnabled: self.isDictationReady,
                    isModelReady: self.modelState.isReady
                )
            }
        }
        hotkeyMonitor.onEscape = { [weak self] in
            // Escape отменяет только идущую диктовку. В остальное время это
            // обычная клавиша, и перехватывать её нельзя.
            guard let self, self.dictationState != .idle else { return }
            self.controller?.cancel()
        }
    }

    // MARK: - Разрешения

    public func refreshPermissions() {
        let accessibility = Permissions.accessibility == .granted
        let microphone = Permissions.microphone == .granted

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
        guard let store else { return }
        Task {
            await transcriber?.unload()
            await store.delete()
            await refreshModelState()
        }
    }

    private func warmUpEngine() async {
        guard let transcriber, let store else { return }
        guard case let .ready(directory) = await store.currentState() else { return }
        _ = directory
        isPreparingEngine = true
        defer { isPreparingEngine = false }

        do {
            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try AppPaths.models())
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
        } catch {
            lastNotice = DictationNotice(
                kind: .warning,
                message: "Модель установлена, но не загрузилась: \(error.localizedDescription)"
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

    private func saveReplacements() {
        guard let data = try? JSONEncoder().encode(replacements) else { return }
        defaults.set(data, forKey: Keys.replacements)
    }

    private static func loadReplacements(from defaults: UserDefaults) -> [DictionaryReplacement] {
        guard let data = defaults.data(forKey: Keys.replacements),
              let decoded = try? JSONDecoder().decode([DictionaryReplacement].self, from: data)
        else { return [] }
        return decoded
    }

    public func addReplacement(spoken: String, written: String) {
        let spoken = spoken.trimmingCharacters(in: .whitespaces)
        let written = written.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        replacements.append(DictionaryReplacement(spoken: spoken, written: written))
    }

    public func removeReplacements(at offsets: IndexSet) {
        replacements.remove(atOffsets: offsets)
    }

    /// Сколько заготовленных терминов ещё не добавлено.
    public var availableStarterCount: Int {
        StarterDictionary.missing(from: replacements).count
    }

    /// Добавить готовый набор терминов разработчика.
    ///
    /// Модель пишет англицизмы так, как слышит их в русской речи: «pull request»
    /// становится «пул реквест». Набор возвращает им обычный вид. Уже заведённые
    /// пользователем замены не трогаем — своё важнее заготовки.
    public func addStarterDictionary() {
        replacements.append(contentsOf: StarterDictionary.missing(from: replacements))
    }
}

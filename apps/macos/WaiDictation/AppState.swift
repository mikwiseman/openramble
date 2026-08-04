import AVFoundation
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
    public var accessibilityManager: any AccessibilityManaging
    public var hotkeyMonitor: any HotkeyMonitoring
    public var inserter: any TextInserting
    public var overlay: any OverlayPresenting
    public var makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void) -> any AudioCapturing
    /// Чем распознавать. Такой же край системы, как микрофон и вставка: в
    /// приложении это модель на диске, в тесте — заранее известный ответ. Без
    /// этого шва путь диктовки целиком в приложении нельзя было проверить
    /// вовсе — тесты доходили только до начала записи.
    public var transcribe: (URL) -> @Sendable (URL) async throws -> ASRResult
    /// Как часто опрашивать разрешения в самом занятом режиме. Ноль — не опрашивать.
    public var permissionPollInterval: TimeInterval
    /// Чем скачивать модель. Единственная сеть, которая есть у приложения.
    public var modelDownloader: any ModelDownloading
    /// Уведомления рабочего стола: сон и пробуждение.
    public var workspaceNotifications: NotificationCenter
    /// Общий центр уведомлений: оттуда приходит смена аудиоустройства.
    public var notifications: NotificationCenter
    /// Единственный production instance движка. В тестах `nil`: там ASR
    /// подставлен через `transcribe` и настоящая модель не нужна.
    public var localTranscriber: LocalTranscriber?

    public init(
        defaults: UserDefaults,
        paths: AppPaths,
        permissions: any PermissionReading,
        accessibilityManager: any AccessibilityManaging,
        hotkeyMonitor: any HotkeyMonitoring,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        makeCapture: @escaping (URL, @escaping @Sendable (AudioCaptureError) -> Void) -> any AudioCapturing,
        transcribe: @escaping (URL) -> @Sendable (URL) async throws -> ASRResult,
        permissionPollInterval: TimeInterval,
        modelDownloader: any ModelDownloading,
        workspaceNotifications: NotificationCenter,
        notifications: NotificationCenter,
        localTranscriber: LocalTranscriber? = nil
    ) {
        self.defaults = defaults
        self.paths = paths
        self.permissions = permissions
        self.accessibilityManager = accessibilityManager
        self.hotkeyMonitor = hotkeyMonitor
        self.inserter = inserter
        self.overlay = overlay
        self.makeCapture = makeCapture
        self.transcribe = transcribe
        self.permissionPollInterval = permissionPollInterval
        self.modelDownloader = modelDownloader
        self.workspaceNotifications = workspaceNotifications
        self.notifications = notifications
        self.localTranscriber = localTranscriber
    }

    /// Настоящие края — то, из чего собирается работающее приложение.
    public static func system() -> AppEnvironment {
        let transcriber = LocalTranscriber()
        return AppEnvironment(
            defaults: .standard,
            paths: .standard(),
            permissions: SystemPermissions(),
            accessibilityManager: SystemAccessibilityManager(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            inserter: TextInserter(),
            overlay: DictationOverlay(),
            makeCapture: { MicrophoneCapture(directory: $0, onFailure: $1) },
            transcribe: { engineDirectory in
                return { url in
                    try await transcriber.prepare(modelDirectory: engineDirectory)
                    return try await transcriber.transcribe(fileURL: url)
                }
            },
            permissionPollInterval: 1,
            modelDownloader: URLSessionModelDownloader(),
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            notifications: .default,
            localTranscriber: transcriber
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
    @Published public private(set) var accessibilityState: AccessibilityPermissionState = .denied
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var lastNotice: DictationNotice?
    @Published public private(set) var isPreparingEngine = false
    @Published public private(set) var isEngineReady = false

    /// Текст неудачной вставки. Никогда не пишется на диск.
    @Published public private(set) var recoveredText: String?
    /// WAV после технической ошибки, доступный для Retry/Delete.
    @Published public private(set) var recoveredRecording: URL?
    /// Идёт ли запись без удержания клавиши — показывается в меню.
    @Published public private(set) var isHandsFreeActive = false
    /// Только успешная вставка считается пройденной пробой в онбординге.
    @Published public private(set) var successfulDictationCount = 0

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

    /// Маркер переживает relaunch. Если новый процесс всё ещё не trusted,
    /// повторять перезапуск бессмысленно — нужен явный repair старой TCC-записи.
    static let accessibilityRelaunchPendingKey = "accessibilityRelaunchPending"

    private let defaults: UserDefaults
    private let paths: AppPaths
    private let permissions: any PermissionReading
    private let accessibilityManager: any AccessibilityManaging
    private let hotkeyMonitor: any HotkeyMonitoring
    private let inserter: any TextInserting
    private let overlay: any OverlayPresenting
    private let makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void) -> any AudioCapturing
    private let transcribe: (URL) -> @Sendable (URL) async throws -> ASRResult
    private let permissionPollInterval: TimeInterval
    private let modelDownloader: any ModelDownloading
    private let workspaceNotifications: NotificationCenter
    private let notifications: NotificationCenter
    private let replacementsStore: ReplacementsStore

    /// Обновления. Отдельный объект со своими подписчиками: галочка
    /// автопроверки живёт в настройках Sparkle, а не в наших `defaults`.
    public let updater = SparkleUpdater()

    private var store: ModelStore?
    private var transcriber: LocalTranscriber?
    private var recordingRecovery: RecordingRecoveryStore?
    private var engineDirectory: URL?
    private var controller: DictationController?
    /// Идёт ли установка модели прямо сейчас.
    private var isInstalling = false
    /// Отказ Core ML при прогреве. Файлы на диске при этом целы, поэтому осмотр
    /// диска отказа не видит — состояние держится здесь до явного восстановления.
    private var engineLoadFailure: String?
    /// Retry/Delete recovery выполняются по одному и блокируют hotkey.
    private var isRecoveryOperationActive = false
    /// Сообщение, которое ждёт конца сессии.
    private var noticeAfterSession: DictationNotice?
    private var didCompleteInitialPermissionRefresh = false

    // Таймеры и подписки помечены `nonisolated(unsafe)`, потому что их снимает
    // `deinit`, а он у изолированного класса — вне изоляции. Трогают их только
    // с главного потока: приложение целиком живёт на нём.
    nonisolated(unsafe) private var permissionTimer: Timer?
    nonisolated(unsafe) private var durationTimer: Timer?
    nonisolated(unsafe) private var systemObservers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    public var isDictationReady: Bool {
        accessibilityGranted && microphoneGranted && modelState.isReady && isEngineReady
    }

    /// Как часто сейчас опрашиваются разрешения. Ноль — опрос не идёт.
    ///
    /// Наружу видно намеренно: обещание «в покое приложение ничего не делает»
    /// проверяется именно этим числом.
    public private(set) var permissionPollingInterval: TimeInterval = 0

    public var isPollingPermissions: Bool { permissionTimer != nil }

    /// Идёт ли проверка предела длительности. В покое её быть не должно.
    public var isCountingDuration: Bool { durationTimer != nil }

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
        accessibilityManager = environment.accessibilityManager
        hotkeyMonitor = environment.hotkeyMonitor
        inserter = environment.inserter
        overlay = environment.overlay
        makeCapture = environment.makeCapture
        transcribe = environment.transcribe
        permissionPollInterval = environment.permissionPollInterval
        modelDownloader = environment.modelDownloader
        workspaceNotifications = environment.workspaceNotifications
        notifications = environment.notifications
        transcriber = environment.localTranscriber
        // Тестовые окружения подставляют готовое ASR-замыкание и не нуждаются
        // в Core ML warmup. Production всегда передаёт shared transcriber.
        isEngineReady = environment.localTranscriber == nil
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

    deinit {
        // Таймер, оставленный в цикле выполнения, продолжает будить процесс и
        // после смерти владельца: слабая ссылка внутри спасает от падения, но
        // не от пробуждений.
        permissionTimer?.invalidate()
        durationTimer?.invalidate()
        for observer in systemObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: - Сборка

    private func setUp() {
        let sounds = SystemSounds(enabled: { [weak self] in self?.soundsEnabled ?? true })

        do {
            let capture = makeCapture(try paths.takes()) { [weak self] error in
                // Аудиопоток перестал быть пригодным посреди речи. Ждать остановки
                // нельзя: человек говорит в пустоту, а причина должна быть показана точно.
                Task { @MainActor in
                    self?.controller?.interrupt(
                        reason: Self.captureFailureMessage(error)
                    )
                }
            }
            let recordingRecovery = RecordingRecoveryStore(directory: try paths.audioRecovery())
            self.recordingRecovery = recordingRecovery

            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            let store = ModelStore(manifest: manifest, layout: layout, downloader: modelDownloader)
            self.store = store

            let engineDirectory = layout.engineDirectory
            self.engineDirectory = engineDirectory
            let controller = DictationController(
                capture: capture,
                transcribe: transcribe(engineDirectory),
                inserter: inserter,
                overlay: overlay,
                sounds: sounds,
                recordingRecovery: recordingRecovery,
                pipeline: { [weak self] in
                    TextPipeline(replacements: self?.replacements ?? [])
                }
            )
            controller.onStateChange = { [weak self] state in
                self?.dictationState = state
                self?.updateDurationTimer(for: state)
                self?.flushNoticeAfterSession(state)
            }
            controller.onNotice = { [weak self] notice in
                self?.lastNotice = notice
                if let text = notice.recoverableText { self?.recoveredText = text }
                if let audio = notice.recoveryAudio { self?.recoveredRecording = audio }
                // Ядро само объяснилось. Своё объяснение поверх его слов было бы
                // хуже молчания: у сессии одна причина конца, а не две.
                self?.noticeAfterSession = nil
            }
            controller.onHandsFreeChange = { [weak self] active in
                // Монитору нужно знать режим: в нём одиночное нажатие означает
                // «останови», а не «начни новую диктовку».
                self?.hotkeyMonitor.isHandsFreeActive = active
                self?.isHandsFreeActive = active
            }
            controller.onTextInserted = { [weak self] in
                self?.successfulDictationCount += 1
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
        observeSystemEvents()
        refreshPermissions()
        Task {
            removeLegacyTextRecovery()
            await importAbandonedRecordings()
            await refreshModelState()
            if modelState.isReady { await warmUpEngine() }
        }
    }

    /// Старые сборки писали нераспознанный текст на диск в `Recovered/`.
    /// Теперь такой текст живёт только в памяти, и обещание «распознанный текст
    /// не пишется на диск» обязано покрывать и следы прошлых версий.
    private func removeLegacyTextRecovery() {
        guard let support = try? paths.support() else { return }
        let legacy = support.appending(path: "Recovered", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacy)
        } catch {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Не удалось удалить тексты recovery старой версии. "
                        + "Удалите вручную: ~/Library/Application Support/WaiDictation/Recovered"
                )
            )
        }
    }

    static func captureFailureMessage(_ error: AudioCaptureError) -> String {
        switch error {
        case .unsupportedAudioFormat(let detail):
            return "Не удалось обработать аудиоформат выбранного микрофона: \(detail)"
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону. Откройте Системные настройки."
        case .engineUnavailable(let detail):
            return "Микрофон перестал отвечать: \(detail)"
        case .diskFull:
            return "Не удалось записать звук: на диске нет свободного места."
        case .writeFailed(let detail):
            return "Не удалось записать звук: \(detail)"
        case .notRecording:
            return "Запись неожиданно остановилась."
        }
    }

    private func importAbandonedRecordings() async {
        guard let recordingRecovery else { return }
        do {
            let result = try await recordingRecovery.importAbandoned(from: paths.takes())
            recoveredRecording = result.recordings.first
            if recoveredRecording != nil {
                notify(
                    DictationNotice(
                        kind: result.discardedCorruptCount == 0 ? .warning : .failure,
                        message: result.discardedCorruptCount == 0
                            ? "После прерывания найдена локальная запись — можно повторить распознавание или удалить."
                            : "Одна запись сохранена для повтора. Повреждённый фрагмент восстановить нельзя, он удалён.",
                        recoveryAudio: recoveredRecording
                    )
                )
            } else if result.discardedCorruptCount > 0 {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Незавершённая запись была повреждена: восстановить её нельзя, фрагмент удалён."
                    )
                )
            }
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Не удалось подготовить восстановление записи: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Copy / Retry / Delete recovery

    public func copyRecoveredText() {
        guard let recoveredText else { return }
        do {
            try HostOnlyPasteboard().copyHostOnly(recoveredText)
            notify(DictationNotice(kind: .info, message: "Текст скопирован только на этот Mac."))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Не удалось скопировать текст."))
        }
    }

    public func retryRecoveredText() {
        guard dictationState == .idle,
              !isRecoveryOperationActive,
              let recoveredText
        else { return }
        let target = inserter.frontmostApplication()
        isRecoveryOperationActive = true
        dictationState = .inserting
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.dictationState = .idle
                self.isRecoveryOperationActive = false
            }
            await overlay.present(.inserting, elapsed: 0)
            do {
                try await inserter.insert(recoveredText, into: target)
                self.recoveredText = nil
                await overlay.dismiss()
            } catch {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Повторная вставка не выполнена — текст всё ещё доступен через Copy/Retry.",
                        recoverableText: recoveredText
                    )
                )
            }
        }
    }

    public func deleteRecoveredText() {
        guard !isRecoveryOperationActive else { return }
        recoveredText = nil
    }

    public func retryRecoveredRecording() {
        guard dictationState == .idle,
              !isRecoveryOperationActive,
              modelState.isReady,
              let url = recoveredRecording,
              let engineDirectory,
              let recordingRecovery
        else { return }
        let target = inserter.frontmostApplication()

        isRecoveryOperationActive = true
        dictationState = .transcribing
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.dictationState = .idle
                self.isRecoveryOperationActive = false
            }
            await overlay.present(.transcribing, elapsed: 0)
            let recognizedText: String
            do {
                let result = try await transcribe(engineDirectory)(url)
                let output = TextPipeline(replacements: replacements).process(result.text)
                guard !output.text.isEmpty else { throw ASREngineError.inferenceFailed("пустой результат") }
                recognizedText = output.text
            } catch {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Повторное распознавание не удалось. Запись сохранена локально.",
                        recoveryAudio: url
                    )
                )
                return
            }

            dictationState = .inserting
            await overlay.present(.inserting, elapsed: 0)
            do {
                try await inserter.insert(recognizedText, into: target)
            } catch {
                recoveredText = recognizedText
                do {
                    try await recordingRecovery.delete(url)
                    recoveredRecording = try await recordingRecovery.recordings().first
                    notify(
                        DictationNotice(
                            kind: .warning,
                            message: "Запись распознана, но текст не вставлен — доступны Copy и Retry.",
                            recoverableText: recognizedText
                        )
                    )
                } catch {
                    recoveredRecording = url
                    notify(
                        DictationNotice(
                            kind: .failure,
                            message: "Текст доступен через Copy/Retry, но локальную WAV удалить не удалось: \(error.localizedDescription)",
                            recoverableText: recognizedText,
                            recoveryAudio: url
                        )
                    )
                }
                return
            }

            do {
                try await recordingRecovery.delete(url)
                recoveredRecording = try await recordingRecovery.recordings().first
                await overlay.dismiss()
            } catch {
                recoveredRecording = url
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Текст вставлен, но локальную WAV удалить не удалось: \(error.localizedDescription)",
                        recoveryAudio: url
                    )
                )
            }
        }
    }

    public func deleteRecoveredRecording() {
        guard !isRecoveryOperationActive, let url = recoveredRecording else { return }
        isRecoveryOperationActive = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRecoveryOperationActive = false }
            do {
                try await recordingRecovery?.delete(url)
                recoveredRecording = try await recordingRecovery?.recordings().first
            } catch {
                notify(DictationNotice(kind: .failure, message: "Не удалось удалить локальную запись."))
            }
        }
    }

    /// Подписаться на то, что происходит с компьютером помимо нас.
    ///
    /// Обе подписки существуют ради одного и того же: диктовка не должна
    /// оставаться включённой, когда слушать уже нечем.
    private func observeSystemEvents() {
        observe(workspaceNotifications, NSWorkspace.willSleepNotification) { $0.handleSleep() }
        observe(workspaceNotifications, NSWorkspace.didWakeNotification) { $0.handleWake() }
        observe(notifications, .AVAudioEngineConfigurationChange) { $0.handleAudioConfigurationChange() }
        observe(notifications, NSApplication.didBecomeActiveNotification) {
            $0.handleApplicationBecameActive()
        }
    }

    private func handleApplicationBecameActive() {
        let wasWaitingForSettings = accessibilityState == .waitingForSettings
        refreshPermissions()
        if wasWaitingForSettings, !accessibilityGranted,
           accessibilityState != .repairRequired {
            accessibilityState = .restartRequired
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        handler: @escaping @MainActor (AppState) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            // Смена аудиоустройства приходит с потока звукового движка, сон —
            // с главного. Общий переход на главный поток дешевле, чем разбор,
            // откуда именно нас позвали.
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
        }
        systemObservers.append((center, token))
    }

    /// Компьютер уходит в сон.
    ///
    /// Отпускание клавиши, случившееся во сне, до нас не дойдёт: система не
    /// присылает событий спящей машины. Без остановки сессия осталась бы в
    /// «слушаю» навсегда — с включённым микрофоном и горящим индикатором
    /// записи, и выйти из этого можно было бы только через Escape.
    private func handleSleep() {
        switch dictationState {
        case .listening:
            // Сказанное до сна уже записано. Распознаём его, а не выбрасываем.
            noticeAfterSession = DictationNotice(
                kind: .info,
                message: "Компьютер уходил в сон — запись пришлось остановить."
            )
            stopCurrentRecording()
        case .preparing:
            // Записать ещё ничего не успели — терять нечего.
            controller?.cancel()
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// Компьютер проснулся.
    ///
    /// Клавишу за время сна успели отпустить, а события об этом не было:
    /// монитор до сих пор считает её зажатой и следующее нажатие проглотит.
    /// Перезапуск слежения — единственное, что стирает память о начатом жесте.
    private func handleWake() {
        hotkeyMonitor.stop()
        refreshPermissions()
    }

    /// Аудиоустройство сменилось посреди записи.
    ///
    /// Наушники вынули, монитор с микрофоном отключили — движок остаётся
    /// запущенным, но кадры в него больше не приходят. Человек говорит в
    /// тишину и узнаёт об этом только по пустому результату.
    private func handleAudioConfigurationChange() {
        guard dictationState == .listening else { return }
        controller?.preserveActiveRecording(
            reason: "Микрофон или аудиоустройство отключено. Диктовка остановлена."
        )
    }

    /// Сказать то, что ждало конца сессии.
    ///
    /// Сразу сказать нельзя: следом за остановкой ядро перерисовывает панель
    /// под «распознаю», и объяснение живёт на экране доли секунды. А сказать
    /// надо — иначе непонятно, почему запись оборвалась на полуслове.
    private func flushNoticeAfterSession(_ state: DictationState) {
        guard state == .idle, let pending = noticeAfterSession else { return }
        noticeAfterSession = nil
        notify(pending)
    }

    /// Закончить идущую запись так, как её закончил бы человек.
    ///
    /// В режиме без удержания отпускание клавиши ничего не значит, и обычная
    /// остановка была бы проигнорирована — запись продолжалась бы в никуда.
    private func stopCurrentRecording() {
        if isHandsFreeActive {
            controller?.stopHandsFree()
        } else {
            controller?.stop()
        }
    }

    /// Видимая кнопка в menu bar: пользователь не обязан помнить жест.
    public func finishCurrentDictation() {
        guard !isRecoveryOperationActive,
              dictationState == .preparing || dictationState == .listening
        else { return }
        stopCurrentRecording()
    }

    /// Общая безопасная отмена для Escape и menu bar.
    public func cancelCurrentDictation() {
        guard !isRecoveryOperationActive, dictationState != .idle else { return }
        controller?.cancel()
        notify(DictationNotice(kind: .info, message: "Диктовка отменена. Запись удалена."))
    }

    private func wireHotkey() {
        hotkeyMonitor.setHotkey(hotkey)
        hotkeyMonitor.onPress = { [weak self] in
            guard let self else { return }
            guard !self.isRecoveryOperationActive else { return }
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
            self?.cancelCurrentDictation()
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
        let previousAccessibility = accessibilityGranted
        let previousMicrophone = microphoneGranted

        // Проверяем на изменение: интерфейс подписан на эти поля, а сюда
        // приходят и по таймеру, и с каждым открытием настроек.
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if microphone != microphoneGranted { microphoneGranted = microphone }

        if accessibility {
            accessibilityState = .granted
            defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
        } else if defaults.bool(forKey: Self.accessibilityRelaunchPendingKey) {
            accessibilityState = .repairRequired
        } else {
            switch accessibilityState {
            case .waitingForSettings, .restartRequired, .repairRequired, .repairing, .failed:
                break
            case .denied, .granted:
                accessibilityState = .denied
            }
        }

        if !didCompleteInitialPermissionRefresh {
            didCompleteInitialPermissionRefresh = true
            if !accessibility || !microphone {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Диктовка выключена: выдайте Универсальный доступ и доступ к микрофону в Системных настройках."
                    )
                )
            }
        } else if previousAccessibility, !accessibility {
            if dictationState == .preparing || dictationState == .listening {
                controller?.preserveActiveRecording(
                    reason: "Отозван Универсальный доступ. Диктовка остановлена; откройте Системные настройки."
                )
            } else {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Отозван Универсальный доступ. Откройте Системные настройки."
                    )
                )
            }
        } else if previousMicrophone, !microphone {
            if dictationState == .preparing || dictationState == .listening {
                controller?.preserveActiveRecording(
                    reason: "Отозван доступ к микрофону. Диктовка остановлена; откройте Системные настройки."
                )
            } else {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Отозван доступ к микрофону. Может потребоваться перезапуск приложения."
                    )
                )
            }
        }

        // Монитор регистрируется заново при каждой проверке: система начинает
        // отдавать ему события только после выдачи доступа, и без повторного
        // запуска клавиша молчала бы до перезапуска приложения.
        if accessibility {
            hotkeyMonitor.start()
        } else {
            hotkeyMonitor.stop()
        }

        reschedulePermissionPolling()
    }

    /// Подобрать частоту опроса под текущее положение дел.
    ///
    /// Пока чего-то не хватает, человек стоит в системных настройках и ждёт
    /// отклика — спрашиваем часто. Когда всё выдано, ждать больше нечего:
    /// приложение неделями сидит в строке меню, и будить процесс каждую секунду
    /// ради ответа, который не изменится, незачем.
    private func reschedulePermissionPolling() {
        let interval = PermissionPollPolicy.interval(
            accessibilityGranted: accessibilityGranted,
            microphoneGranted: microphoneGranted,
            base: permissionPollInterval
        )
        guard interval != permissionPollingInterval else { return }

        permissionPollingInterval = interval
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard interval > 0 else { return }

        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    public func requestAccessibility() {
        guard !accessibilityGranted else { return }
        accessibilityState = .waitingForSettings
        _ = accessibilityManager.requestAccess()
        accessibilityManager.openSettings()
        refreshPermissions()
    }

    public func openAccessibilitySettings() {
        accessibilityManager.openSettings()
    }

    public func revealApplicationForAccessibility() {
        accessibilityManager.revealApplication()
    }

    public func restartForAccessibility() {
        defaults.set(true, forKey: Self.accessibilityRelaunchPendingKey)
        Task {
            do {
                try await accessibilityManager.relaunchApplication()
            } catch {
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                accessibilityState = .failed(error.localizedDescription)
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Не удалось перезапустить Wai Dictation: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    /// Вызывается только после отдельного подтверждения в UI: команда удаляет
    /// Accessibility-записи ровно этого bundle id и потребует выдать доступ
    /// заново. Автоматического reset при запуске или запросе нет.
    public func repairAccessibility() {
        guard !accessibilityGranted, accessibilityState != .repairing else { return }
        accessibilityState = .repairing
        Task {
            do {
                try await accessibilityManager.resetAccess()
                // После reset отсутствие grant ожидаемо: новый процесс должен
                // снова показать обычную кнопку «Выдать», а не попасть в цикл
                // «repair required». Pending относится только к перезапуску
                // без reset, который обязан был подхватить уже включённый grant.
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                try await accessibilityManager.relaunchApplication()
            } catch {
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                accessibilityState = .failed(error.localizedDescription)
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Не удалось восстановить Универсальный доступ: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    public func requestMicrophone() {
        Task {
            let granted = await Permissions.requestMicrophone()
            if !granted { Permissions.openMicrophoneSettings() }
            refreshPermissions()
        }
    }

    // MARK: - Модель

    public func refreshModelState() async {
        guard let store else { return }
        // Пока идёт установка, осмотр диска сбрасывал бы состояние в «модель не
        // установлена»: метки готовности ещё нет. Прогресс с экрана пропадал бы
        // ровно тогда, когда человек открыл настройки на него посмотреть.
        guard !isInstalling else { return }
        modelState = await store.refreshState()
        // Осмотр диска не видит отказ Core ML: файлы целы, а модель не поднялась.
        // Пока человек явно не запросил восстановление, отказ остаётся на экране —
        // иначе кнопка восстановления исчезает, а диктовка так и не работает.
        if let engineLoadFailure, modelState.isReady {
            modelState = .repairRequired(engineLoadFailure)
        }
        if transcriber == nil {
            isEngineReady = modelState.isReady
        } else if !modelState.isReady {
            isEngineReady = false
        }
    }

    public func installModel() {
        // Повторное нажатие во время загрузки ничего не начинает: кнопка на
        // экране живёт до первого пришедшего состояния, и успеть нажать её
        // дважды проще, чем кажется.
        guard let store, !isInstalling else { return }
        isInstalling = true
        isEngineReady = false
        let isRepair: Bool
        if case .repairRequired = modelState {
            isRepair = true
        } else {
            isRepair = false
        }
        // Явная команда человека открывает новую попытку: прежний отказ Core ML
        // больше не держится, свежая установка прогреется заново.
        engineLoadFailure = nil

        Task {
            let states = await store.states()
            let monitor = Task { @MainActor in
                for await state in states { modelState = state }
            }
            if isRepair {
                await store.repair()
            } else {
                await store.install()
            }
            monitor.cancel()
            isInstalling = false
            await refreshModelState()

            // Первая загрузка компилирует модель под нейромодуль и занимает
            // секунды. Делаем это сразу, чтобы пользователь не ждал в момент
            // первой диктовки.
            if modelState.isReady { await warmUpEngine() }
        }
    }

    public func cancelModelInstall() {
        guard isInstalling else { return }
        Task { await store?.cancelInstall() }
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
            isEngineReady = false
            engineLoadFailure = nil
            await transcriber?.unload()
            await store.delete()
            await refreshModelState()
        }
    }

    private func warmUpEngine() async {
        guard let transcriber, let store else { return }
        guard case .ready = await store.currentState() else { return }
        isEngineReady = false
        isPreparingEngine = true
        defer { isPreparingEngine = false }

        do {
            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
            isEngineReady = true
            engineLoadFailure = nil
        } catch {
            let detail =
                "файлы прошли проверку, но Core ML не загрузил модель: \(error.localizedDescription)"
            engineLoadFailure = detail
            modelState = .repairRequired(detail)
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Модель не загрузилась. Требуется явное восстановление 483 МБ."
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

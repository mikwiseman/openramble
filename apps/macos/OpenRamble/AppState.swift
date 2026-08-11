import AVFoundation
import AppKit
import ServiceManagement
import DictationAudio
import DictationCore
import Foundation
import LocalASR
import SwiftUI

/// The edges of the system from which the application is built.
///
/// Here is exactly what cannot be touched in the test: user settings, folders on
/// disk, issued permissions, microphone, other people's applications and screen. In the application
/// real implementations are substituted, in the test - fake ones.
@MainActor
public struct AppEnvironment {
    public var defaults: UserDefaults
    public var paths: AppPaths
    public var permissions: any PermissionReading
    public var accessibilityManager: any AccessibilityManaging
    public var hotkeyMonitor: any HotkeyMonitoring
    public var inserter: any TextInserting
    public var overlay: any OverlayPresenting
    /// Capture factory: recording folder, crash handler and live microphone samples
    /// used by the recording waveform.
    public var makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void, @escaping @Sendable ([Float]) -> Void) -> any AudioCapturing
    /// How to recognize. Same system edge as microphone and insert: in
    /// in the application this is a model on disk, in the test this is a previously known answer. Without
    /// this seam, the entire dictation path in the application could not be checked
    /// at all - the tests only reached the start of recording.
    /// Recognition factory: engine folder and language hint provider.
    /// A hint is read for each call - the person could change the language between
    /// dictations, and fixing it during assembly would mean ignoring the choice.
    public var transcribe: (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult
    /// How often to request permissions in the busiest mode. Zero - do not poll.
    public var permissionPollInterval: TimeInterval
    /// How to download the model. The only network that the application has.
    public var modelDownloader: any ModelDownloading
    /// System microphone prompt and the app/window transition that follows it.
    public var requestMicrophoneAccess: () async -> Bool
    public var openMicrophoneSettings: () -> Void
    public var activateApplication: () -> Void
    /// Desktop notifications: sleep and wake.
    public var workspaceNotifications: NotificationCenter
    /// General notification center: the audio device change comes from there.
    public var notifications: NotificationCenter
    /// The only production instance of the engine. In tests `nil`: there is ASR
    /// is substituted via `transcribe` and the real model is not needed.
    public var localTranscriber: LocalTranscriber?
    /// How to read the field in which you inserted it. The only thing the app reads
    /// at other people’s windows, so there is a seam: “turned off means we can’t read” otherwise
    /// there is nothing to prove, but you will have to prove it in the README.
    public var focusedFieldReader: any FocusedFieldReading
    /// Where the inserter reports a clipboard it could not put back.
    public var clipboardRestoreReporter: ClipboardRestoreReporter?

    public init(
        defaults: UserDefaults,
        paths: AppPaths,
        permissions: any PermissionReading,
        accessibilityManager: any AccessibilityManaging,
        hotkeyMonitor: any HotkeyMonitoring,
        inserter: any TextInserting,
        overlay: any OverlayPresenting,
        makeCapture: @escaping (URL, @escaping @Sendable (AudioCaptureError) -> Void, @escaping @Sendable ([Float]) -> Void) -> any AudioCapturing,
        transcribe: @escaping (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult,
        permissionPollInterval: TimeInterval,
        modelDownloader: any ModelDownloading,
        requestMicrophoneAccess: @escaping () async -> Bool,
        openMicrophoneSettings: @escaping () -> Void,
        activateApplication: @escaping () -> Void,
        workspaceNotifications: NotificationCenter,
        notifications: NotificationCenter,
        localTranscriber: LocalTranscriber? = nil,
        focusedFieldReader: any FocusedFieldReading = SystemFocusedFieldReader(),
        clipboardRestoreReporter: ClipboardRestoreReporter? = nil
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
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.openMicrophoneSettings = openMicrophoneSettings
        self.activateApplication = activateApplication
        self.workspaceNotifications = workspaceNotifications
        self.notifications = notifications
        self.localTranscriber = localTranscriber
        self.focusedFieldReader = focusedFieldReader
        self.clipboardRestoreReporter = clipboardRestoreReporter
    }

    /// Real edges are what a working application is built from.
    public static func system() -> AppEnvironment {
        let transcriber = LocalTranscriber()
        let restoreReporter = ClipboardRestoreReporter()
        return AppEnvironment(
            defaults: .standard,
            paths: .standard(),
            permissions: SystemPermissions(),
            accessibilityManager: SystemAccessibilityManager(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            inserter: TextInserter(restoreReporter: restoreReporter),
            overlay: DictationOverlay(),
            makeCapture: { MicrophoneCapture(directory: $0, onFailure: $1, onSamples: $2) },
            transcribe: { engineDirectory, languageHint in
                return { url in
                    try await transcriber.prepare(modelDirectory: engineDirectory)
                    return try await transcriber.transcribe(
                        fileURL: url,
                        languageHint: languageHint()
                    )
                }
            },
            permissionPollInterval: 1,
            modelDownloader: URLSessionModelDownloader(),
            requestMicrophoneAccess: { await Permissions.requestMicrophone() },
            openMicrophoneSettings: Permissions.openMicrophoneSettings,
            activateApplication: { NSApplication.shared.activate(ignoringOtherApps: true) },
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            notifications: .default,
            localTranscriber: transcriber
        )
    }
}

/// All application state in one place.
///
/// Links hotkey, audio capture, recognition and insertion. Herself
/// dictation logic lives in `DictationController` - there is only connection here
/// system edges and what the interface sees.
@MainActor
public final class AppState: ObservableObject {
    // Shown in the interface.
    @Published public private(set) var dictationState: DictationState = .idle
    @Published public private(set) var modelState: ModelState = .notInstalled
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var accessibilityState: AccessibilityPermissionState = .denied
    @Published public private(set) var microphoneGranted = false
    @Published public private(set) var lastNotice: DictationNotice?
    @Published public private(set) var isPreparingEngine = false
    /// What to show while the engine is preparing for the first dictation.
    ///
    /// The timer here counts the seconds, not the view: in the view it would show “0 s”
    /// all preparation - the state comes once at the beginning and once at
    /// end, that is, exactly when the counter is no longer needed.
    @Published public private(set) var enginePreparation = EnginePreparationState.make(
        phase: .idle, elapsed: 0
    )
    private var preparationTimer: Timer?
    private var preparationStartedAt: Date?
    /// Is the preparation countdown in progress? Needed for tests: “the application is silent at rest.”
    public var isCountingEnginePreparation: Bool { preparationTimer != nil }
    @Published public private(set) var isEngineReady = false
    /// How much the installation button will download: the full volume or additional volume after the update.
    @Published public private(set) var remainingDownloadMegabytes = 586
    /// Recognition language: nil - auto-detection by sound. Code BCP-47 (“en”).
    /// Manual selection is the way out for the case when the emphasis is removed from autodetection
    /// in the wrong language; mixed speech it is contraindicated, so by default
    /// always automatic.
    @Published public var recognitionLanguage: String? {
        didSet {
            guard oldValue != recognitionLanguage else { return }
            if let recognitionLanguage {
                defaults.set(recognitionLanguage, forKey: Self.recognitionLanguageKey)
            } else {
                defaults.removeObject(forKey: Self.recognitionLanguageKey)
            }
        }
    }

    nonisolated static let recognitionLanguageKey = "recognitionLanguage"

    /// Text of unsuccessful insertion. Never written to disk.
    @Published public private(set) var recoveredText: String?
    /// WAV after a technical error, available for Retry/Delete.
    @Published public private(set) var recoveredRecording: URL?
    /// Whether recording occurs without holding down a key is shown in the menu.
    @Published public private(set) var isHandsFreeActive = false
    /// Only a successful insertion is considered a passed test in onboarding.
    @Published public private(set) var successfulDictationCount = 0

    /// The last successful dictation is only in the process memory. There is a window from it
    /// edits are taught by the dictionary; The text never gets to disk.
    public struct LastDictation: Equatable {
        public let insertedText: String
        /// What the text was before the dictionary and cosmetics.
        ///
        /// Lives only in process memory and is overwritten by each dictation:
        /// one slot, not a story. This is where “copy verbatim” comes from and this is where
        /// training on edits recognizes protected spans - another honest one
        /// it has no source, it only sees the inserted text.
        public let provenance: PipelineProvenance
    }
    @Published public private(set) var lastDictation: LastDictation?

    /// A short, in-memory list for quick copying from the menu. Nothing is
    /// persisted, so quitting the app clears the history.
    public struct RecentDictation: Identifiable, Equatable {
        public let id: UUID
        public let text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }

        var menuTitle: String {
            let singleLine = text
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard singleLine.count > 56 else { return singleLine }
            return String(singleLine.prefix(55)) + "…"
        }
    }
    @Published public private(set) var recentDictations: [RecentDictation] = []

    /// What's wrong with the dictionary. Until `nil`, the dictionary is write-locked.
    @Published public private(set) var dictionaryProblem: ReplacementsStore.Problem?

    // Settings.
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

    /// Replacement dictionary. Changes only through the methods below: direct write bypassed
    /// would check that the dictionary can be saved at all.
    @Published public private(set) var replacements: [DictionaryReplacement]

    private enum Keys {
        static let hotkey = "hotkey"
        static let sounds = "soundsEnabled"
        static let replacements = "replacements"
        /// macOS global setup: what pressing 🌐 does.
        static let fnUsage = "AppleFnUsageType"
    }

    /// The marker survives relaunch. If the new process is still not trusted,
    /// There is no point in repeating the restart - an explicit repair of the old TCC record is needed.
    static let accessibilityRelaunchPendingKey = "accessibilityRelaunchPending"

    private let defaults: UserDefaults
    private let paths: AppPaths
    private let permissions: any PermissionReading
    private let accessibilityManager: any AccessibilityManaging
    private let hotkeyMonitor: any HotkeyMonitoring
    private let inserter: any TextInserting
    private let clipboardRestoreReporter: ClipboardRestoreReporter?
    private let overlay: any OverlayPresenting
    private let makeCapture: (URL, @escaping @Sendable (AudioCaptureError) -> Void, @escaping @Sendable ([Float]) -> Void) -> any AudioCapturing
    private let transcribe: (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult
    private let permissionPollInterval: TimeInterval
    private let modelDownloader: any ModelDownloading
    private let requestMicrophoneAccess: () async -> Bool
    private let openMicrophoneSettings: () -> Void
    private let activateApplication: () -> Void
    private let workspaceNotifications: NotificationCenter
    private let notifications: NotificationCenter
    private let replacementsStore: ReplacementsStore

    /// Updates. A separate object with its own subscribers: check mark
    /// autochecks live in Sparkle settings, not in our `defaults`.
    public let updater = SparkleUpdater()

    private var store: ModelStore?
    private var vocabularyStore: ModelStore?
    private var vocabularyDirectory: URL?
    private var mainModelBytes: Int64 = 0
    private var vocabularyModelBytes: Int64 = 0
    private var mainModelFileCount = 0
    private var vocabularyModelFileCount = 0
    private var transcriber: LocalTranscriber?
    private var recordingRecovery: RecordingRecoveryStore?
    private var engineDirectory: URL?
    private var controller: DictationController?
    /// Is the model being installed right now?
    private var isInstalling = false
    /// Core ML failure during warm-up. The files on the disk are intact, so inspection
    /// does not see the failure disk - the state is kept here until explicit recovery.
    private var engineLoadFailure: String?
    /// Retry/Delete recovery are performed one at a time and block the hotkey.
    private var isRecoveryOperationActive = false
    /// A message that waits for the end of the session.
    private var noticeAfterSession: DictationNotice?
    /// The delayed “no sound” prompt is canceled by the first live signal.
    private var silenceHintTask: Task<Void, Never>?

    /// Observer of edits of inserted text - learns the dictionary automatically.
    private let editWatcher: EditLearningWatcher

    /// Whether to learn from edits of inserted text. Only the field is read
    /// where the application itself inserted it, and only in the first half a minute.
    ///
    /// **Disabled by default.** This is the only place where the application
    /// looks into the contents of someone else's window - and the promise of the product sounds like
    /// “we read exactly the bundle id of the active application: not the screen, not the content.”
    /// While the toggle switch was set to `true` and it was not in the settings, the promise was
    /// false, and the person had no way to notice it. Inclusion is conscious
    /// human action, not our default.
    @Published public var learnFromEdits: Bool {
        didSet {
            guard oldValue != learnFromEdits else { return }
            defaults.set(learnFromEdits, forKey: Self.learnFromEditsKey)
            if !learnFromEdits { editWatcher.cancel() }
        }
    }
    nonisolated static let learnFromEditsKey = "learnFromEdits"


    /// Last speed measurement. Only in memory, only numbers.
    @Published public private(set) var lastSpeed: DictationSpeedReport?

    /// Start at login. An app without a Dock icon that doesn't
    /// started after reboot, indistinguishable from broken: key
    /// is silent, and there is no one to explain why.
    @Published public var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    private var didCompleteInitialPermissionRefresh = false

    // Timers and subscriptions are marked `nonisolated(unsafe)` because they are removed
    // `deinit`, and it is for an isolated class - outside of isolation. They only touch them
    // from the main thread: the application lives entirely on it.
    nonisolated(unsafe) private var permissionTimer: Timer?
    nonisolated(unsafe) private var durationTimer: Timer?
    nonisolated(unsafe) private var systemObservers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    public var isDictationReady: Bool {
        accessibilityGranted && microphoneGranted && modelState.isReady && isEngineReady
    }

    /// How often permissions are now polled. Zero - polling is not running.
    ///
    /// Outwardly visible on purpose: the promise “at rest the application does nothing”
    /// is checked with this particular number.
    public private(set) var permissionPollingInterval: TimeInterval = 0

    public var isPollingPermissions: Bool { permissionTimer != nil }

    /// Whether the duration limit is being checked. It shouldn't be at rest.
    public var isCountingDuration: Bool { durationTimer != nil }

    /// Warning about the selected key, if any.
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
        // The saved code is checked against the engine list. List - property
        // library and may become narrower when it is updated; without checking each
        // dictation would fall on “unsupported language hint”, WAV would accumulate
        // in salvation, and the picker would show an empty line. Unfamiliar code -
        // this is autodetection, as it was before the selection.
        let storedLanguage = environment.defaults.string(forKey: Self.recognitionLanguageKey)
        recognitionLanguage = storedLanguage.flatMap {
            FluidAudioAdapter.supportedLanguageHints.contains($0) ? $0 : nil
        }
        editWatcher = EditLearningWatcher(reader: environment.focusedFieldReader)
        // No key = disabled: `bool(forKey:)` returns false. This
        // reads someone else's window and therefore requires an explicit opt-in.
        learnFromEdits = environment.defaults.bool(forKey: Self.learnFromEditsKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        paths = environment.paths
        permissions = environment.permissions
        accessibilityManager = environment.accessibilityManager
        hotkeyMonitor = environment.hotkeyMonitor
        inserter = environment.inserter
        clipboardRestoreReporter = environment.clipboardRestoreReporter
        overlay = environment.overlay
        makeCapture = environment.makeCapture
        transcribe = environment.transcribe
        permissionPollInterval = environment.permissionPollInterval
        modelDownloader = environment.modelDownloader
        requestMicrophoneAccess = environment.requestMicrophoneAccess
        openMicrophoneSettings = environment.openMicrophoneSettings
        activateApplication = environment.activateApplication
        workspaceNotifications = environment.workspaceNotifications
        notifications = environment.notifications
        transcriber = environment.localTranscriber
        // Test environments substitute a ready-made ASR closure and do not need
        // in Core ML warmup. Production always sends a shared transcriber.
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

        // We inform you after the build: before it there would have been nowhere to show the message.
        if let problem = loaded.problem {
            notify(DictationNotice(kind: .warning, message: problem.message))
        }
    }

    deinit {
        // The timer left in the run loop continues to wake up the process and
        // after the death of the owner: a weak link inside saves from falling, but
        // not from waking up.
        permissionTimer?.invalidate()
        durationTimer?.invalidate()
        for observer in systemObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: - Assembly

    private func setUp() {
        let sounds = SystemSounds(enabled: { [weak self] in self?.soundsEnabled ?? true })

        do {
            let capture = makeCapture(
                try paths.takes(),
                { [weak self] error in
                    // The audio stream is no longer usable in the middle of a speech. Wait
                    // stopping is not possible: the person speaks into emptiness, and the reason
                    // must be shown exactly.
                    Task { @MainActor in
                        self?.controller?.interrupt(
                            reason: Self.captureFailureMessage(error)
                        )
                    }
                },
                { [weak self] samples in
                    // The peak is sufficient for the waveform; RMS would hide short
                    // consonant transients that make the live signal feel responsive.
                    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                    Task { @MainActor in self?.registerInputLevel(peak) }
                }
            )
            let recordingRecovery = RecordingRecoveryStore(directory: try paths.audioRecovery())
            self.recordingRecovery = recordingRecovery

            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            let store = ModelStore(manifest: manifest, layout: layout, downloader: modelDownloader)
            self.store = store
            mainModelBytes = manifest.totalByteCount
            mainModelFileCount = manifest.files.count

            // Acoustic term hint - the second model with its own
            // manifesto. For a person, both are one “model”: see ModelPairState.
            let vocabularyManifest = try ModelManifest.bundledVocabulary()
            let vocabularyLayout = try ModelInstallLayout(
                manifest: vocabularyManifest,
                root: try paths.models()
            )
            vocabularyStore = ModelStore(
                manifest: vocabularyManifest,
                layout: vocabularyLayout,
                downloader: modelDownloader
            )
            vocabularyDirectory = vocabularyLayout.engineDirectory
            vocabularyModelBytes = vocabularyManifest.totalByteCount
            vocabularyModelFileCount = vocabularyManifest.files.count

            let engineDirectory = layout.engineDirectory
            self.engineDirectory = engineDirectory
            let controller = DictationController(
                capture: capture,
                transcribe: transcribe(
                    engineDirectory,
                    { [box = UncheckedBox(defaults)] in
                        // The provider is called from the background recognition context.
                        // UserDefaults is thread safe (documented) and
                        // repository is the same source of truth as
                        // published property; box only carries it through
                        // Sendable border.
                        box.value.string(forKey: Self.recognitionLanguageKey)
                    }
                ),
                inserter: inserter,
                overlay: overlay,
                sounds: sounds,
                recordingRecovery: recordingRecovery,
                pipeline: { [weak self] in
                    self?.makePipeline() ?? TextPipeline()
                }
            )
            controller.onStateChange = { [weak self] state in
                self?.dictationState = state
                self?.updateDurationTimer(for: state)
                self?.flushNoticeAfterSession(state)
                self?.updateRecordingFeedback(for: state)
            }
            controller.onNotice = { [weak self] notice in
                self?.lastNotice = notice
                if let text = notice.recoverableText { self?.recoveredText = text }
                if let audio = notice.recoveryAudio { self?.recoveredRecording = audio }
                // The kernel explained itself. Your own explanation on top of his words would be
                // worse than silence: the session has one reason for ending, not two.
                self?.noticeAfterSession = nil
            }
            controller.onHandsFreeChange = { [weak self] active in
                // The monitor needs to know the mode: in it, a single press means
                // “stop”, not “start a new dictation”.
                self?.hotkeyMonitor.isHandsFreeActive = active
                self?.isHandsFreeActive = active
            }
            controller.onTextInserted = { [weak self] text in
                guard let self else { return }
                self.recordSuccessfulDictation(text)
                guard self.learnFromEdits else { return }
                self.editWatcher.beginWatching(inserted: text) { [weak self] original, edited in
                    self?.learn(original: original, edited: edited)
                }
            }
            controller.onSpeed = { [weak self] report in
                // Keep the measurement for diagnostics and performance tests, but do
                // not cover the destination app after text has already arrived.
                self?.lastSpeed = report
            }
            controller.onDictationCompleted = { [weak self] provenance in
                self?.lastDictation = LastDictation(
                    insertedText: provenance.finalText,
                    provenance: provenance
                )
            }
            // Putting the person's own clipboard back happens a second after the
            // paste, detached, with nobody left to throw to. If it fails they
            // silently lose whatever they had copied and our dictation stays on
            // the board in its place — exactly the kind of quiet loss the
            // project forbids. This is the only path that can say so.
            clipboardRestoreReporter?.onFailure { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.notify(
                        DictationNotice(
                            kind: .warning,
                            message: "The text was inserted, but the previous clipboard couldn't be restored."
                        )
                    )
                }
            }
            self.controller = controller
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Couldn't prepare the app's working folders: \(error.localizedDescription)"
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

    /// Old builds wrote unrecognized text to disk in `Recovered/`.
    /// Now such text lives only in memory, and the promise of “recognized text
    /// is not written to disk” must also cover traces of previous versions.
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
                    message: "Couldn't delete the old version's recovery texts. "
                        + "Delete them manually: ~/Library/Application Support/OpenRamble/Recovered"
                )
            )
        }
    }

    static func captureFailureMessage(_ error: AudioCaptureError) -> String {
        switch error {
        case .unsupportedAudioFormat(let detail):
            return "Couldn't handle the selected microphone's audio format: \(detail)"
        case .microphonePermissionDenied:
            return "No microphone access. Open System Settings."
        case .engineUnavailable(let detail):
            return "The microphone stopped responding: \(detail)"
        case .diskFull:
            return "Couldn't record audio: no free disk space."
        case .writeFailed(let detail):
            return "Couldn't record audio: \(detail)"
        case .notRecording:
            return "Recording stopped unexpectedly."
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
                            ? "A local recording was found after an interruption — you can retry transcription or delete it."
                            : "One recording was saved for retry. A damaged fragment couldn't be recovered and was deleted.",
                        recoveryAudio: recoveredRecording
                    )
                )
            } else if result.discardedCorruptCount > 0 {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "An unfinished recording was damaged: it can't be recovered, the fragment was deleted."
                    )
                )
            }
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Couldn't prepare recording recovery: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Verbatim text of the last dictation

    private func recordSuccessfulDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        successfulDictationCount += 1
        recoveredText = nil
        recentDictations.insert(RecentDictation(text: trimmed), at: 0)
        if recentDictations.count > 8 {
            recentDictations.removeLast(recentDictations.count - 8)
        }
    }

    /// Copy a completed dictation without opening another window or writing
    /// history to disk. Successful copies stay quiet; the menu action itself is
    /// sufficient feedback.
    public func copyRecentDictation(_ dictation: RecentDictation) {
        guard recentDictations.contains(where: { $0.id == dictation.id }) else { return }
        do {
            try HostOnlyPasteboard().copyHostOnly(dictation.text)
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the dictation."))
        }
    }

    /// Is there anything to copy verbatim.
    public var canCopyRawDictation: Bool {
        guard let raw = lastDictation?.provenance.raw else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Put in a buffer what the person said - before the dictionary and before cosmetics.
    ///
    /// The promise of “verbatim text is always available” is backed by the recording
    /// origin in process memory: no reading of foreign fields through
    /// Accessibility, no disk writing required for this.
    ///
    /// The buffer is written host-only with transient/concealed markers, just like the insert:
    /// naked `clearContents()` would give dictation to Universal Clipboard for everything
    /// Apple ID devices.
    public func copyRawDictation() {
        guard let raw = lastDictation?.provenance.raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        do {
            try HostOnlyPasteboard().copyHostOnly(raw)
            notify(DictationNotice(kind: .info, message: "Verbatim text copied to this Mac only."))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the verbatim text."))
        }
    }

    // MARK: - Copy / Retry / Delete recovery

    public func copyRecoveredText() {
        guard let recoveredText else { return }
        do {
            try HostOnlyPasteboard().copyHostOnly(recoveredText)
            notify(DictationNotice(kind: .info, message: "Text copied to this Mac only."))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the text."))
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
            await overlay.dismiss()
            do {
                try await inserter.insert(recoveredText, into: target)
                self.recordSuccessfulDictation(recoveredText)
                await overlay.dismiss()
            } catch {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Retry insert failed — the text is still available via Copy and Retry.",
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
            let provenance: PipelineProvenance
            do {
                let result = try await transcribe(
                    engineDirectory,
                    { [box = UncheckedBox(defaults)] in
                        box.value.string(forKey: Self.recognitionLanguageKey)
                    }
                )(url)
                // Same pipeline as the live path, same entry
                // origin. Without it, a replay would be left after a failure
                // `lastDictation` from the PREVIOUS dictation - and training on
                // edits would learn a couple from someone else’s text, that is, quietly
                // would ruin a person's personal dictionary.
                let run = makePipeline().run(result.text)
                guard !run.output.text.isEmpty else { throw ASREngineError.inferenceFailed("empty result") }
                recognizedText = run.output.text
                provenance = run.provenance
            } catch {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Retry transcription failed. The recording is still saved locally.",
                        recoveryAudio: url
                    )
                )
                return
            }

            dictationState = .inserting
            await overlay.dismiss()
            do {
                try await inserter.insert(recognizedText, into: target)
                recordSuccessfulDictation(recognizedText)
                // Exactly like on a living path: the origin is recorded only
                // after successful insertion.
                lastDictation = LastDictation(
                    insertedText: recognizedText,
                    provenance: provenance
                )
            } catch {
                recoveredText = recognizedText
                do {
                    try await recordingRecovery.delete(url)
                    recoveredRecording = try await recordingRecovery.recordings().first
                    notify(
                        DictationNotice(
                            kind: .warning,
                            message: "The recording was transcribed, but the text wasn't inserted — Copy and Retry are in the menu.",
                            recoverableText: recognizedText
                        )
                    )
                } catch {
                    recoveredRecording = url
                    notify(
                        DictationNotice(
                            kind: .failure,
                            message: "The text is available via Copy and Retry, but the local WAV couldn't be deleted: \(error.localizedDescription)",
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
                        message: "The text was inserted, but the local WAV couldn't be deleted: \(error.localizedDescription)",
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
                notify(DictationNotice(kind: .failure, message: "Couldn't delete the local recording."))
            }
        }
    }

    /// Subscribe to what is happening to the computer outside of us.
    ///
    /// Both subscriptions exist for the same reason: dictation should not
    /// stay on when there is nothing else to listen to.
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
            // Changing the audio device comes from the audio engine thread, sleep -
            // from main. A general transition to the main thread is cheaper than parsing,
            // where exactly we were called from.
            Task { @MainActor in
                guard let self else { return }
                handler(self)
            }
        }
        systemObservers.append((center, token))
    }

    /// The computer goes to sleep.
    ///
    /// The release of a key that happened in a dream will not reach us: the system does not
    /// sends events to a sleeping machine. Without stopping, the session would remain in
    /// “listening” forever - with the microphone on and the indicator on
    /// records, and the only way out of this would be through Escape.
    private func handleSleep() {
        switch dictationState {
        case .listening:
            // What was said before bed has already been written down. Let's recognize it and not throw it away.
            noticeAfterSession = DictationNotice(
                kind: .info,
                message: "The Mac went to sleep — recording had to stop."
            )
            stopCurrentRecording()
        case .preparing:
            // We haven’t had time to write anything down yet - there’s nothing to lose.
            controller?.cancel()
        case .idle, .transcribing, .inserting:
            break
        }
    }

    /// The computer woke up.
    ///
    /// The key was released during sleep, but there was no event about it:
    /// the monitor still considers it clamped and will swallow the next press.
    /// Restarting tracking is the only thing that erases the memory of the started gesture.
    private func handleWake() {
        hotkeyMonitor.stop()
        refreshPermissions()
    }

    /// The audio device changed mid-recording.
    ///
    /// The headphones were taken out, the monitor and microphone were turned off - the engine remains
    /// launched, but frames no longer arrive to it. Man speaks in
    /// silence and learns about it only by the empty result.
    private func handleAudioConfigurationChange() {
        guard dictationState == .listening else { return }
        controller?.preserveActiveRecording(
            reason: "The microphone or audio device was disconnected. Dictation stopped."
        )
    }

    /// Say what was waiting for the end of the session.
    ///
    /// It’s impossible to say right away: after stopping, the kernel redraws the panel
    /// under “I recognize”, and the explanation lives on the screen for a split second. And say
    /// it is necessary - otherwise it is not clear why the recording was cut off mid-sentence.
    private func flushNoticeAfterSession(_ state: DictationState) {
        guard state == .idle, let pending = noticeAfterSession else { return }
        noticeAfterSession = nil
        notify(pending)
    }

    /// Finish the running recording as a human would finish it.
    ///
    /// In non-holding mode, releasing the key does not mean anything, and the normal
    /// the stop would be ignored - the recording would continue to nowhere.
    private func stopCurrentRecording() {
        if isHandsFreeActive {
            controller?.stopHandsFree()
        } else {
            controller?.stop()
        }
    }

    /// Visible button in the menu bar: the user is not required to remember the gesture.
    public func finishCurrentDictation() {
        guard !isRecoveryOperationActive,
              dictationState == .preparing || dictationState == .listening
        else { return }
        stopCurrentRecording()
    }

    /// General safe cancel for Escape and menu bar.
    ///
    /// The message is given only for a cancellation that has actually taken place. From
    /// `.inserting` there is nothing to cancel - ⌘V has already gone into someone else's
    /// window - and the kernel ignores such a request. The words “the recording was
    /// deleted” would then say the exact opposite of what a person sees a moment later in
    /// his document, and would also erase the real warning about the insertion from the
    /// screen. Escape at this moment does nothing, and it is right that it says nothing:
    /// the text is already in place, and there is nothing to report about it.
    public func cancelCurrentDictation() {
        guard !isRecoveryOperationActive,
              DictationStopPolicy.canCancel(state: dictationState)
        else { return }
        controller?.cancel()
        notify(DictationNotice(kind: .info, message: "Dictation cancelled. The recording was deleted."))
    }

    private func wireHotkey() {
        hotkeyMonitor.setHotkey(hotkey)
        hotkeyMonitor.onPress = { [weak self] in
            guard let self else { return }
            guard !self.isRecoveryOperationActive else { return }
            guard self.explainIfNotReady() else { return }
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
                // The session is already running - the first click launched it. We translate it into
                // no hold mode instead of starting a new one: new
                //wouldn't have started anyway, because this one hasn't finished yet.
                self.controller?.promoteToHandsFree()
            case .idle:
                guard self.explainIfNotReady() else { return }
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
        hotkeyMonitor.onAbortShortcut = { [weak self] in
            // Hold turned out to be a shortcut (Ctrl+C over the selected key):
            // the recording ends quietly - without insertion, without messages and without sound
            // errors. The person pressed the shortcut, rather than dictated.
            self?.controller?.cancel()
        }
        hotkeyMonitor.onEscape = { [weak self] in
            // Escape cancels only the dictation in progress. The rest of the time it's
            // a regular key, and cannot be intercepted.
            self?.cancelCurrentDictation()
        }
    }

    /// Is it possible to start dictation; if not, say why.
    ///
    /// The kernel rejects the start silently, and rightly so: it has neither a screen nor
    /// words. But outside, the silence in response to pressing is indistinguishable from a broken
    /// applications - especially in the warm-up window after installation, where everything is displayed,
    /// everything is downloaded, but the key still doesn’t work for tens of seconds.
    ///
    /// Asked only at rest. Pressing in the middle of a running dictation core too
    /// rejects, but there silence is appropriate: a person sees the panel and knows that
    /// happens, and an explanation for each extra click would be nitpicking.
    ///
    /// Returns `true` if there are no obstacles.
    private func explainIfNotReady() -> Bool {
        guard dictationState == .idle else { return true }
        guard let reason = DictationReadiness.reason(
            accessibilityGranted: accessibilityGranted,
            microphoneGranted: microphoneGranted,
            modelState: modelState,
            isEngineReady: isEngineReady
        ) else { return true }

        // Precisely warning: for VoiceOver this is an urgent announcement, and the person
        // just pressed a key and is waiting for a response now, not after
        // the synthesizer finishes reading someone else's phrase.
        notify(DictationNotice(kind: .warning, message: reason))
        return false
    }

    /// Show the message to the person.
    ///
    /// Through an overlay, and not just the `lastNotice` field: no window can do it
    /// shows, and messages like “dictation is now in progress” were not received at all.
    private func notify(_ notice: DictationNotice) {
        lastNotice = notice
        Task { await overlay.presentNotice(notice) }
    }

    // MARK: - Permissions

    public func refreshPermissions() {
        let accessibility = permissions.accessibilityGranted
        let microphone = permissions.microphoneGranted
        let previousAccessibility = accessibilityGranted
        let previousMicrophone = microphoneGranted

        // Check for changes: the interface is subscribed to these fields, and here
        // come both on a timer and with each opening of the settings.
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
                        message: "Dictation is off: grant Accessibility and Microphone access in System Settings."
                    )
                )
            }
        } else if previousAccessibility, !accessibility {
            if dictationState == .preparing || dictationState == .listening {
                controller?.preserveActiveRecording(
                    reason: "Accessibility access was revoked. Dictation stopped; open System Settings."
                )
            } else {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Accessibility access was revoked. Open System Settings."
                    )
                )
            }
        } else if previousMicrophone, !microphone {
            if dictationState == .preparing || dictationState == .listening {
                controller?.preserveActiveRecording(
                    reason: "Microphone access was revoked. Dictation stopped; open System Settings."
                )
            } else {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Microphone access was revoked. The app may need a relaunch."
                    )
                )
            }
        }

        // The monitor is re-registered every time it is checked: the system starts
        // give events to it only after granting access, and without repeating
        // the start key would be silent until the application was restarted.
        if accessibility {
            hotkeyMonitor.start()
        } else {
            hotkeyMonitor.stop()
        }

        reschedulePermissionPolling()
    }

    /// Select the polling frequency to match the current state of affairs.
    ///
    /// While something is missing, a person stands in the system settings and waits
    /// response - we ask often. When everything is issued, there is nothing more to wait:
    /// The application sits in the menu bar for weeks, and wakes up the process every second
    /// for the sake of an answer that will not change, there is no need.
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
                        message: "Couldn't relaunch OpenRamble: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    /// Called only after a separate confirmation in the UI: the command deletes
    /// Accessibility records of exactly this bundle id will require access to be granted
    /// again. There is no automatic reset upon startup or request.
    public func repairAccessibility() {
        guard !accessibilityGranted, accessibilityState != .repairing else { return }
        accessibilityState = .repairing
        Task {
            do {
                try await accessibilityManager.resetAccess()
                // After reset, the lack of grant is expected: the new process must
                // show the normal "Give" button again instead of getting into a loop
                // "repair required". Pending only applies to restarts
                // without reset, which was supposed to pick up the already enabled grant.
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                try await accessibilityManager.relaunchApplication()
            } catch {
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
                accessibilityState = .failed(error.localizedDescription)
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Couldn't repair Accessibility access: \(error.localizedDescription)"
                    )
                )
            }
        }
    }

    public func requestMicrophone() {
        Task {
            let granted = await requestMicrophoneAccess()
            if granted {
                // The TCC prompt can restore focus to whichever app was active before
                // this menu-bar app. Bring the Welcome window back after a successful
                // grant so onboarding continues where the user left it.
                activateApplication()
            } else {
                openMicrophoneSettings()
            }
            refreshPermissions()
        }
    }

    // MARK: - Model

    public func refreshModelState() async {
        guard let store else { return }
        // While the installation is in progress, inspection of the disk would reset the state to "model not
        // installed”: there is no ready flag yet. Progress would disappear from the screen
        // exactly when the person opened the settings to look at it.
        guard !isInstalling else { return }
        let mainState = await store.refreshState()
        let vocabularyState = await vocabularyStore?.refreshState() ?? .notInstalled
        modelState = combinedModelState(main: mainState, vocabulary: vocabularyState)
        remainingDownloadMegabytes = Int(
            (ModelPairState.remainingBytes(
                main: mainState,
                vocabulary: vocabularyState,
                mainTotalBytes: mainModelBytes,
                vocabularyTotalBytes: vocabularyModelBytes
            ) + 500_000) / 1_000_000
        )
        // Inspection of the disk does not see a Core ML failure: the files are intact, but the model has not risen.
        // Until the person explicitly requests restoration, the refusal remains on the screen -
        // otherwise the recovery button disappears and dictation still doesn't work.
        if let engineLoadFailure, modelState.isReady {
            modelState = .repairRequired(engineLoadFailure)
        }
        if transcriber == nil {
            isEngineReady = modelState.isReady
        } else if !modelState.isReady {
            isEngineReady = false
        }
    }

    private func combinedModelState(main: ModelState, vocabulary: ModelState) -> ModelState {
        ModelPairState.combine(
            main: main,
            vocabulary: vocabulary,
            mainTotalBytes: mainModelBytes,
            vocabularyTotalBytes: vocabularyModelBytes,
            mainFileCount: mainModelFileCount,
            vocabularyFileCount: vocabularyModelFileCount
        )
    }

    public func installModel() {
        // Pressing again during loading does not start anything: the button is on
        // the screen lives until the first state arrives, and has time to press it
        // twice as simple as it seems.
        guard let store, !isInstalling else { return }
        isInstalling = true
        isEngineReady = false
        // Core ML failure leaves files on disk “intact” - both storages
        // they will say “ready”. Explicit restoration is required to keep the promise of
        // messages and re-download, rather than silently repeat the warm-up.
        let engineRejectedModels = engineLoadFailure != nil
        // Explicit human command opens a new attempt: previous Core ML failure
        // no longer holds, the fresh installation will warm up again.
        engineLoadFailure = nil

        Task {
            // Both models are placed sequentially, and the progress on the screen is common:
            // each event of any of the repositories reassembles the combined one
            // state. The finished model is not touched - so add it after
            // only the missing prompter downloads updates.
            var mainLatest = await store.refreshState()
            let vocabularyLatest = UncheckedBox(
                await vocabularyStore?.refreshState() ?? .notInstalled
            )

            if !mainLatest.isReady || engineRejectedModels {
                let states = await store.states()
                let monitor = Task { @MainActor in
                    for await state in states {
                        modelState = combinedModelState(
                            main: state,
                            vocabulary: vocabularyLatest.value
                        )
                    }
                }
                if mainLatest.isReady || mainLatest.requiresRepair {
                    await store.repair()
                } else {
                    await store.install()
                }
                monitor.cancel()
                mainLatest = await store.currentState()
            }

            if mainLatest.isReady, let vocabularyStore,
               !vocabularyLatest.value.isReady || engineRejectedModels {
                let states = await vocabularyStore.states()
                let mainSnapshot = mainLatest
                let monitor = Task { @MainActor in
                    for await state in states {
                        vocabularyLatest.value = state
                        modelState = combinedModelState(main: mainSnapshot, vocabulary: state)
                    }
                }
                if vocabularyLatest.value.isReady || vocabularyLatest.value.requiresRepair {
                    await vocabularyStore.repair()
                } else {
                    await vocabularyStore.install()
                }
                monitor.cancel()
            }

            // Preserve the stores' terminal states. Scanning the install directory after
            // a failure finds no ready marker and used to erase the detailed error with
            // `.notInstalled` before the user could read it or press Retry.
            let finalMain = await store.currentState()
            let finalVocabulary = await vocabularyStore?.currentState() ?? .notInstalled
            modelState = combinedModelState(main: finalMain, vocabulary: finalVocabulary)
            remainingDownloadMegabytes = Int(
                (ModelPairState.remainingBytes(
                    main: finalMain,
                    vocabulary: finalVocabulary,
                    mainTotalBytes: mainModelBytes,
                    vocabularyTotalBytes: vocabularyModelBytes
                ) + 500_000) / 1_000_000
            )
            isInstalling = false

            // The first load compiles the model for the neuromodule and takes
            // seconds. We do this right away so that the user does not wait at the moment
            // first dictation.
            if modelState.isReady { await warmUpEngine() }
        }
    }

    public func cancelModelInstall() {
        guard isInstalling else { return }
        Task {
            await store?.cancelInstall()
            await vocabularyStore?.cancelInstall()
        }
    }

    public func deleteModel() {
        // Dictation in progress - the model is currently at work. To remove it from under oneself means
        // lose what was already said and show the loading error instead.
        //
        // The check comes before the rest on purpose: a person needs an answer to
        // your own pressing, and not silence due to the fact that something is not inside.
        guard dictationState == .idle else {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Dictation is in progress. Wait for it to finish."
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
            await vocabularyStore?.delete()
            await refreshModelState()
        }
    }

    private func warmUpEngine() async {
        guard let transcriber, let store else { return }
        guard case .ready = await store.currentState() else { return }
        isEngineReady = false
        isPreparingEngine = true
        beginPreparationCountdown(phase: .loadingRecognizer)
        defer {
            isPreparingEngine = false
            endPreparationCountdown()
        }

        do {
            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
            // The term hint is part of the same readiness: without it, dictation
            // it would work quieter than stated, and the silent “worse, but it works”
            // not allowed here.
            if let vocabularyDirectory {
                // The second model is the second phase: it is compiled separately, and
                // merging them into one line means showing the person that
                // “a little more” when new work has started.
                setPreparationPhase(.loadingVocabulary)
                // The person's own replacements - including those learned from edits -
                // amplify the acoustics with the same fuses as
                // starting set.
                try await transcriber.prepareVocabulary(
                    modelDirectory: vocabularyDirectory,
                    boost: .withUserReplacements(replacements)
                )
            }
            isEngineReady = true
            engineLoadFailure = nil
        } catch let boost as VocabularyBoostError {
            // The problem is with the list of human terms, not with the model's weights.
            // Previously, this fell into the general catch and was classified as damage
            // models: the interface offered to download hundreds of megabytes, which
            // would not help in any way - the term would not go away, and the circle
            // would be repeated. User data cannot be treated by pumping.
            engineLoadFailure = nil
            isEngineReady = true
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "One of the dictionary terms couldn't be used for acoustic "
                        + "boosting; dictation works, text replacements still apply. "
                        + "(\(boost))"
                )
            )
        } catch {
            let detail =
                "the files passed verification, but Core ML couldn't load the model: \(error.localizedDescription)"
            engineLoadFailure = detail
            modelState = .repairRequired(detail)
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "The model didn't load. An explicit repair will redownload "
                        + "\(remainingDownloadMegabytes == 0 ? 586 : remainingDownloadMegabytes) MB."
                )
            )
        }
    }

    /// Editing the dictionary reaches the acoustics now, and not after a restart.
    ///
    /// Text replacements are applied to the next dictation immediately - if acoustics
    /// at the same time lives with the old list, the behavior of the dictionary bifurcates without
    /// explanations: half of the feature is working, half is waiting for a restart, and
    /// a person cannot understand the system. Reassembly costs a fraction of a second, weight
    /// the tipster survives it without rebooting.
    private func rebuildVocabularyBoost() {
        guard isEngineReady, let transcriber, let vocabularyDirectory else { return }
        let currentReplacements = replacements
        Task { [weak self] in
            do {
                try await transcriber.prepareVocabulary(
                    modelDirectory: vocabularyDirectory,
                    boost: .withUserReplacements(currentReplacements)
                )
            } catch {
                // The acoustics have not been reassembled - text replacements are already working, and
                // the only honest reaction is to say, and not roll back the edit.
                await MainActor.run { [weak self] in
                    self?.notify(
                        DictationNotice(
                            kind: .warning,
                            message: "The dictionary was saved, but acoustic boosting "
                                + "couldn't pick it up: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    // MARK: - Duration limit

    // MARK: - Recording feedback

    private func updateRecordingFeedback(for state: DictationState) {
        silenceHintTask?.cancel()
        silenceHintTask = nil
        guard state == .listening else { return }

        silenceHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            (self?.overlay as? RecordingFeedbackPresenting)?.showSilenceHint()
        }
    }

    /// Peak level from the microphone. A real signal also cancels the silence hint.
    private func registerInputLevel(_ peak: Float) {
        (overlay as? RecordingFeedbackPresenting)?.updateInputLevel(peak)
        if peak > 0.02 {
            silenceHintTask?.cancel()
            silenceHintTask = nil
        }
    }

    /// Registration error visible: silently leave a person without autostart -
    /// means returning the problem “the key is silent after a reboot.”
    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Could not update the login item: \(error.localizedDescription)"
                )
            )
        }
    }

    private func updateDurationTimer(for state: DictationState) {
        durationTimer?.invalidate()
        durationTimer = nil
        guard state == .listening else { return }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.controller?.checkDurationLimit() }
        }
    }

    // MARK: - Engine preparation countdown

    private func beginPreparationCountdown(phase: EnginePreparationState.Phase) {
        preparationTimer?.invalidate()
        preparationStartedAt = Date()
        enginePreparation = .make(phase: phase, elapsed: 0)
        preparationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPreparation() }
        }
    }

    private func setPreparationPhase(_ phase: EnginePreparationState.Phase) {
        guard preparationTimer != nil else { return }
        enginePreparation = .make(phase: phase, elapsed: elapsedPreparation())
    }

    private func tickPreparation() {
        guard preparationTimer != nil else { return }
        enginePreparation = .make(phase: enginePreparation.phase, elapsed: elapsedPreparation())
    }

    private func elapsedPreparation() -> TimeInterval {
        guard let preparationStartedAt else { return 0 }
        return Date().timeIntervalSince(preparationStartedAt)
    }

    private func endPreparationCountdown() {
        preparationTimer?.invalidate()
        preparationTimer = nil
        preparationStartedAt = nil
        enginePreparation = .make(phase: isEngineReady ? .ready : .idle, elapsed: 0)
    }

    // MARK: - Conveyor

    /// One pipeline for both paths: live dictation and replay after failure.
    ///
    /// There were two paths, and they were already diverging - the replay was losing `output.command`.
    /// Generic assembly makes "both paths are the same" a property of the code, not something that
    /// must be remembered when ruling one of two places.
    private func makePipeline() -> TextPipeline {
        // Safe built-in technical vocabulary is part of recognition, not a
        // hidden setup chore. Personal entries win when they use the same
        // heard spelling.
        TextPipeline(
            replacements: StarterDictionary.missing(from: replacements) + replacements
        )
    }

    // MARK: - Dictionary

    /// Is it possible to change the dictionary now?
    ///
    /// It is impossible in exactly one case: the previous dictionary was not read. Then any
    /// the recording would have erased it entirely - and the person would have lost everything accumulated.
    public var isDictionaryEditable: Bool { dictionaryProblem == nil }

    /// Learn edits to pasted text noticed in the target application.
    /// Word-by-word diff with conservative filter: only terms are learned
    /// (change of writing, brand register), speech edits do not work.
    @discardableResult
    public func learn(original: String, edited: String) -> Int {
        let proposals = CorrectionLearning.propose(
            original: original,
            edited: edited,
            existing: replacements,
            // Spans of the last dictation: editing inside the path or backticks is
            // code editing, and it will not become a silent rule for future dictations.
            protecting: lastDictation?.provenance.spans ?? []
        )
        for proposal in proposals {
            addReplacement(spoken: proposal.spoken, written: proposal.written)
        }
        if !proposals.isEmpty {
            notify(
                DictationNotice(
                    kind: .info,
                    message: proposals.count == 1
                        ? "Learned 1 replacement from your edit."
                        : "Learned \(proposals.count) replacements from your edit."
                )
            )
        }
        return proposals.count
    }

    public func learnCorrections(editedText: String) -> Int {
        guard let lastDictation else { return 0 }
        let proposals = CorrectionLearning.propose(
            original: lastDictation.insertedText,
            edited: editedText,
            existing: replacements,
            protecting: lastDictation.provenance.spans
        )
        for proposal in proposals {
            addReplacement(spoken: proposal.spoken, written: proposal.written)
        }
        if !proposals.isEmpty {
            notify(
                DictationNotice(
                    kind: .info,
                    message: proposals.count == 1
                        ? "Learned 1 replacement for future dictations."
                        : "Learned \(proposals.count) replacements for future dictations."
                )
            )
        }
        return proposals.count
    }

    /// The edit did not provide a single replacement - say it directly, and not close the window silently.
    public func notifyNothingLearned() {
        notify(
            DictationNotice(
                kind: .info,
                message: "No new terms to learn — only term-like corrections become replacements."
            )
        )
    }

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

    /// Add a ready-made set of developer terms.
    ///
    /// The model writes Anglicisms as she hears them in Russian speech: “pull request”
    /// becomes "pull request". The set returns them to their normal appearance. Already started
    /// We don’t touch the replacement by the user - ours is more important than the workpiece.
    public func addStarterDictionary() {
        updateReplacements(replacements + StarterDictionary.missing(from: replacements))
    }

    /// How many prepared terms have not yet been added.
    public var availableStarterCount: Int {
        StarterDictionary.missing(from: replacements).count
    }

    private func updateReplacements(_ updated: [DictionaryReplacement]) {
        guard let problem = dictionaryProblem else {
            do {
                try replacementsStore.save(updated)
            } catch {
                // It’s not saved, which means it can’t be changed in memory: the list is on
                // the screen would differ from what is on the disk, and the person would find out about
                // this only after a restart.
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "The dictionary wasn't saved: \(error.localizedDescription)"
                    )
                )
                return
            }
            replacements = updated
            rebuildVocabularyBoost()
            return
        }

        notify(DictationNotice(kind: .warning, message: problem.message))
    }
}

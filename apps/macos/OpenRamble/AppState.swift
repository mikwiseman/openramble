import AVFoundation
import AppKit
import ServiceManagement
import DictationAudio
import DictationCore
import Foundation
import LocalASR
import SwiftUI
import os

/// Field diagnostics for the engine — numbers and reasons only, never words.
///
/// This is how the warm/cold latency distribution and every unload decision
/// get verified against reality after a release, from the unified log alone.
/// The network gate separately enforces that no transcript text is ever
/// logged.
let engineLog = Logger(subsystem: "is.waiwai.dictation", category: "engine")

extension Duration {
    /// Seconds as a plain Double, for logging and arithmetic.
    var appSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Await worker-owned model preparation without transferring the caller's
/// cancellation to it. The dictation controller may abandon its short
/// foreground wait, while the persistent worker must be allowed to finish a
/// healthy load/specialization for the next take.
func awaitOwnedEnginePreparation(
    _ operation: @escaping @Sendable () async throws -> Void
) async throws {
    let owned = Task { try await operation() }
    try await owned.value
}

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
    /// A second watcher, for the shortcut that copies the last dictation.
    ///
    /// Its own monitor rather than another callback on the first: that one
    /// watches a bare modifier being held, this one watches a chord being
    /// pressed. Different events, different machinery.
    public var copyShortcutMonitor: (any ShortcutMonitoring)?
    public var inserter: any TextInserting
    /// Lock-only destination snapshot maintained ahead of the hotkey. The
    /// shipping path never asks AppKit/WindowServer synchronously after the
    /// microphone has started.
    public var targetApplicationSnapshot: @Sendable () -> TargetApplication?
    public var overlay: any OverlayPresenting
    /// Builds the attention sound, given the live "sounds enabled" reading.
    ///
    /// A factory rather than a value because the setting is read at play time,
    /// and injected rather than constructed inside `setUp` because the
    /// application sources are compiled straight into the test bundle: a
    /// directly built `SystemSounds` meant every suite exercising a failure
    /// path played Submarine through the speakers of whoever ran the tests.
    /// A test must not be audible.
    public var makeSounds: @MainActor (@escaping @MainActor () -> Bool) -> any Sounding
    /// Capture factory: recording folder, crash handler and live microphone samples
    /// used by the recording waveform.
    public var makeCapture: (
        URL,
        @escaping @Sendable (DictationSessionID, AudioCaptureError) -> Void,
        @escaping @Sendable ([Float]) -> Void,
        @escaping @Sendable (DictationSessionID) -> Void,
        AudioDeviceID?
    ) -> any AudioCapturing
    /// How to recognize. Same system edge as microphone and insert: in
    /// in the application this is a model on disk, in the test this is a previously known answer. Without
    /// this seam, the entire dictation path in the application could not be checked
    /// at all - the tests only reached the start of recording.
    /// Recognition factory: engine folder and language hint provider.
    /// A hint is read for each call - the person could change the language between
    /// dictations, and fixing it during assembly would mean ignoring the choice.
    public var transcribe: (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult
    /// Retry insertion is a system edge too. Keep it injectable so the app
    /// and tests share the same bounded state transition.
    public var recoveryInsertionDeadline: Duration
    /// A worker timeout is not evidence that verified model files are bad.
    /// Preparation retries forever with a backoff ladder; this scale keeps the
    /// suite from sleeping production-scale intervals (nil = the real ladder).
    public var engineWarmupRetryDelay: Duration?
    /// Warning-tier rewarm settle window; injectable for the same reason.
    /// Test-only override for the idle-unload countdown: the policy's real
    /// options start at two minutes, and suites never sleep that long.
    public var idleUnloadDelayOverride: Duration?
    /// Crash-recovery timing is injectable so launch-to-idle maintenance can
    /// be proven without sleeping for the production compatibility window.
    public var recordingRecoveryCompatibilityGrace: TimeInterval
    public var recordingRecoveryMaintenanceRetryDelay: TimeInterval
    public var recordingRecoveryIdleScanInterval: TimeInterval
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
    /// The only production recognition lifecycle. Production owns the model
    /// in a private child process; tests may inject an in-process fake engine.
    public var localTranscriber: (any DictationRecognizing)?
    /// How to read the field in which you inserted it. The only thing the app reads
    /// at other people’s windows, so there is a seam: “turned off means we can’t read” otherwise
    /// there is nothing to prove, but you will have to prove it in the README.
    public var focusedFieldReader: any FocusedFieldReading
    /// Where the inserter reports a clipboard it could not put back.
    public var clipboardRestoreReporter: ClipboardRestoreReporter?
    /// One-release upgrade cleanup for voice files staged by the retired MCP
    /// helper. Test environments default to a no-op and never touch the real
    /// user's Darwin temporary directory.
    public var cleanupLegacyAgentStaging: @Sendable () throws -> Void
    /// Shared with the worker supervisor so its off-main recovery loop can
    /// read the pressure tier without hopping through AppState.

    public init(
        defaults: UserDefaults,
        paths: AppPaths,
        permissions: any PermissionReading,
        accessibilityManager: any AccessibilityManaging,
        hotkeyMonitor: any HotkeyMonitoring,
        copyShortcutMonitor: (any ShortcutMonitoring)? = nil,
        inserter: any TextInserting,
        targetApplicationSnapshot: @escaping @Sendable () -> TargetApplication? = { nil },
        overlay: any OverlayPresenting,
        makeSounds: @escaping @MainActor (@escaping @MainActor () -> Bool) -> any Sounding
            = { SystemSounds(enabled: $0) },
        makeCapture: @escaping (
            URL,
            @escaping @Sendable (DictationSessionID, AudioCaptureError) -> Void,
            @escaping @Sendable ([Float]) -> Void,
            @escaping @Sendable (DictationSessionID) -> Void,
            AudioDeviceID?
        ) -> any AudioCapturing,
        transcribe: @escaping (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult,
        recoveryInsertionDeadline: Duration = .seconds(2),
        engineWarmupRetryDelay: Duration? = nil,
        idleUnloadDelayOverride: Duration? = nil,
        recordingRecoveryCompatibilityGrace: TimeInterval = 60,
        recordingRecoveryMaintenanceRetryDelay: TimeInterval = 5,
        recordingRecoveryIdleScanInterval: TimeInterval = 60,
        permissionPollInterval: TimeInterval,
        modelDownloader: any ModelDownloading,
        requestMicrophoneAccess: @escaping () async -> Bool,
        openMicrophoneSettings: @escaping () -> Void,
        activateApplication: @escaping () -> Void,
        workspaceNotifications: NotificationCenter,
        notifications: NotificationCenter,
        localTranscriber: (any DictationRecognizing)? = nil,
        focusedFieldReader: any FocusedFieldReading = SystemFocusedFieldReader(),
        clipboardRestoreReporter: ClipboardRestoreReporter? = nil,
        cleanupLegacyAgentStaging: @escaping @Sendable () throws -> Void = {},
    ) {
        self.defaults = defaults
        self.paths = paths
        self.permissions = permissions
        self.accessibilityManager = accessibilityManager
        self.hotkeyMonitor = hotkeyMonitor
        self.copyShortcutMonitor = copyShortcutMonitor
        self.inserter = inserter
        self.targetApplicationSnapshot = targetApplicationSnapshot
        self.overlay = overlay
        self.makeSounds = makeSounds
        self.makeCapture = makeCapture
        self.transcribe = transcribe
        self.recoveryInsertionDeadline = recoveryInsertionDeadline
        self.engineWarmupRetryDelay = engineWarmupRetryDelay
        self.idleUnloadDelayOverride = idleUnloadDelayOverride
        self.recordingRecoveryCompatibilityGrace = recordingRecoveryCompatibilityGrace
        self.recordingRecoveryMaintenanceRetryDelay = recordingRecoveryMaintenanceRetryDelay
        self.recordingRecoveryIdleScanInterval = recordingRecoveryIdleScanInterval
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
        self.cleanupLegacyAgentStaging = cleanupLegacyAgentStaging
    }

    /// Real edges are what a working application is built from.
    public static func system() -> AppEnvironment {
        let transcriber = LocalTranscriber()
        let restoreReporter = ClipboardRestoreReporter()
        let activeApplication = ActiveApplicationSnapshot()
        return AppEnvironment(
            defaults: .standard,
            paths: .standard(),
            permissions: SystemPermissions(),
            accessibilityManager: SystemAccessibilityManager(),
            hotkeyMonitor: GlobalHotkeyMonitor(),
            copyShortcutMonitor: GlobalShortcutMonitor(),
            inserter: TextInserter(restoreReporter: restoreReporter),
            targetApplicationSnapshot: { activeApplication.current() },
            overlay: DictationOverlay(),
            makeSounds: { SystemSounds(enabled: $0) },
            makeCapture: {
                MicrophoneCapture(
                    directory: $0,
                    onFailure: $1,
                    onSamples: $2,
                    onMemoryLimitReached: $3,
                    preferredInputDeviceID: $4
                )
            },
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
            activateApplication: { NSApplication.shared.activate() },
            workspaceNotifications: NSWorkspace.shared.notificationCenter,
            notifications: .default,
            localTranscriber: transcriber,
            cleanupLegacyAgentStaging: {
                try LegacyAgentStagingCleanup.removeAbandonedAudio(
                    bundleIdentifier: Bundle.main.bundleIdentifier
                        ?? "is.waiwai.dictation"
                )
            },
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
    /// Every route by which the files become usable starts preparation.
    ///
    /// Readiness arrives from more places than the two that used to start a
    /// warm-up: a finished install, yes, but also a plain look at the disk —
    /// the Settings window refreshes on open, and a run that begins before the
    /// download re-reads the result afterwards. Readiness discovered that way
    /// used to start nothing, and the app sat on a ready model with a cold
    /// engine that had never once been loaded, which is the one cold engine a
    /// key press cannot warm. Hanging the rule on the fact itself, rather than
    /// on the events that happen to produce it, is what makes it standing.
    @Published public private(set) var modelState: ModelState = .notInstalled {
        didSet {
            guard modelState.isReady else { return }
            prepareEngineIfIdleAndCold()
        }
    }
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
    @Published public private(set) var isEngineReady = false {
        didSet { if isEngineReady { hasEngineBeenReady = true } }
    }
    /// Whether the engine has ever been ready in this process.
    ///
    /// Splits two very different "not ready" states: the FIRST warm-up after
    /// install (blocks dictation with an honest message — there is genuinely
    /// nothing to recognize with yet) and a residency unload (recording must
    /// start instantly; the reload rides under the voice).
    public private(set) var hasEngineBeenReady = false
    /// How much the installation button will download: the full volume or additional volume after the update.
    @Published public private(set) var remainingDownloadMegabytes = 586
    /// What a fresh start costs: both models, from nothing.
    ///
    /// The delete confirmation asks a different question from the download
    /// button — not "what is missing now" but "what will you pay to get this
    /// back" — and the answer is always both models, because deleting removes
    /// both. Asking `remainingDownloadMegabytes` there gives 0, which is why
    /// that sentence used to carry an `== 0 ? 586` and print a constant nobody
    /// recomputed when the manifests changed. Read from the bundled manifests,
    /// so it needs no fallback: a run that could not read them has no store,
    /// and therefore no model to offer for deletion.
    public var fullModelDownloadMegabytes: Int {
        Int((mainModelBytes + 500_000) / 1_000_000)
    }
    /// Text of unsuccessful insertion. Never written to disk.
    @Published public private(set) var recoveredText: String?
    /// Technical-failure audio retained under the documented age/count/size
    /// limits. The menu exposes the count and an exact Finder destination;
    /// crash recovery is never a hidden disk write.
    @Published public private(set) var recoveredRecordingCount = 0
    /// Fail-closed recovery state after the bounded delete-intent lane could
    /// no longer retain exact identities. Ambiguous audio stays untouched and
    /// the menu exposes the Support folder instead of silently guessing.
    @Published public private(set) var recordingRecoveryStorageFaulted = false
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

    /// Finished dictations kept on disk, newest first, with their audio.
    @Published public private(set) var history: [HistoryEntry] = []

    /// How many takes the history keeps. Changing it trims what is already
    /// stored, so lowering the number is a deletion the person can rely on.
    @Published public var historyLimit: Int {
        didSet {
            guard oldValue != historyLimit else { return }
            defaults.set(historyLimit, forKey: DictationHistoryStore.limitKey)
            guard let historyStore else { return }
            history = (try? historyStore.applyLimit(historyLimit)) ?? history
        }
    }

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

    /// Also leave the finished text on the clipboard.
    ///
    /// Off by default, and deliberately: dictated text on the clipboard is
    /// dictated text handed to every clipboard manager on the machine, and the
    /// product's promise is that what you say stays here. Someone who wants it
    /// can ask, and then it is written host-only with the transient and
    /// concealed markers, the same as every other copy this app makes.
    @Published public var copiesToClipboard: Bool {
        didSet {
            guard oldValue != copiesToClipboard else { return }
            defaults.set(copiesToClipboard, forKey: Keys.copyToClipboard)
        }
    }

    /// Which microphone to record through, by its stable UID.
    ///
    /// `nil` means whatever the system calls default, which is what almost
    /// everyone wants and what the app did before this existed. The UID rather
    /// than the numeric device id, because the numbers are handed out per boot
    /// and reused — a stored one can name a different microphone tomorrow.
    @Published public var inputDeviceUID: String? {
        didSet {
            guard oldValue != inputDeviceUID else { return }
            defaults.set(inputDeviceUID ?? "", forKey: Keys.inputDevice)
        }
    }

    /// The microphones this Mac can hear through, right now.
    public var availableInputDevices: [AudioInputDevice] { AudioInputDevices.available() }

    /// The chosen microphone as CoreAudio knows it, or `nil` for the default.
    ///
    /// A device that has been unplugged resolves to `nil` rather than failing:
    /// dictation still works through the default input, and `inputDeviceNotice`
    /// is what makes sure the person is told rather than left wondering why
    /// their headset is not being used.
    var preferredInputDeviceID: AudioDeviceID? {
        inputDeviceUID.flatMap(AudioInputDevices.deviceID(forUID:))
    }

    /// Set when the chosen microphone is not on this machine.
    public var inputDeviceNotice: String? {
        guard let inputDeviceUID, !inputDeviceUID.isEmpty else { return nil }
        guard preferredInputDeviceID == nil else { return nil }
        return "The microphone you chose isn't connected. Dictation is using the system default."
    }

    /// End every dictation with a space.
    ///
    /// Off by default: most dictations land in the middle of writing, where a
    /// stray space at the end is noise. On, it is for people who dictate in
    /// runs — without it the next phrase arrives welded to the last word.
    @Published public var appendsTrailingSpace: Bool {
        didSet {
            guard oldValue != appendsTrailingSpace else { return }
            defaults.set(appendsTrailingSpace, forKey: Keys.trailingSpace)
        }
    }

    /// Light, dark, or whatever the machine is doing.
    @Published public var appearance: AppAppearance {
        didSet {
            guard oldValue != appearance else { return }
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            Self.apply(appearance)
        }
    }

    /// Hand the choice to AppKit, which owns every window including the ones
    /// SwiftUI has not made yet.
    static func apply(_ appearance: AppAppearance) {
        NSApp?.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The shortcut that copies the last dictation, or nothing.
    ///
    /// Optional because most people will not want a second global shortcut
    /// taken out of their keyboard, and one nobody asked for is one that
    /// collides with something they already use.
    @Published public var copyShortcut: KeyCombination? {
        didSet {
            guard oldValue != copyShortcut else { return }
            defaults.set(copyShortcut?.rawValue ?? "", forKey: Keys.copyShortcut)
            applyCopyShortcut()
        }
    }

    /// Point the second watcher at the chosen shortcut, or take it off the
    /// keyboard.
    private func applyCopyShortcut() {
        guard let copyShortcutMonitor else { return }
        copyShortcutMonitor.setShortcut(copyShortcut)
        guard copyShortcut != nil else { return }
        // Only once dictation itself is running: before that the app has no
        // Accessibility permission and starting would fail silently.
        if hotkeyMonitor.isRunning, !copyShortcutMonitor.isRunning {
            copyShortcutMonitor.start()
        }
    }

    @Published public var overlayPlacement: DictationOverlayPlacement {
        didSet {
            guard oldValue != overlayPlacement else { return }
            defaults.set(overlayPlacement.rawValue, forKey: Keys.overlayPlacement)
            (overlay as? any OverlayPlacementConfiguring)?.placement = overlayPlacement
        }
    }

    /// Replacement dictionary. Changes only through the methods below: direct write bypassed
    /// would check that the dictionary can be saved at all.
    @Published public private(set) var replacements: [DictionaryReplacement]

    private enum Keys {
        static let hotkey = "hotkey"
        static let sounds = "soundsEnabled"
        static let copyToClipboard = "copyToClipboard"
        static let copyShortcut = "copyShortcut"
        static let trailingSpace = "appendsTrailingSpace"
        static let appearance = "appearance"
        static let inputDevice = "inputDeviceUID"
        static let overlayPlacement = "overlayPlacement"
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
    private let copyShortcutMonitor: (any ShortcutMonitoring)?
    private let inserter: any TextInserting
    private let targetApplicationSnapshot: @Sendable () -> TargetApplication?
    private let clipboardRestoreReporter: ClipboardRestoreReporter?
    private let overlay: any OverlayPresenting
    private let makeSounds: @MainActor (@escaping @MainActor () -> Bool) -> any Sounding
    private let makeCapture: (
        URL,
        @escaping @Sendable (DictationSessionID, AudioCaptureError) -> Void,
        @escaping @Sendable ([Float]) -> Void,
        @escaping @Sendable (DictationSessionID) -> Void,
        AudioDeviceID?
    ) -> any AudioCapturing
    private let transcribe: (URL, @escaping @Sendable () -> String?) -> @Sendable (URL) async throws -> ASRResult
    private let recoveryInsertionDeadline: Duration
    private let engineWarmupRetryDelayOverride: Duration?
    private let recordingRecoveryCompatibilityGrace: TimeInterval
    private let recordingRecoveryMaintenanceRetryDelay: TimeInterval
    private let recordingRecoveryIdleScanInterval: TimeInterval
    private let permissionPollInterval: TimeInterval
    private let modelDownloader: any ModelDownloading
    private let requestMicrophoneAccess: () async -> Bool
    private let openMicrophoneSettings: () -> Void
    private let activateApplication: () -> Void
    private let workspaceNotifications: NotificationCenter
    private let notifications: NotificationCenter
    private let replacementsStore: ReplacementsStore
    private let cleanupLegacyAgentStaging: @Sendable () throws -> Void

    /// Updates. A separate object with its own subscribers: check mark
    /// autochecks live in Sparkle settings, not in our `defaults`.
    public let updater = SparkleUpdater()

    private var store: ModelStore?
    private var historyStore: DictationHistoryStore?
    private var mainModelBytes: Int64 = 0
    private var mainModelFileCount = 0
    private var transcriber: (any DictationRecognizing)?
    private var recordingRecovery: RecordingRecoveryStore?
    private var recordingRecoveryMaintenanceTask: Task<Void, Never>?
    private var engineReadinessTask: Task<Void, Never>?
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
    /// Model preparation is single-flight at the AppState boundary as well as
    /// inside the worker. This keeps UI state and recovery decisions causal
    /// when startup, wake and memory-pressure events arrive together.
    private var engineWarmupTask: Task<EngineWarmupOutcome, Never>?
    private var engineWarmupTaskRevision = 0
    /// At most one bounded retry loop may exist. A transient worker failure
    /// never becomes a model-redownload request.
    private var engineWarmupRetryTask: Task<Void, Never>?
    private var engineWarmupRetryRevision = 0

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
            guard oldValue != launchAtLogin, !isReconcilingLaunchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    private var isReconcilingLaunchAtLogin = false
    private var didCompleteInitialPermissionRefresh = false

    // Timers and subscriptions are marked `nonisolated(unsafe)` because they are removed
    // `deinit`, and it is for an isolated class - outside of isolation. They only touch them
    // from the main thread: the application lives entirely on it.
    nonisolated(unsafe) private var permissionTimer: Timer?
    nonisolated(unsafe) private var systemObservers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    public var isDictationReady: Bool {
        accessibilityGranted && microphoneGranted && modelState.isReady
            && (isEngineReady || hasEngineBeenReady)
    }

    /// How often permissions are now polled. Zero - polling is not running.
    ///
    /// Outwardly visible on purpose: the promise “at rest the application does nothing”
    /// is checked with this particular number.
    public private(set) var permissionPollingInterval: TimeInterval = 0

    public var isPollingPermissions: Bool { permissionTimer != nil }

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
        editWatcher = EditLearningWatcher(reader: environment.focusedFieldReader)
        // No key = disabled: `bool(forKey:)` returns false. This
        // reads someone else's window and therefore requires an explicit opt-in.
        historyLimit = DictationHistoryStore.storedLimit(in: environment.defaults)
        learnFromEdits = environment.defaults.bool(forKey: Self.learnFromEditsKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        paths = environment.paths
        permissions = environment.permissions
        accessibilityManager = environment.accessibilityManager
        hotkeyMonitor = environment.hotkeyMonitor
        copyShortcutMonitor = environment.copyShortcutMonitor
        inserter = environment.inserter
        targetApplicationSnapshot = environment.targetApplicationSnapshot
        clipboardRestoreReporter = environment.clipboardRestoreReporter
        overlay = environment.overlay
        makeSounds = environment.makeSounds
        makeCapture = environment.makeCapture
        transcribe = environment.transcribe
        recoveryInsertionDeadline = environment.recoveryInsertionDeadline
        engineWarmupRetryDelayOverride = environment.engineWarmupRetryDelay
        idleUnloadDelayOverride = environment.idleUnloadDelayOverride
        modelUnloadTimeout = IdleUnloadPolicy.stored(in: environment.defaults)
        recordingRecoveryCompatibilityGrace = environment.recordingRecoveryCompatibilityGrace
        recordingRecoveryMaintenanceRetryDelay = environment.recordingRecoveryMaintenanceRetryDelay
        recordingRecoveryIdleScanInterval = environment.recordingRecoveryIdleScanInterval
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
        cleanupLegacyAgentStaging = environment.cleanupLegacyAgentStaging

        hotkey = DictationHotkey(rawValue: environment.defaults.string(forKey: Keys.hotkey) ?? "")
            ?? SettingsDefaults.hotkey
        soundsEnabled = environment.defaults.object(forKey: Keys.sounds) as? Bool ?? SettingsDefaults.soundsEnabled
        // Off unless asked for: dictated text on the clipboard is dictated text
        // handed to every clipboard manager on the machine.
        copiesToClipboard = environment.defaults.object(forKey: Keys.copyToClipboard) as? Bool
            ?? SettingsDefaults.copiesToClipboard
        copyShortcut = (environment.defaults.string(forKey: Keys.copyShortcut))
            .flatMap(KeyCombination.init(rawValue:))
        appendsTrailingSpace = environment.defaults.object(forKey: Keys.trailingSpace) as? Bool
            ?? SettingsDefaults.appendsTrailingSpace
        appearance = AppAppearance(
            rawValue: environment.defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? SettingsDefaults.appearance
        inputDeviceUID = (environment.defaults.string(forKey: Keys.inputDevice))
            .flatMap { $0.isEmpty ? nil : $0 }
        overlayPlacement = DictationOverlayPlacement(
            rawValue: environment.defaults.string(forKey: Keys.overlayPlacement) ?? ""
        ) ?? SettingsDefaults.overlayPlacement
        let loaded = replacementsStore.load()
        replacements = loaded.replacements
        dictionaryProblem = loaded.problem

        (overlay as? any OverlayPlacementConfiguring)?.placement = overlayPlacement

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
        engineWarmupTask?.cancel()
        engineWarmupRetryTask?.cancel()
        recordingRecoveryMaintenanceTask?.cancel()
        engineReadinessTask?.cancel()
        for observer in systemObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    // MARK: - Assembly

    private func setUp() {
        let sounds = makeSounds { [weak self] in self?.soundsEnabled ?? true }

        do {
            let capture = makeCapture(
                try paths.takes(),
                { [weak self] session, error in
                    // The audio stream is no longer usable in the middle of a speech. Wait
                    // stopping is not possible: the person speaks into emptiness, and the reason
                    // must be shown exactly.
                    Task { @MainActor in
                        self?.controller?.interrupt(
                            session: session,
                            reason: Self.captureFailureMessage(error)
                        )
                    }
                },
                { [weak self] samples in
                    // The peak is sufficient for the waveform; RMS would hide short
                    // consonant transients that make the live signal feel responsive.
                    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                    Task { @MainActor in self?.registerInputLevel(peak) }
                },
                { [weak self] session in
                    // Disk spill never gates the microphone. If it remained
                    // unavailable until the bounded PCM buffer became full,
                    // finish the complete retained take normally instead of
                    // dropping history or continuing into unrecoverable audio.
                    Task { @MainActor in
                        self?.controller?.stopAtCaptureMemoryLimit(session: session)
                    }
                },
                preferredInputDeviceID
            )
            let recordingRecovery = RecordingRecoveryStore(
                directory: try paths.audioRecovery(),
                compatibilityGrace: recordingRecoveryCompatibilityGrace,
                maintenanceRetryDelay: recordingRecoveryMaintenanceRetryDelay,
                idleScanInterval: recordingRecoveryIdleScanInterval
            )
            self.recordingRecovery = recordingRecovery

            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            let store = ModelStore(manifest: manifest, layout: layout, downloader: modelDownloader)
            self.store = store
            mainModelBytes = manifest.totalByteCount
            mainModelFileCount = manifest.files.count

            let historyStore = DictationHistoryStore(
                directory: try paths.support()
                    .appending(path: "History", directoryHint: .isDirectory)
            )
            self.historyStore = historyStore
            history = historyStore.load()

            let engineDirectory = layout.engineDirectory
            self.engineDirectory = engineDirectory
            // The model spans 25 languages with one tokenizer and detects which
            // is being spoken, including speech that switches between them
            // mid-sentence. A forced language could only make that worse, so
            // there is no setting and nothing to read.
            let languageHint: @Sendable () -> String? = { nil }
            let transcribeSamples: (@Sendable ([Float]) async throws -> ASRResult)?
            if let transcriber {
                transcribeSamples = { samples in
                    try await transcriber.transcribe(
                        samples: samples,
                        languageHint: languageHint()
                    )
                }
            } else {
                transcribeSamples = nil
            }
            let controller = DictationController(
                capture: capture,
                transcribe: transcribe(
                    engineDirectory,
                    languageHint
                ),
                transcribeSamples: transcribeSamples,
                inserter: inserter,
                targetApplicationSnapshot: targetApplicationSnapshot,
                overlay: overlay,
                sounds: sounds,
                recordingRecovery: recordingRecovery,
                pipeline: { [weak self] in
                    self?.makePipeline() ?? TextPipeline()
                },
                prepareForTranscription: makePrepareForTranscription(
                    engineDirectory: engineDirectory
                )
            )
            controller.onStateChange = { [weak self] state in
                self?.dictationState = state
                self?.flushNoticeAfterSession(state)
                // The person just pressed the key and is about to speak for
                // seconds. Refresh accelerator residency now, under their
                // voice, instead of trusting a device-specific idle timer and
                // discovering a cold Core ML graph only after key-up.
                if state == .preparing { self?.warmEngineUnderVoice() }
                // The moment the person stopped speaking, before any of the
                // remaining work has run. A diagnostics build samples the
                // machine here so the closing sample has something to be
                // differenced against; a release build does nothing at all.
                if state == .transcribing, let self {
                    DictationDiagnostics.noteStop(
                        engineWasReady: self.isEngineReady,
                        unloadPolicy: self.modelUnloadTimeout
                    )
                }
                // Every state change re-arms or cancels the idle-unload
                // timer: activity disarms it, idleness starts the countdown.
                self?.rescheduleIdleUnload()
            }
            controller.onNotice = { [weak self] notice in
                self?.lastNotice = notice
                if notice.recoveryAudio != nil {
                    self?.refreshRecoveredRecordingCount()
                }
                if let text = notice.recoverableText {
                    self?.recoveredText = text
                    // The words also join Recent Dictations at failure time:
                    // the single recovery slot is overwritten by the next
                    // failure, and without this copy the first failure's words
                    // would silently vanish from the person's reach.
                    self?.rememberFailedInsertion(text)
                }
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
            controller.onTranscriptionStall = { [weak self] in
                // Recognition blew its deadline: the engine is presumed wedged
                // on a dead system service. A fresh session is the cure.
                self?.recycleWedgedEngine()
            }
            controller.onTextInserted = { [weak self] text in
                guard let self else { return }
                self.recordSuccessfulDictation(text)
                if self.copiesToClipboard {
                    // Host-only with the transient and concealed markers, like
                    // every other copy this app makes: asking for the clipboard
                    // is not asking for it to be synced to other devices.
                    try? HostOnlyPasteboard().copyHostOnly(text)
                }
                guard self.learnFromEdits else { return }
                self.editWatcher.beginWatching(inserted: text) { [weak self] original, edited in
                    self?.learn(original: original, edited: edited)
                }
            }
            controller.onEnginePreparationWait = { [weak self] waiting in
                // The panel is the only feedback channel during dictation, and
                // a wait for a model that is still loading is not the same
                // event as transcription. Presenters that cannot say so simply
                // keep their previous message.
                (self?.overlay as? any EngineWaitPresenting)?
                    .setWaitingForEngine(waiting)
            }
            controller.onSpeed = { [weak self] report in
                // Keep the measurement for diagnostics and performance tests, but do
                // not cover the destination app after text has already arrived.
                self?.lastSpeed = report
                // `notice`, not `info`: a slow take is exactly the entry that
                // must survive in the system log long enough to be read, and
                // `info` rotates within hours on a busy Mac. The stages travel
                // with it because the total alone cannot name the cause.
                engineLog.notice(
                    """
                    dictation stop→text \(report.toRecognizedText.appSeconds, format: .fixed(precision: 2))s \
                    stop→paste \(report.toPasteDispatched?.appSeconds ?? -1, format: .fixed(precision: 2))s \
                    freeze \(report.phases?.captureFreeze.appSeconds ?? -1, format: .fixed(precision: 2))s \
                    prepare \(report.phases?.enginePreparation?.appSeconds ?? -1, format: .fixed(precision: 2))s \
                    recognize \(report.phases?.recognition.appSeconds ?? -1, format: .fixed(precision: 2))s \
                    engine \(report.phases?.engineProcessing?.appSeconds ?? -1, format: .fixed(precision: 2))s \
                    audio \(report.phases?.audioDuration.appSeconds ?? -1, format: .fixed(precision: 2))s
                    """
                )
                DictationDiagnostics.noteCompleted(
                    report: report,
                    characterCount: self?.lastDictation?.insertedText.count ?? 0
                )
            }
            controller.onTakeFinished = { [weak self] text, audio in
                self?.archive(text: text, audio: audio)
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
        scheduleLegacyCleanup()
        Task {
            await startEngineReadinessMonitoring()
            await startRecordingRecoveryMaintenance()
            await importAbandonedRecordings()
            // No explicit warm-up here: reading the disk publishes the model
            // state, and readiness itself starts preparation. Launch is not a
            // special case, and having it be one is how the rule came to hold
            // at launch and nowhere else.
            await refreshModelState()
        }
    }

    /// The worker process is the authority on readiness. In particular, an
    /// idle child can disappear after AppState previously published Ready; a
    /// local sticky Bool must not hide that death until the next key release.
    private func startEngineReadinessMonitoring() async {
        guard engineReadinessTask == nil, let transcriber else { return }
        let changes = await transcriber.readinessChanges()
        engineReadinessTask = Task { @MainActor [weak self] in
            for await ready in changes {
                guard !Task.isCancelled, let self else { return }
                self.isEngineReady = ready
            }
        }
    }

    /// A residency-managed engine may be cold at stop time; the reload has
    /// been running since the keypress and gets its own budget in the
    /// controller so a two-second utterance's recognition deadline never has
    /// to cover a sixteen-second load. The single-flight transcriber
    /// coalesces this with the reload already in flight. Test environments
    /// (transcriber == nil) keep the old shape: no separate prepare phase.
    private func makePrepareForTranscription(
        engineDirectory: URL
    ) -> (@Sendable () async throws -> Void)? {
        guard let transcriber else { return nil }
        return {
            // The controller owns only the foreground wait. Model loading and
            // Core ML specialization belong to the persistent worker and must
            // survive a short utterance exhausting that wait; otherwise the
            // deadline kills a healthy almost-ready generation and guarantees
            // another cold start on the next dictation.
            try await awaitOwnedEnginePreparation {
                try await transcriber.prepare(modelDirectory: engineDirectory)
            }
        }
    }

    /// Old builds wrote unrecognized text to disk in `Recovered/`.
    /// Now such text lives only in memory, and the promise of “recognized text
    /// is not written to disk” must also cover traces of previous versions.
    /// Upgrade cleanup is filesystem work, not a launch prerequisite. Run one
    /// bounded lifetime job away from MainActor so a stalled directory scan or
    /// unlink cannot freeze hotkeys, permission UI, or engine preparation.
    private func scheduleLegacyCleanup() {
        let paths = paths
        let cleanupAgentStaging = cleanupLegacyAgentStaging
        Task.detached(priority: .utility) { [weak self] in
            let notices = Self.performLegacyCleanup(
                paths: paths,
                cleanupAgentStaging: cleanupAgentStaging
            )
            guard !notices.isEmpty else { return }
            await self?.publishLegacyCleanupNotices(notices)
        }
    }

    nonisolated private static func performLegacyCleanup(
        paths: AppPaths,
        cleanupAgentStaging: @Sendable () throws -> Void
    ) -> [DictationNotice] {
        var notices: [DictationNotice] = []
        if let support = try? paths.support() {
            let legacy = support.appending(path: "Recovered", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: legacy.path) {
                do {
                    try FileManager.default.removeItem(at: legacy)
                } catch {
                    notices.append(
                        DictationNotice(
                            kind: .warning,
                            message: "Couldn't delete the old version's recovery texts. "
                                + "Delete them manually: ~/Library/Application Support/OpenRamble/Recovered"
                        )
                    )
                }
            }
        }

        do {
            try cleanupAgentStaging()
        } catch {
            notices.append(
                DictationNotice(
                    kind: .warning,
                    message: "Couldn't delete audio staged by the retired agent transcription feature. Restart OpenRamble to retry cleanup."
                )
            )
        }
        return notices
    }

    private func publishLegacyCleanupNotices(_ notices: [DictationNotice]) {
        for notice in notices { notify(notice) }
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

    /// Tidy up recordings left behind by a kill or power loss.
    ///
    /// The import repairs interrupted WAV headers, discards fragments too
    /// short to hold speech, and prunes the folder by age, count and size.
    /// A newly imported take is disclosed once and every retained take remains
    /// discoverable from the menu. Existing takes do not produce a launch
    /// notification on every run; their count is still visible.
    private func importAbandonedRecordings() async {
        guard let recordingRecovery else { return }
        do {
            let result = try await recordingRecovery.importAbandoned(from: paths.takes())
            applyRecordingRecoveryResult(result)
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Couldn't prepare recording recovery: \(error.localizedDescription)"
                )
            )
        }
    }

    /// Subscribe before the first import so a fresh crash artifact that is
    /// deliberately skipped during the cross-instance grace window is picked
    /// up in this same process. The store owns one bounded maintenance loop;
    /// this task only reflects its results into product state.
    private func startRecordingRecoveryMaintenance() async {
        guard recordingRecoveryMaintenanceTask == nil,
              let recordingRecovery
        else { return }
        let results = await recordingRecovery.maintenanceResults()
        recordingRecoveryMaintenanceTask = Task { @MainActor [weak self] in
            for await result in results {
                guard !Task.isCancelled, let self else { return }
                self.applyRecordingRecoveryResult(result)
            }
        }
    }

    private func applyRecordingRecoveryResult(
        _ result: AbandonedRecordingImportResult
    ) {
        recoveredRecordingCount = result.recordings.count
        if result.storageFaulted {
            let isNewFault = !recordingRecoveryStorageFaulted
            recordingRecoveryStorageFaulted = true
            if isNewFault {
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "Automatic audio recovery was disabled after a storage failure. "
                            + "Open Recording Support Files from the menu: ambiguous recordings "
                            + "were left untouched, not deleted or imported."
                    )
                )
            }
            return
        }

        guard result.newlyImportedCount > 0 else { return }
        let noun = result.newlyImportedCount == 1 ? "recording" : "recordings"
        notify(
            DictationNotice(
                kind: .warning,
                message: "OpenRamble recovered \(result.newlyImportedCount) unfinished \(noun) "
                    + "after an interrupted session. Open Recovered Recordings from the menu "
                    + "to review or delete the audio; retention is limited to seven days."
            )
        )
    }

    private func refreshRecoveredRecordingCount() {
        guard let recordingRecovery else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                self.recoveredRecordingCount = try await recordingRecovery.recordings().count
            } catch {
                engineLog.error(
                    "couldn't refresh recovered recording count: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Open the exact retention directory. Finder supplies explicit Preview,
    /// Move and Delete actions without the app reading or transcribing audio in
    /// the background.
    public func revealRecoveredRecordings() {
        do {
            let directory = recordingRecoveryStorageFaulted
                ? try paths.support()
                : try paths.audioRecovery()
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: "Couldn't reveal recovered recordings: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Verbatim text of the last dictation

    /// Keep a finished take: its text, and a copy of its audio.
    ///
    /// Failures here are reported rather than swallowed. A history that
    /// silently stops recording looks exactly like a history of someone who
    /// stopped dictating.
    private func archive(text: String, audio: URL) {
        guard let historyStore else { return }
        do {
            history = try historyStore.record(text: text, audio: audio, limit: historyLimit)
        } catch {
            engineLog.error("history entry not written")
        }
    }

    /// The take's audio, if it is still on disk.
    public func historyAudioURL(for entry: HistoryEntry) -> URL? {
        historyStore?.audioURL(for: entry)
    }

    public func deleteHistoryEntry(_ entry: HistoryEntry) {
        guard let historyStore else { return }
        history = (try? historyStore.delete(entry)) ?? history
    }

    public func clearHistory() {
        guard let historyStore else { return }
        try? historyStore.deleteAll()
        history = []
    }

    /// Put a stored transcript back on the clipboard.
    ///
    /// Host-only and concealed, exactly like every other copy this app makes: a
    /// transcript must not travel to another Mac through Universal Clipboard
    /// just because it came from a list rather than from a live dictation.
    public func copyHistoryEntry(_ entry: HistoryEntry) {
        do {
            try HostOnlyPasteboard().copyHostOnly(entry.text)
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the dictation."))
        }
    }

    private func recordSuccessfulDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        successfulDictationCount += 1
        recoveredText = nil
        prependRecentDictation(trimmed)
    }

    /// Words that failed to insert enter the history immediately.
    ///
    /// Idempotent across repeated failures of the same text: retrying the
    /// insertion and failing again must not fill the history with copies.
    private func rememberFailedInsertion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, recentDictations.first?.text != trimmed else { return }
        prependRecentDictation(trimmed)
    }

    private func prependRecentDictation(_ trimmed: String) {
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

    /// Is there anything to copy as spoken.
    ///
    /// Only when the raw words actually differ from the inserted text: for
    /// most dictations the dictionary and cosmetics change nothing, and the
    /// menu item would be a duplicate of the last recent dictation.
    public var canCopyRawDictation: Bool {
        guard let lastDictation else { return false }
        let raw = lastDictation.provenance.raw
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return raw != lastDictation.insertedText
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
            notify(DictationNotice(kind: .info, message: "Copied as spoken — to this Mac only."))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the spoken text."))
        }
    }

    /// Put the last dictation back on the clipboard.
    ///
    /// The text as it was inserted, not the raw words: this is the "I need that
    /// again" action, and what the person saw appear is what they mean.
    public func copyLastDictation() {
        guard let text = lastDictation?.insertedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            notify(DictationNotice(kind: .info, message: "Nothing dictated yet."))
            return
        }
        do {
            try HostOnlyPasteboard().copyHostOnly(text)
            notify(DictationNotice(kind: .info, message: "Copied — to this Mac only."))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the dictation."))
        }
    }

    // MARK: - Recovering a failed insertion

    public func retryRecoveredText() {
        guard dictationState == .idle,
              !isRecoveryOperationActive,
              let recoveredText
        else { return }
        // The destination is maintained ahead of the click. Querying
        // NSWorkspace synchronously here can wedge MainActor and permanently
        // lock both Retry and the dictation hotkey.
        let target = targetApplicationSnapshot()
        isRecoveryOperationActive = true
        dictationState = .inserting
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.dictationState = .idle
                self.isRecoveryOperationActive = false
            }
            do {
                let inserter = inserter
                try await withTranscriptionDeadline(recoveryInsertionDeadline) {
                    try await inserter.insert(recoveredText, into: target)
                }
                // The words already joined Recent Dictations at failure time;
                // appending again here would duplicate them. The provenance
                // slot is cleared too: it still holds the PREVIOUS dictation,
                // and "Copy Last as Spoken" must not offer someone else's raw
                // text after inserting recovered words.
                self.successfulDictationCount += 1
                self.recoveredText = nil
                self.lastDictation = nil
            } catch is TranscriptionTimeout {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Insertion couldn't be confirmed in time. The text stays in the menu and may already have been pasted.",
                        recoverableText: recoveredText
                    )
                )
            } catch {
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "The text still couldn't be inserted — it stays in the menu.",
                        recoverableText: recoveredText
                    )
                )
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
        // Coming back to the app is a cheap hint that dictation is near.
        rewarmEngineIfCold(trigger: .appActivation)
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
        copyShortcutMonitor?.stop()
        refreshPermissions()
        revalidateEngineAfterWake()
    }

    /// Whether an engine recycle is already underway — one wedge, one cure.
    private var isRecyclingEngine = false

    /// Run one second of silence through the engine to pull its weights back
    /// onto the Neural Engine. The measured stakes: 0.13 s warm, 16.06 s
    /// after eviction. A hung ping means the engine is wedged on a dead
    /// system service — recycle it.
    private func pingEngine(deadline: Duration) {
        guard let transcriber else { return }
        Task { [weak self] in
            do {
                _ = try await withTranscriptionDeadline(deadline) {
                    try await transcriber.warmUpInference()
                }
            } catch {
                await MainActor.run { [weak self] in self?.recycleWedgedEngine() }
            }
        }
    }

    /// Internal, not private: the residency pin drives the exact press hook.
    func warmEngineUnderVoice() {
        guard transcriber != nil, !isRecyclingEngine else { return }
        // Residency gave the memory back: the press starts the FULL reload —
        // weights — in parallel with the recording. The
        // single-flight transcriber coalesces this with the transcription
        // path's own prepare, and the preparation UI narrates honestly if
        // the reload outlasts the speech.
        guard isEngineReady else {
            // Same single-flight path the key-down trigger takes; by the time
            // this runs the reload is usually already riding under the voice.
            rewarmEngineIfCold(trigger: .keyDown)
            return
        }
        // A ready engine needs nothing further. There used to be a "ping" here
        // — a full inference over a second of silence, on every key press,
        // which the real dictation then waited for. That made every dictation
        // two inferences where Handy does one, and its cost was invisible: the
        // ping's own duration was discarded, and the waiting sat inside the
        // reported `recognition` but outside the reported `engine`. It is also
        // why the engine number never passed ~1.07 s while the gap reached
        // 13.74 s — the sacrificial first run paid whatever the second would
        // have.
        //
        // Its stated reason was Core ML weights not materialising every
        // prediction path. There is no Core ML in this app; that engine was
        // removed. The comment outlived the runtime it described.
    }

    /// Release the engine before the process exits.
    ///
    /// The inference runtime destroys its Metal device from a static
    /// destructor at `exit()`. If the model is still loaded when that runs, the
    /// device is torn down with live buffers under it and the runtime aborts —
    /// so a quit that should be silent produces a crash report instead, every
    /// time, on a Mac that was working perfectly.
    ///
    /// Unloading here is also simply correct: nearly a gigabyte goes back to
    /// the system at the moment the person asked the app to go away. The wait
    /// is bounded because quitting must not hang on a wedged engine; a killed
    /// process at least fails the same way it does today rather than aborting.
    public func releaseEngineBeforeTermination(timeout: Duration = .seconds(3)) {
        guard let transcriber else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await transcriber.unload()
            done.signal()
        }
        _ = done.wait(timeout: .now() + .milliseconds(Int(timeout.components.seconds * 1000)))
    }

    /// Show the support folder in Finder.
    ///
    /// Kept recordings, downloaded models — everything the app writes lives
    /// here. The failure notice points at this button, so a preserved take
    /// is never a file the person can't find without a terminal.
    func revealSupportFolder() {
        do {
            let support = try paths.support()
            NSWorkspace.shared.activateFileViewerSelecting([support])
        } catch {
            // Application Support failing to materialize is a disk-level
            // event; the click must still not pass silently.
            NSSound.beep()
        }
    }

    // MARK: - Engine residency (automatic, zero settings)

    /// True while an engine that was deliberately given back should stay cold.
    ///
    /// A residency eviction or an idle unload is a decision, not a failure: the
    /// comeback belongs to the next key press. The standing preparation rule
    /// must respect that, or the app would immediately reload what it just
    /// released. Setup never sets this, because during setup the person is
    /// waiting for the engine rather than resting from it.
    private var shouldStayUnloadedUntilUse = false

    /// When to give the engine's memory back after dictation goes idle.
    /// Mirrors Handy's "Unload Model" row; `.never` is the pre-0.8 behavior.
    @Published public var modelUnloadTimeout: IdleUnloadPolicy {
        didSet {
            guard oldValue != modelUnloadTimeout else { return }
            defaults.set(modelUnloadTimeout.rawValue, forKey: IdleUnloadPolicy.defaultsKey)
            rescheduleIdleUnload()
        }
    }

    /// One pending idle-unload timer at most; any dictation activity replaces
    /// it through the state-change hook.
    private var idleUnloadTask: Task<Void, Never>?

    private func rescheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard dictationState == .idle,
              isEngineReady,
              // Setup is not idleness: the person is granting permissions, not
              // resting from dictation, and the try-out is a minute away. The
              // engine stays so that first dictation is instant. Nothing
              // depends on this any more — the setup screen no longer waits
              // for a loaded engine, and a resting one is woken by the same
              // key press as everywhere else — so it is a courtesy, not a
              // guard.
              hasCompletedOnboarding,
              let policyDelay = modelUnloadTimeout.idleDelay
        else { return }
        // The override shortens the countdown for tests; the decision itself
        // (`never` keeps the engine forever) always belongs to the policy.
        let delay = idleUnloadDelayOverride ?? policyDelay
        idleUnloadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.performIdleUnload()
        }
    }

    private func performIdleUnload() async {
        idleUnloadTask = nil
        guard dictationState == .idle,
              !isRecoveryOperationActive,
              !isRecyclingEngine,
              !isPreparingEngine,
              isEngineReady,
              let transcriber
        else { return }
        engineLog.notice(
            "engine idle unload: \(self.modelUnloadTimeout.rawValue, privacy: .public)"
        )
        guard await transcriber.unloadIfIdle() else { return }
        isEngineReady = false
        shouldStayUnloadedUntilUse = true
        enginePreparation = .make(phase: .idle, elapsed: 0)
        // Deliberately no proactive rewarm: the comeback is the next key
        // press, riding under the voice.
    }

    /// Test-only idle-unload countdown override (see AppEnvironment).
    private let idleUnloadDelayOverride: Duration?

    /// The onboarding window owns this flag; the engine only reads it, to know
    /// whether the person has finished setting the app up.
    private var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.onboardingCompletedKey)
    }

    nonisolated static let onboardingCompletedKey = "onboardingCompleted"

    /// Does the app currently want a ready engine?
    ///
    /// The files are usable, the recognizer is not loaded, and nobody gave the
    /// memory back on purpose. This is the "desired state" half of the rule
    /// that keeps setup from stalling; it is deliberately not about events.
    private var wantsEngineReady: Bool {
        modelState.isReady && !isEngineReady && !shouldStayUnloadedUntilUse
    }

    /// Leave the "downloaded but cold" state without waiting for an event.
    ///
    /// Preparation used to be started only by events: launch, a finished
    /// install, a key press, an app activation. Any missed event left the model
    /// ready on disk, the engine cold, nothing running, and a setup screen
    /// claiming to prepare. This is the standing rule instead of those events:
    /// if the files are ready and the engine is not, and no attempt is alive,
    /// start one. Safe to call from anywhere — `warmUpEngine` single-flights.
    func prepareEngineIfIdleAndCold() {
        guard transcriber != nil,
              modelState.isReady,
              !isEngineReady,
              !isPreparingEngine,
              engineWarmupTask == nil,
              engineWarmupRetryTask == nil,
              !isRecyclingEngine,
              !isInstalling,
              // A deliberate residency or idle unload owns its own comeback:
              // that engine is meant to stay cold until the next key press.
              !shouldStayUnloadedUntilUse
        else { return }
        engineLog.info("engine preparation resumed: ready model, cold engine, nothing running")
        Task { [weak self] in await self?.warmUpEngine() }
    }

    /// What woke the engine back up.
    enum RewarmTrigger: String {
        case keyDown
        case appActivation
    }

    /// The earliest reload triggers: they fire before any readiness guard can
    /// swallow the press. Single-flight through `warmUpEngine`'s shared task;
    /// calling on every press is safe and free when warm.
    ///
    /// There used to be a memory-pressure tier in this condition, deciding
    /// whether waking was polite right now. It is gone with the rest of the
    /// pressure machinery: reloading costs 0.29 s and 740 MB, which is not a
    /// decision worth negotiating with the OS about.
    func rewarmEngineIfCold(trigger: RewarmTrigger) {
        guard transcriber != nil,
              !isRecyclingEngine,
              !isEngineReady,
              hasEngineBeenReady,
              !isPreparingEngine,
              modelState.isReady
        else { return }
        engineLog.info(
            "engine rewarm trigger=\(trigger.rawValue, privacy: .public)"
        )
        shouldStayUnloadedUntilUse = false
        Task { [weak self] in await self?.warmUpEngine() }
    }

    /// Reload the recognition engine after a wedged transcription.
    ///
    /// The stall means a CoreML session stuck on a system service that died
    /// under it (observed after sleep and after coreaudiod restarts). The
    /// files on disk are fine; only the loaded session is poisoned. Unload
    /// and warm up again: the next dictation runs on a fresh session instead
    /// of the same stuck one, and the existing preparation UI narrates the
    /// warm-up honestly.
    private func recycleWedgedEngine() {
        guard !isRecyclingEngine, let transcriber else { return }
        engineLog.warning("engine recycle: wedged (deadline or ping failure)")
        isRecyclingEngine = true
        isEngineReady = false
        Task { [weak self] in
            // In-process now, so nothing else is going to reclaim this engine:
            // the unload here is the recovery. It used to be conditional
            // because a worker process fenced and replaced its own generation.
            await transcriber.unload()
            guard let self else { return }
            await self.warmUpEngine()
            self.isRecyclingEngine = false
        }
    }

    /// First inference after wake, taken out of the person's way.
    ///
    /// Sleep is where the engine's system services die (observed: coreaudiod
    /// restarts, an XPC connection interrupted mid-prediction). Without this,
    /// the first dictation of the morning pays the reconnect — the two dead
    /// sessions in the field log both sat right after an idle gap. The ping
    /// forces the reconnect now, while nobody is waiting; if even that hangs,
    /// the engine is wedged and gets recycled here rather than during
    /// someone's sentence. The engine's own input minimum is 300 ms — the
    /// one-second buffer is deliberately above it.
    private func revalidateEngineAfterWake() {
        guard transcriber != nil, isEngineReady, dictationState == .idle,
              !isRecyclingEngine
        else { return }
        pingEngine(deadline: .seconds(10))
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
    /// window - and the kernel ignores such a request. A message saying the recording was
    /// queued for deletion would then say the exact opposite of what a person sees a moment later in
    /// his document, and would also erase the real warning about the insertion from the
    /// screen. Escape at this moment does nothing, and it is right that it says nothing:
    /// the text is already in place, and there is nothing to report about it.
    public func cancelCurrentDictation() {
        guard !isRecoveryOperationActive,
              DictationStopPolicy.canCancel(state: dictationState)
        else { return }
        controller?.cancel()
        notify(
            DictationNotice(
                kind: .info,
                message: "Dictation cancelled. Its local recording is queued for deletion."
            )
        )
    }

    private func wireHotkey() {
        hotkeyMonitor.setHotkey(hotkey)
        copyShortcutMonitor?.onPress = { [weak self] in
            self?.copyLastDictation()
        }
        hotkeyMonitor.onPress = { [weak self] in
            guard let self else { return }
            // Before any guard can swallow the press: the reload must start
            // at the earliest observable moment of intent.
            self.rewarmEngineIfCold(trigger: .keyDown)
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
            isEngineReady: isEngineReady,
            engineWasReadyBefore: hasEngineBeenReady
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
        applyPermissionSnapshot(
            accessibility: permissions.accessibilityGranted,
            microphone: permissions.microphoneGranted
        )
    }

    /// The timer path of `refreshPermissions`: the TCC reads happen off the
    /// main thread. Both are synchronous IPC to system daemons; polled once a
    /// second on the main thread they were a standing invitation for a frozen
    /// interface the moment a daemon answered slowly under load — observed as
    /// a stuck "Transcribing…" panel while the engine was busy.
    /// The one thread allowed to wait on the permission daemon.
    ///
    /// Reading these is a synchronous IPC round trip to `tccd`, and it used to
    /// run in `Task.detached` — on Swift's cooperative pool, which has one
    /// thread per core and must never be blocked. Once a second, forever, this
    /// app parked a pool thread on another process answering.
    ///
    /// Field logs show what that costs when the daemon is slow: probes stop
    /// arriving for seconds and then land in a single burst, one per elapsed
    /// second, because the work was queued the whole time rather than run. The
    /// same burst brackets the recognition stalls — anything else suspended on
    /// that pool was waiting behind these.
    private static let permissionQueue = DispatchQueue(
        label: "is.waiwai.dictation.permission-poll",
        qos: .utility
    )

    private func pollPermissions() {
        let reader = permissions
        Self.permissionQueue.async { [weak self] in
            let accessibility = reader.accessibilityGranted
            let microphone = reader.microphoneGranted
            Task { @MainActor in
                self?.applyPermissionSnapshot(
                    accessibility: accessibility,
                    microphone: microphone
                )
            }
        }
    }

    private func applyPermissionSnapshot(accessibility: Bool, microphone: Bool) {
        let previousAccessibility = accessibilityGranted
        let previousMicrophone = microphoneGranted

        // Check for changes: the interface is subscribed to these fields, and here
        // come both on a timer and with each opening of the settings.
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if microphone != microphoneGranted { microphoneGranted = microphone }

        if accessibility {
            // Assignments are guarded: `@Published` does not deduplicate, and
            // an unconditional write here re-rendered the whole menu bar scene
            // on every poll tick — a permanent one-hertz UI heartbeat at rest.
            if accessibilityState != .granted { accessibilityState = .granted }
            if defaults.bool(forKey: Self.accessibilityRelaunchPendingKey) {
                defaults.removeObject(forKey: Self.accessibilityRelaunchPendingKey)
            }
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
            // First launch already presents the setup window. A status-bar HUD on
            // top of it duplicates the same work and competes for attention.
            if defaults.bool(forKey: "onboardingCompleted"), !accessibility || !microphone {
                let missingAccess: String
                switch (microphone, accessibility) {
                case (false, false): missingAccess = "Microphone and Accessibility access"
                case (false, true): missingAccess = "Microphone access"
                case (true, false): missingAccess = "Accessibility access"
                case (true, true): return
                }
                notify(
                    DictationNotice(
                        kind: .warning,
                        message: "Dictation is off: grant \(missingAccess) in System Settings."
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
            applyCopyShortcut()
        } else {
            hotkeyMonitor.stop()
            copyShortcutMonitor?.stop()
        }

        reschedulePermissionPolling()
    }

    /// Select the polling frequency to match the current state of affairs.
    ///
    /// Polling deliberately continues even when everything is granted — see
    /// `PermissionPollPolicy`: revocation sends no reliable event, and an app
    /// with revoked Accessibility looks intact while silently not working.
    /// The price is kept honest instead: each tick reads TCC off the main
    /// thread and writes no published state unless something changed.
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
            Task { @MainActor in self?.pollPermissions() }
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
        var refreshed = mainState
        // Inspection of the disk does not see a Core ML failure: the files are intact, but the model has not risen.
        // Until the person explicitly requests restoration, the refusal remains on the screen -
        // otherwise the recovery button disappears and dictation still doesn't work.
        //
        // Decided before publishing, not after: readiness is what starts a
        // preparation, so a "ready" the app is about to take back would start
        // one that instantly finds nothing to do.
        if let engineLoadFailure, refreshed.isReady {
            refreshed = .repairRequired(engineLoadFailure)
        }
        modelState = refreshed
        publishRemainingDownload(main: mainState)
        if transcriber == nil {
            isEngineReady = modelState.isReady
        } else if !modelState.isReady {
            isEngineReady = false
        }
    }

    /// Publish what the download button would fetch if it were pressed now.
    ///
    /// Recomputed wherever the answer can have changed, and from one place, so
    /// the two facts it depends on — what the disk holds and whether the engine
    /// has rejected an intact copy — cannot be consulted by half the screens.
    private func publishRemainingDownload(main: ModelState) {
        // Anything but a ready model on disk means the whole model is still to
        // fetch; an engine that rejected verified files means fetching it
        // again. There used to be a second model here, and a type whose only
        // job was to reconcile the two into one progress bar.
        let outstanding = !main.isReady || engineLoadFailure != nil
        let bytes = outstanding ? mainModelBytes : 0
        remainingDownloadMegabytes = Int((bytes + 500_000) / 1_000_000)
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
            let mainLatest = await store.refreshState()

            if !mainLatest.isReady || engineRejectedModels {
                let states = await store.states()
                let monitor = Task { @MainActor in
                    for await state in states { modelState = state }
                }
                if mainLatest.isReady || mainLatest.requiresRepair {
                    await store.repair()
                } else {
                    await store.install()
                }
                monitor.cancel()
            }

            // Preserve the stores' terminal states. Scanning the install directory after
            // a failure finds no ready marker and used to erase the detailed error with
            // `.notInstalled` before the user could read it or press Retry.
            let finalMain = await store.currentState()
            modelState = finalMain
            publishRemainingDownload(main: finalMain)
            isInstalling = false

            // The first load compiles the model for this Mac and takes tens of
            // seconds. It starts here so that nobody pays for it under their
            // first dictation.
            //
            // Launch gave up its explicit warm-up because readiness alone starts
            // one; an install cannot, because the standing rule stands down
            // while `isInstalling` holds — the readiness published a few lines
            // above therefore started nothing. `isInstalling` has just been
            // cleared, so this is the first instant the rule can speak, and it
            // speaks in both forms: the load itself, and then the rule, for the
            // case where that load only joined an attempt already in flight and
            // so scheduled no retry ladder of its own.
            if modelState.isReady { await warmUpEngine() }
            prepareEngineIfIdleAndCold()
        }
    }

    public func cancelModelInstall() {
        guard isInstalling else { return }
        Task {
            await store?.cancelInstall()
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

        // Deletion is an ownership boundary, not another model lifecycle event.
        // Revoke every AppState task before asking the recognizer to unload so a
        // cancellation-deaf continuation cannot publish Ready or queue a retry
        // after the files have gone away. The process-backed recognizer also
        // serializes unload against its active request and fences queued calls.
        modelState = .deleting
        isEngineReady = false
        engineLoadFailure = nil
        engineWarmupTaskRevision &+= 1
        engineWarmupTask?.cancel()
        engineWarmupTask = nil
        engineWarmupRetryRevision &+= 1
        engineWarmupRetryTask?.cancel()
        engineWarmupRetryTask = nil
        // A revoked preparation has nobody left to put its indicator down. The
        // ladder lowers it when it finishes, but only for the revision it still
        // owns, and the revision bump above has just taken that revision away —
        // so a ladder cancelled mid-wait woke up belonging to nobody and left
        // the app saying it was preparing a model that no longer exists. It
        // said so for the rest of the run, and while it did, the standing rule
        // was disabled: `prepareEngineIfIdleAndCold` will not start a
        // preparation while the app believes one is already running. Deletion
        // is where the revoking happens, so deletion is where it is undone.
        isPreparingEngine = false
        endPreparationCountdown()
        Task {
            await transcriber?.unload()
            await store.delete()
            await refreshModelState()
        }
    }

    private enum EngineWarmupOutcome: Sendable {
        case ready
        case skipped
        case retryable(String)
        case repairRequired(String)
    }

    /// Does one attempt's outcome leave the app still owing a ready engine?
    ///
    /// Two places read an outcome — the first attempt and the retry ladder —
    /// and this is the only sentence either of them is allowed to read it by.
    /// They used to answer it separately, and they answered `.skipped`
    /// differently: 0.8.2 taught the first attempt that "nothing happened" is
    /// one moment's answer, and left the ladder treating it as the world's. A
    /// single cancelled load inside the ladder therefore ended preparation for
    /// good, on the one engine nothing else can rescue — an engine that has
    /// never been ready is not woken by a key press, has no residency comeback
    /// to wait for, and is reloaded only when readiness changes, which it does
    /// not, because the model has been ready the whole time. That is ⌘Q as the
    /// only way out, which is the defect this branch exists to remove.
    ///
    /// With one sentence there is no second opinion left to drift.
    private func preparationContinues(after outcome: EngineWarmupOutcome) -> Bool {
        switch outcome {
        case .ready:
            // The engine is loaded. Nothing is owed.
            return false
        case .repairRequired:
            // The files are the problem, and only the person can answer for
            // them. The card says so and offers the button.
            return false
        case .retryable:
            // A dead pipe, a worker watchdog, a Mac momentarily busy with the
            // 586 MB it just wrote. The files are fine; wait longer and retry.
            return true
        case .skipped:
            // Nothing happened: a cancelled request, a fenced generation, a
            // guard that was briefly false. Whether that is the end depends on
            // one thing only — whether the app still wants a ready engine.
            return wantsEngineReady
        }
    }

    /// Prepare one fully warm generation. Calls from launch, wake, pressure
    /// recovery and a key-down are coalesced here so only the owner updates the
    /// UI and decides whether a failure means "retry worker" or "repair files".
    @discardableResult
    private func warmUpEngine(
        allowAutomaticRetry: Bool = true
    ) async -> EngineWarmupOutcome {
        if let engineWarmupTask {
            return await engineWarmupTask.value
        }

        engineWarmupTaskRevision &+= 1
        let revision = engineWarmupTaskRevision
        let task = Task { @MainActor [weak self] in
            guard let self else { return EngineWarmupOutcome.skipped }
            return await self.performEngineWarmup()
        }
        engineWarmupTask = task
        let outcome = await task.value
        if engineWarmupTaskRevision == revision {
            engineWarmupTask = nil
        }

        if allowAutomaticRetry, preparationContinues(after: outcome) {
            if case let .retryable(detail) = outcome {
                scheduleEngineWarmupRetry(after: detail)
            } else {
                scheduleEngineWarmupRetry(after: "preparation did not start")
            }
        }
        return outcome
    }

    private func performEngineWarmup() async -> EngineWarmupOutcome {
        // One source of truth. `modelState` is computed from the stores, so
        // asking a store again only introduces a second opinion that can
        // disagree for an instant — and that instant used to be terminal: the
        // disagreement returned "nothing to do", which schedules no retry, so
        // a fresh install could sit on a promise nobody was keeping. If the
        // files really are not usable, `prepare` says so and that failure is
        // retried like any other.
        guard let transcriber else { return .skipped }
        guard modelState.isReady else { return .skipped }
        isEngineReady = false
        isPreparingEngine = true
        // The retry loop owns one continuous countdown across its waits; a
        // lone attempt owns its own. Whoever owns it also ends it, so the
        // indicator never blinks between two attempts of the same preparation.
        if engineWarmupRetryTask == nil {
            beginPreparationCountdown(phase: .loadingRecognizer)
        }
        defer {
            if engineWarmupRetryTask == nil {
                isPreparingEngine = false
                endPreparationCountdown()
            }
        }

        do {
            let clock = ContinuousClock()
            let preparationStart = clock.now
            let manifest = try ModelManifest.bundled()
            let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
            try await transcriber.prepare(modelDirectory: layout.engineDirectory)
            try Task.checkCancellation()
            engineLog.info(
                "engine prepared in \(preparationStart.duration(to: clock.now).appSeconds, format: .fixed(precision: 2))s"
            )
            try Task.checkCancellation()
            setPreparationPhase(.warmingUp)
            let inferenceStart = clock.now
            try await transcriber.warmUpInference()
            try Task.checkCancellation()
            engineLog.info(
                "engine inference warmed in \(inferenceStart.duration(to: clock.now).appSeconds, format: .fixed(precision: 2))s"
            )
            isEngineReady = true
            engineLoadFailure = nil
            engineWarmupRetryRevision &+= 1
            engineWarmupRetryTask?.cancel()
            engineWarmupRetryTask = nil
            rescheduleIdleUnload()
            return .ready
        } catch is CancellationError {
            return .skipped
        } catch {
            if let reason = verifiedModelRejection(from: error) {
                let detail =
                    "the files passed verification, but Core ML couldn't load the model: \(reason)"
                // Both stores said the files are there — the guard at the top of
                // this function is that very statement, and it is what makes
                // this a rejection rather than a missing model. The repair
                // redownloads them anyway, so the volume has to be republished
                // right here: without it the only control on the setup screen
                // read "Redownload Model — 0 MB".
                let filesOnDisk = modelState
                engineLoadFailure = detail
                modelState = .repairRequired(detail)
                publishRemainingDownload(main: filesOnDisk)
                engineWarmupRetryRevision &+= 1
                engineWarmupRetryTask?.cancel()
                engineWarmupRetryTask = nil
                notify(
                    DictationNotice(
                        kind: .failure,
                        message: "The model didn't load. An explicit repair will redownload "
                            + "\(remainingDownloadMegabytes) MB."
                    )
                )
                return .repairRequired(detail)
            }

            // A dead pipe, worker watchdog, cancellation, launch failure or
            // protocol fence says nothing about the verified files on disk.
            // Keep them and recover the process generation in the background.
            let detail = error.localizedDescription
            engineLoadFailure = nil
            engineLog.error(
                "engine warm-up failed without model rejection: \(detail, privacy: .public)"
            )
            return .retryable(detail)
        }
    }

    private func verifiedModelRejection(from error: any Error) -> String? {
        guard let engineError = error as? ASREngineError else { return nil }
        guard case let .modelsUnavailable(reason) = engineError else { return nil }
        return reason
    }

    /// Keep preparing until it works. There is nothing else to do.
    ///
    /// The files are verified; only the worker generation failed, and the
    /// commonest reason is a Mac momentarily busy with the 586 MB it just
    /// wrote. A budget of attempts turned that into a permanent "give up"
    /// state with a button, on the very first run — the app now simply waits
    /// longer between attempts and stays honestly "preparing" throughout, so
    /// the interface never has to ask a person to retry work it can do itself.
    /// One task at a time, fenced by revision, cancelled by unload and delete.
    private func scheduleEngineWarmupRetry(after initialDetail: String) {
        guard engineWarmupRetryTask == nil, modelState.isReady else { return }

        engineWarmupRetryRevision &+= 1
        let revision = engineWarmupRetryRevision
        engineLog.info(
            "engine rewarm scheduled: \(initialDetail, privacy: .public)"
        )
        // The countdown keeps running across the waits: the person sees one
        // continuous "preparing", which is exactly what is happening.
        isPreparingEngine = true
        beginPreparationCountdown(phase: .loadingRecognizer)
        engineWarmupRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var failures = 0
            while true {
                // Re-assert after each attempt: the attempt's own bookkeeping
                // runs while this loop is still going to try again.
                self.isPreparingEngine = true
                do {
                    try await Task.sleep(
                        for: self.engineWarmupRetryDelay(afterFailures: failures)
                    )
                } catch {
                    self.finishRetryPresentation(revision: revision)
                    return
                }
                guard self.engineWarmupRetryRevision == revision,
                      self.modelState.isReady
                else {
                    self.finishRetryPresentation(revision: revision)
                    return
                }

                let outcome = await self.warmUpEngine(allowAutomaticRetry: false)
                guard self.preparationContinues(after: outcome) else {
                    self.finishRetryPresentation(revision: revision)
                    return
                }
                failures += 1
            }
        }
    }

    private func engineWarmupRetryDelay(afterFailures failures: Int) -> Duration {
        engineWarmupRetryDelayOverride
            ?? EngineWarmupBackoff.delay(afterFailures: failures)
    }

    /// Hand the preparation indicator back once the loop is done owning it.
    ///
    /// A revoked ladder arrives here with a stale revision by definition — that
    /// is what revoking means — so refusing it outright left the indicator lit
    /// with nobody behind it. Deleting the model mid-wait did exactly that: the
    /// app went on narrating a preparation of files that no longer existed, and
    /// because `prepareEngineIfIdleAndCold` stands down while a preparation
    /// looks live, the next installed model could never start one.
    ///
    /// Only a live successor may keep the indicator, and a successor is exactly
    /// what `engineWarmupRetryTask` being non-nil means: every revocation site
    /// clears it, so a stale revision with nothing in that slot is a ladder that
    /// left without an heir.
    private func finishRetryPresentation(revision: Int) {
        guard engineWarmupRetryRevision == revision || engineWarmupRetryTask == nil
        else { return }
        engineWarmupRetryTask = nil
        isPreparingEngine = false
        endPreparationCountdown()
    }

    // MARK: - Duration limit

    // MARK: - Recording feedback

    /// Peak level from the microphone — feeds the waveform in the panel.
    ///
    /// There is deliberately no "no sound detected" watcher here: pausing to
    /// think before a phrase is normal speech, not an error, and a hint built
    /// on a two-second timer fired on every such pause. A dead input is still
    /// honestly visible — by the flat waveform during recording and by the
    /// final "Nothing was recognized" at the end.
    private func registerInputLevel(_ peak: Float) {
        (overlay as? RecordingFeedbackPresenting)?.updateInputLevel(peak)
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
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual {
                isReconcilingLaunchAtLogin = true
                launchAtLogin = actual
                isReconcilingLaunchAtLogin = false
            }
            notify(
                DictationNotice(
                    kind: .warning,
                    message: "Could not update the login item: \(error.localizedDescription)"
                )
            )
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
    private func makePipeline() -> any TextProcessing {
        // Safe built-in technical vocabulary is part of recognition, not a
        // hidden setup chore. Personal entries win when they use the same
        // heard spelling.
        //
        // Run by the shared core, so an improvement to these rules reaches
        // every platform rather than this one. `DictationCore.TextPipeline`
        // remains the specification the conformance fixtures record, and
        // `SharedCorePipelineTests` compares the two on every case in that
        // corpus.
        TrailingSpacePipeline(
            wrapped: SharedCorePipeline(
                replacements: StarterDictionary.missing(from: replacements) + replacements
            ),
            appendsSpace: appendsTrailingSpace
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

    /// The dictionary as a portable file — personal terms are the one piece
    /// of dictation state worth carrying to another Mac.
    public func exportedDictionary() throws -> Data {
        try DictionaryTransfer.export(replacements)
    }

    /// Merge a dictionary file into the current replacements.
    ///
    /// Imports never destroy: existing entries are edited in place when the
    /// file knows the same spoken phrase, everything else is appended. The
    /// outcome is always named — including "nothing changed".
    public func importDictionary(from data: Data) {
        guard dictionaryProblem == nil else {
            notify(DictationNotice(kind: .warning, message: dictionaryProblem?.message ?? ""))
            return
        }
        let merged: DictionaryTransfer.MergeResult
        do {
            merged = DictionaryTransfer.merge(
                existing: replacements,
                imported: try DictionaryTransfer.read(data)
            )
        } catch {
            notify(
                DictationNotice(
                    kind: .failure,
                    message: (error as? LocalizedError)?.errorDescription
                        ?? "The dictionary file couldn't be read."
                )
            )
            return
        }
        guard merged.added > 0 || merged.updated > 0 else {
            notify(
                DictationNotice(
                    kind: .info,
                    message: "Nothing to import — every phrase in the file is already in the dictionary."
                )
            )
            return
        }
        updateReplacements(merged.replacements)
        // updateReplacements reports its own save failure and leaves the list
        // untouched; announce success only when the merge actually landed.
        guard replacements == merged.replacements else { return }
        notify(
            DictationNotice(
                kind: .info,
                message: importSummary(added: merged.added, updated: merged.updated)
            )
        )
    }

    /// The file dialogs live in the view; their failures surface through the
    /// same channel as every other notice.
    public func reportDictionaryFileProblem(_ message: String) {
        notify(DictationNotice(kind: .failure, message: message))
    }

    private func importSummary(added: Int, updated: Int) -> String {
        let phrases = { (count: Int) in count == 1 ? "1 phrase" : "\(count) phrases" }
        switch (added > 0, updated > 0) {
        case (true, true):
            return "Imported \(phrases(added)), updated \(phrases(updated))."
        case (true, false):
            return "Imported \(phrases(added))."
        case (false, true):
            return "Updated \(phrases(updated)) from the file."
        case (false, false):
            return "Nothing to import."
        }
    }

    public func removeReplacements(at offsets: IndexSet) {
        var updated = replacements
        updated.remove(atOffsets: offsets)
        updateReplacements(updated)
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
            return
        }

        notify(DictationNotice(kind: .warning, message: problem.message))
    }
}

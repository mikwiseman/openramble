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
    /// A third watcher, for the shortcut that starts and stops a recording.
    public var recordingShortcutMonitor: (any ShortcutMonitoring)?
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
    /// Recognition factory: give it the engine folder, get back the call that
    /// recognizes one recording.
    public var transcribe: (URL) -> @Sendable (URL) async throws -> ASRResult
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
    /// How to record a long take — a meeting or a voice note — into a
    /// directory: given the directory, the preferred microphone, a level
    /// callback for the meters and a failure callback.
    public typealias MeetingCaptureFactory = (
        URL,
        AudioDeviceID?,
        Bool,
        @escaping @Sendable (MeetingCapture.Levels) -> Void,
        @escaping @Sendable (MeetingSegmentRef) -> Void,
        @escaping @Sendable (MeetingCapture.Failure) -> Void
    ) -> any MeetingCapturing
    public var makeMeetingCapture: MeetingCaptureFactory
    /// Spoken state changes the person cannot see — a meter that stopped.
    public var announcer: any AccessibilityAnnouncing
    public var openSystemAudioSettings: @MainActor () -> Void
    /// The inaudible tone that asks whether the other side can be heard.
    /// Played again every ten seconds while the answer is no, so a
    /// permission granted a moment after the first ask is noticed without
    /// waiting for someone on the call to speak.
    public var playSystemAudioProbe: @Sendable () -> Void

    /// The other side of the call, where this macOS can record it.
    public static func makeSystemAudioSource() -> (any MeetingAudioSource)? {
        if #available(macOS 14.2, *) { return SystemAudioTapSource() }
        return nil
    }
    /// Deleting a recording is a move to the Trash. Injectable so a test
    /// removes its fixtures instead of filling the developer's Trash.
    public var trashItem: @Sendable (URL) throws -> Void
    /// Shared with the worker supervisor so its off-main recovery loop can
    /// read the pressure tier without hopping through AppState.

    public init(
        defaults: UserDefaults,
        paths: AppPaths,
        permissions: any PermissionReading,
        accessibilityManager: any AccessibilityManaging,
        hotkeyMonitor: any HotkeyMonitoring,
        copyShortcutMonitor: (any ShortcutMonitoring)? = nil,
        recordingShortcutMonitor: (any ShortcutMonitoring)? = nil,
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
        transcribe: @escaping (URL) -> @Sendable (URL) async throws -> ASRResult,
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
        makeMeetingCapture: @escaping MeetingCaptureFactory = { directory, device, includeSystemAudio, onLevels, onSegment, onFailure in
            MeetingCapture(
                directory: directory,
                microphone: MicrophoneAudioSource(preferredInputDeviceID: device),
                systemAudio: includeSystemAudio ? AppEnvironment.makeSystemAudioSource() : nil,
                onLevels: onLevels,
                onSegment: onSegment,
                onFailure: onFailure
            )
        },
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer(),
        openSystemAudioSettings: @escaping @MainActor () -> Void = { Permissions.openSystemAudioSettings() },
        playSystemAudioProbe: @escaping @Sendable () -> Void = SystemAudioProbe.play,
        trashItem: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        },
    ) {
        self.defaults = defaults
        self.paths = paths
        self.permissions = permissions
        self.accessibilityManager = accessibilityManager
        self.hotkeyMonitor = hotkeyMonitor
        self.copyShortcutMonitor = copyShortcutMonitor
        self.recordingShortcutMonitor = recordingShortcutMonitor
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
        self.makeMeetingCapture = makeMeetingCapture
        self.trashItem = trashItem
        self.announcer = announcer
        self.openSystemAudioSettings = openSystemAudioSettings
        self.playSystemAudioProbe = playSystemAudioProbe
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
            recordingShortcutMonitor: GlobalShortcutMonitor(),
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
            transcribe: { engineDirectory in
                return { url in
                    // Measured, because this is the last span on the dictation
                    // path that nothing timed. `prepare` runs before every
                    // single recognition, and the `prepare` already in the
                    // speed line is a different call on a different path — so
                    // this one could take seconds while that one read 0.00.
                    let readyAt = ContinuousClock.now
                    try await transcriber.prepare(modelDirectory: engineDirectory)
                    let prepared = readyAt.duration(to: .now)
                    let result = try await transcriber.transcribe(fileURL: url)
                    return ASRResult(
                        text: result.text,
                        words: result.words,
                        audioDuration: result.audioDuration,
                        processingDuration: result.processingDuration,
                        engineDispatchDuration: result.engineDispatchDuration,
                        queueingDuration: result.queueingDuration
                            + Double(prepared.components.seconds)
                            + Double(prepared.components.attoseconds) / 1e18,
                        decodingDuration: result.decodingDuration,
                        phaseTimings: result.phaseTimings
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
        didSet {
            if isEngineReady { hasEngineBeenReady = true }
            let arbiter = engineArbiter
            let ready = isEngineReady
            Task { await arbiter.setEngineReady(ready) }
        }
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
    /// One re-run at a time: the engine takes one call, and a queue of them
    /// would be a queue nobody asked for.
    @Published public private(set) var isRetranscribing = false
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

    // MARK: - Recordings

    /// What the recorder is doing. Orthogonal to `dictationState`: a person
    /// can dictate into Slack while a meeting records, and both are true.
    public enum MeetingState: Equatable {
        case idle
        case starting
        case recording
        case paused
        case stopping
    }
    @Published public private(set) var meetingState: MeetingState = .idle
    /// Every finished recording, newest first.
    @Published public private(set) var recordings: [MeetingRecordingMetadata] = []
    /// The recording in progress, once it has actually started.
    @Published public private(set) var liveRecording: MeetingRecordingMetadata?
    /// Seconds on disk so far, refreshed once a second while recording.
    @Published public private(set) var liveDuration: TimeInterval = 0
    /// The loudest sample per channel over the last stretch, for the meters.
    @Published public private(set) var liveLevels = MeetingCapture.Levels.silent
    /// What the recordings occupy on disk.
    @Published public private(set) var recordingsBytes: Int64 = 0
    /// The recording that most recently ended — the window selects it.
    @Published public private(set) var lastFinishedRecordingID: UUID?
    private var meetingStore: MeetingStore?
    private var meetingCapture: (any MeetingCapturing)?
    private var liveDurationTimer: Timer?
    /// ⌘Q is waiting for the recording to end before the app may quit.
    private var terminationPending = false

    /// The transcript of the recording being made — or of the one that just
    /// ended and is still being decoded — with the paragraph in progress last.
    @Published public private(set) var liveTranscript: [MeetingUtterance] = []
    /// How far an m4a export has got, or nothing when none is running.
    /// One at a time: the encoder is the slow part and two would race.
    @Published public private(set) var audioExportProgress: Double?
    private let audioExportCancelled = UncheckedBox<Bool>(false)
    /// Seconds of speech waiting for the engine. Measured from what was
    /// submitted and what came back, never modelled.
    @Published public private(set) var transcriptBacklogSeconds: TimeInterval = 0
    /// The queue stopped itself after repeated failures. The audio is safe.
    @Published public private(set) var isTranscriptionPaused = false
    /// Transcripts read from disk for the detail pane, by recording.
    @Published public private(set) var loadedTranscripts: [UUID: [MeetingUtterance]] = [:]
    /// Which recording `liveTranscript` belongs to.
    @Published public private(set) var transcribingRecordingID: UUID?
    /// Dictation always wins the engine; meeting decodes wait their turn.
    private let engineArbiter = EngineArbiter()
    private var transcriptionQueue: MeetingTranscriptionQueue?
    private var utteranceAssembler = MeetingUtteranceAssembler()
    private var closedUtterances: [MeetingUtterance] = []
    private var transcriptWriteFailureReported = false

    // MARK: - The other side

    /// Whether the record button captures what the Mac plays.
    public enum SystemAudioMode: Equatable {
        case unsupported
        case declined
        case enabled
    }
    public static let systemAudioDeclinedKey = "systemAudioDeclined"
    public static let systemAudioIntroShownKey = "systemAudioIntroShown"
    /// What the last recording found: "working" or "unheard".
    public static let systemAudioLastResultKey = "systemAudioLastResult"

    public var systemAudioMode: SystemAudioMode {
        guard SystemAudioAvailability.isSupported else { return .unsupported }
        return defaults.bool(forKey: Self.systemAudioDeclinedKey) ? .declined : .enabled
    }
    /// The one-time explanation before the first recording of the other side.
    @Published public private(set) var isSystemAudioIntroPresented = false
    /// Whether the other side is actually arriving, refreshed once a second.
    @Published private(set) var liveCaptureHealth: CaptureHealth = .notRequested
    /// For the Settings row: what the app knows, never a guess.
    @Published private(set) var systemAudioPermission: SystemAudioPermissionMode = .notChecked
    private var systemAudioStartFailure: String?
    private var liveRecordingStartedAt: ContinuousClock.Instant?
    private var lastAnnouncedHealth: String?

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

    /// Finish a hands-free dictation when the talking stops.
    ///
    /// Hands-free only, and that is the whole design. While the key is held the
    /// person is holding it — they are saying with their hand that they have
    /// not finished, and a pause for thought is not an ending. Cutting a
    /// sentence off under a held key is what makes voice input feel hostile.
    @Published public var stopsOnSilence: Bool {
        didSet {
            guard oldValue != stopsOnSilence else { return }
            defaults.set(stopsOnSilence, forKey: Keys.stopsOnSilence)
        }
    }

    /// Tracks the quiet. Reset per take, never shared between them.
    private var silence = SilencePolicy()

    /// Keep the engine's own notes, not just the per-dictation numbers.
    ///
    /// Off by default, and what it changes is narrow: the engine already
    /// writes notes about loading, unloading and warming, but at `info` level,
    /// which macOS discards unless someone passes `--info` to `log show`. On,
    /// they are written at `notice` and survive — so a slow dictation can be
    /// explained after the fact rather than only while someone is watching.
    ///
    /// It does not turn on any new measurement. Every stage of every dictation
    /// is already timed and logged, because a number that only exists when a
    /// setting is on is a number missing from the report you actually need.
    /// And nothing here ever carries a word of what was said.
    @Published public var detailedLogging: Bool {
        didSet {
            guard oldValue != detailedLogging else { return }
            defaults.set(detailedLogging, forKey: Keys.detailedLogging)
            EngineNotes.isDetailed = detailedLogging
            DictationLogFile.shared.isEnabled = detailedLogging
        }
    }

    /// Where the app shows itself. Never nowhere — see `AppPresence`.
    @Published public var presence: AppPresence {
        didSet {
            guard oldValue != presence else { return }
            defaults.set(presence.rawValue, forKey: Keys.presence)
            Self.applyDockPresence(presence)
        }
    }

    /// The Dock icon follows the choice; the menu bar icon follows it in the
    /// view. `WindowFronting` may still raise the app to `.regular` while a
    /// window is open, and puts it back to whatever this says afterwards.
    static func applyDockPresence(_ presence: AppPresence) {
        NSApp?.setActivationPolicy(presence.showsDockIcon ? .regular : .accessory)
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

    /// The shortcut that starts and stops a recording, or nothing.
    ///
    /// Default is ⇧⌘R. Clearing it is Off — an empty defaults value, not a
    /// missing one, so the first launch and a deliberate clear stay different.
    @Published public var recordingShortcut: KeyCombination? {
        didSet {
            guard oldValue != recordingShortcut else { return }
            defaults.set(recordingShortcut?.rawValue ?? "", forKey: Keys.recordingShortcut)
            applyRecordingShortcut()
        }
    }

    /// Point the second watcher at the chosen shortcut, or take it off the
    /// keyboard.
    private func applyCopyShortcut() {
        applyShortcutMonitor(copyShortcutMonitor, shortcut: copyShortcut)
    }

    private func applyRecordingShortcut() {
        applyShortcutMonitor(recordingShortcutMonitor, shortcut: recordingShortcut)
    }

    private func applyShortcutMonitor(
        _ monitor: (any ShortcutMonitoring)?,
        shortcut: KeyCombination?
    ) {
        guard let monitor else { return }
        monitor.setShortcut(shortcut)
        guard shortcut != nil else { return }
        // Only once dictation itself is running: before that the app has no
        // Accessibility permission and starting would fail silently.
        if hotkeyMonitor.isRunning, !monitor.isRunning {
            monitor.start()
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
        static let recordingShortcut = "recordingShortcut"
        static let trailingSpace = "appendsTrailingSpace"
        static let appearance = "appearance"
        static let inputDevice = "inputDeviceUID"
        static let presence = "presence"
        static let detailedLogging = "detailedLogging"
        static let stopsOnSilence = "stopsOnSilence"
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
    /// Keeps one level update in flight at a time. See `LevelUpdateGate`.
    private let levelGate = LevelUpdateGate()
    private let hotkeyMonitor: any HotkeyMonitoring
    private let copyShortcutMonitor: (any ShortcutMonitoring)?
    private let recordingShortcutMonitor: (any ShortcutMonitoring)?
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
    private let transcribe: (URL) -> @Sendable (URL) async throws -> ASRResult
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
    private let makeMeetingCapture: AppEnvironment.MeetingCaptureFactory
    private let trashItem: @Sendable (URL) throws -> Void
    private let announcer: any AccessibilityAnnouncing
    private let openSystemAudioSettingsPane: @MainActor () -> Void
    private let playSystemAudioProbe: @Sendable () -> Void
    private var lastProbeAt: ContinuousClock.Instant?

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
        recordingShortcutMonitor = environment.recordingShortcutMonitor
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
        makeMeetingCapture = environment.makeMeetingCapture
        trashItem = environment.trashItem
        announcer = environment.announcer
        openSystemAudioSettingsPane = environment.openSystemAudioSettings
        playSystemAudioProbe = environment.playSystemAudioProbe

        hotkey = DictationHotkey(rawValue: environment.defaults.string(forKey: Keys.hotkey) ?? "")
            ?? SettingsDefaults.hotkey
        soundsEnabled = environment.defaults.object(forKey: Keys.sounds) as? Bool ?? SettingsDefaults.soundsEnabled
        // Off unless asked for: dictated text on the clipboard is dictated text
        // handed to every clipboard manager on the machine.
        copiesToClipboard = environment.defaults.object(forKey: Keys.copyToClipboard) as? Bool
            ?? SettingsDefaults.copiesToClipboard
        copyShortcut = (environment.defaults.string(forKey: Keys.copyShortcut))
            .flatMap(KeyCombination.init(rawValue:))
        if environment.defaults.object(forKey: Keys.recordingShortcut) == nil {
            recordingShortcut = SettingsDefaults.recordingShortcut
        } else {
            recordingShortcut = (environment.defaults.string(forKey: Keys.recordingShortcut))
                .flatMap(KeyCombination.init(rawValue:))
        }
        appendsTrailingSpace = environment.defaults.object(forKey: Keys.trailingSpace) as? Bool
            ?? SettingsDefaults.appendsTrailingSpace
        appearance = AppAppearance(
            rawValue: environment.defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? SettingsDefaults.appearance
        inputDeviceUID = (environment.defaults.string(forKey: Keys.inputDevice))
            .flatMap { $0.isEmpty ? nil : $0 }
        presence = AppPresence(
            rawValue: environment.defaults.string(forKey: Keys.presence) ?? ""
        ) ?? SettingsDefaults.presence
        detailedLogging = environment.defaults.object(forKey: Keys.detailedLogging) as? Bool
            ?? SettingsDefaults.detailedLogging
        stopsOnSilence = environment.defaults.object(forKey: Keys.stopsOnSilence) as? Bool
            ?? SettingsDefaults.stopsOnSilence
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
                    // At most one hop to the main actor in flight at a time.
                    //
                    // This fired per audio frame — about twenty times a second
                    // for the whole dictation — and each one is a hop the main
                    // actor has to service. The recognition path is main-actor
                    // bound too, so the meter was competing with the dictation
                    // it was drawn for. Under load that queue is where seconds
                    // went.
                    //
                    // Dropping intermediate frames costs nothing visible: the
                    // waveform draws 24 samples and a display refresh cannot
                    // show more than it is given. The newest peak always wins,
                    // so the meter still tracks the voice rather than lagging.
                    guard self?.levelGate.take() == true else { return }
                    Task { @MainActor in
                        self?.registerInputLevel(peak)
                        self?.levelGate.release()
                    }
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

            let meetingStore = MeetingStore(root: try paths.recordings(), trasher: trashItem)
            self.meetingStore = meetingStore
            // Whatever a crash left is repaired and listed before anything
            // else is shown, and disclosed once — a recording that reappears
            // without a word would read as one the person never made.
            let recovered = meetingStore.recoverIncomplete()
            reloadRecordings()
            refreshSystemAudioPermission()
            if !recovered.isEmpty {
                notify(DictationNotice(
                    kind: .info,
                    message: recovered.count == 1
                        ? "A recording was recovered after an interruption."
                        : "\(recovered.count) recordings were recovered after an interruption."
                ))
            }

            let engineDirectory = layout.engineDirectory
            self.engineDirectory = engineDirectory
            let transcribeSamples: (@Sendable ([Float]) async throws -> ASRResult)?
            if let transcriber {
                transcribeSamples = { samples in
                    // This boundary timer deliberately surrounds the actor
                    // call. After subtracting engine work it still contains
                    // both actor admission and the return to this caller; it is
                    // useful as a total, but it cannot identify which side
                    // waited. DictationController records the two outer return
                    // hops separately before we choose a scheduling fix.
                    let handedOver = ContinuousClock.now
                    let result = try await transcriber.transcribe(samples: samples)
                    let waited = handedOver.duration(to: .now)
                    return ASRResult(
                        text: result.text,
                        words: result.words,
                        audioDuration: result.audioDuration,
                        processingDuration: result.processingDuration,
                        engineDispatchDuration: result.engineDispatchDuration,
                        queueingDuration: max(
                            0,
                            Double(waited.components.seconds)
                                + Double(waited.components.attoseconds) / 1e18
                                - result.processingDuration
                                - result.engineDispatchDuration
                        ),
                        decodingDuration: result.decodingDuration,
                        phaseTimings: result.phaseTimings
                    )
                }
            } else {
                transcribeSamples = nil
            }
            let controller = DictationController(
                capture: capture,
                transcribe: transcribe(engineDirectory),
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
                // A session that has started owns the engine until it ends;
                // a meeting decode that has not started yet waits.
                if let arbiter = self?.engineArbiter {
                    Task { await arbiter.setDictationActive(state != .idle) }
                }
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
                // `notice`, not `info`: a slow take is exactly the entry that
                // must survive in the system log long enough to be read.
                engineLog.notice("\(DictationSpeedLine.text(for: report), privacy: .public)")
                DictationLogFile.shared.write(DictationSpeedLine.text(for: report))
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

    /// Open the folder holding the audio kept alongside history.
    ///
    /// Points at a recording rather than the bare folder when there is one, so
    /// Finder opens with something selected instead of leaving the person to
    /// work out which of these files is theirs.
    public func revealHistoryAudio() {
        let target = history.compactMap(historyAudioURL(for:)).first
        guard let target else {
            notify(DictationNotice(kind: .info, message: "No recordings kept yet."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Recognise a kept recording again.
    ///
    /// Worth having after editing the dictionary: the words the model heard do
    /// not change, but what they become does, and re-running is the only way to
    /// see that without dictating the sentence a second time.
    ///
    /// The new text replaces the entry's text and nothing else. The audio stays
    /// where it is, so this can be done repeatedly, and a run that fails leaves
    /// the previous text intact rather than blanking a record of something the
    /// person actually said.
    public func retranscribeHistoryEntry(_ entry: HistoryEntry) {
        guard !isRetranscribing else { return }
        guard let audio = historyAudioURL(for: entry) else {
            notify(DictationNotice(kind: .info, message: "That dictation's audio is gone."))
            return
        }
        guard let transcriber, isEngineReady else {
            notify(DictationNotice(kind: .info, message: "The speech model isn't ready yet."))
            return
        }
        isRetranscribing = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.isRetranscribing = false } }
            do {
                let result = try await transcriber.transcribe(fileURL: audio)
                let text = self?.makePipeline().run(result.text).output.text ?? result.text
                await MainActor.run {
                    guard let self, let store = self.historyStore else { return }
                    self.history = (try? store.replaceText(text, for: entry)) ?? self.history
                }
            } catch {
                await MainActor.run {
                    self?.notify(
                        DictationNotice(
                            kind: .failure,
                            message: "Couldn't recognise that recording again."
                        )
                    )
                }
            }
        }
    }

    /// Star an entry so retention leaves it alone, or unstar it.
    public func setHistoryEntryKept(_ isKept: Bool, for entry: HistoryEntry) {
        guard let historyStore else { return }
        history = (try? historyStore.setKept(isKept, for: entry)) ?? history
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
                // and after inserting recovered words neither "Copy Last
                // Dictation" nor correction learning may act on it — one would
                // hand back someone else's text, the other would protect
                // someone else's spans.
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
        recordingShortcutMonitor?.stop()
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
              // A recording is not idleness either, and neither is a queue
              // still decoding one that just ended: unloading here would
              // reload 0.3 s later for the next segment, forever.
              meetingState == .idle,
              transcriptionQueue == nil,
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
              meetingState == .idle,
              transcriptionQueue == nil,
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
        EngineNotes.note("engine preparation resumed: ready model, cold engine, nothing running")
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
        recordingShortcutMonitor?.onPress = { [weak self] in
            self?.handleRecordingShortcut()
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

    // MARK: - Recordings

    /// The global recording shortcut: start if idle, stop if running.
    /// Pause stays a window control — a shortcut that paused would need a
    /// third press to finish, and nobody would remember which state they were in.
    private func handleRecordingShortcut() {
        switch meetingState {
        case .idle:
            startRecording()
        case .recording, .paused:
            stopRecording()
        case .starting, .stopping:
            break
        }
    }

    /// The record button. One button and no mode: it records the microphone
    /// and, where this Mac can and the person has not said otherwise, what
    /// the Mac plays. The first time that would happen, it explains itself
    /// once instead of raising a system prompt out of nowhere.
    public func startRecording() {
        switch systemAudioMode {
        case .enabled:
            guard defaults.bool(forKey: Self.systemAudioIntroShownKey) else {
                isSystemAudioIntroPresented = true
                return
            }
            startRecording(includingSystemAudio: true)
        case .declined, .unsupported:
            startRecording(includingSystemAudio: false)
        }
    }

    /// The sheet's answer.
    public func confirmSystemAudioIntro(includeSystemAudio: Bool) {
        defaults.set(true, forKey: Self.systemAudioIntroShownKey)
        if !includeSystemAudio { defaults.set(true, forKey: Self.systemAudioDeclinedKey) }
        isSystemAudioIntroPresented = false
        refreshSystemAudioPermission()
        startRecording(includingSystemAudio: includeSystemAudio)
    }

    public func dismissSystemAudioIntro() {
        isSystemAudioIntroPresented = false
    }

    /// The remembered choice behind the button. Choosing is the explanation,
    /// so the sheet does not come after it.
    public func setSystemAudioDeclined(_ declined: Bool) {
        defaults.set(declined, forKey: Self.systemAudioDeclinedKey)
        defaults.set(true, forKey: Self.systemAudioIntroShownKey)
        refreshSystemAudioPermission()
    }

    public func openSystemAudioSettings() {
        openSystemAudioSettingsPane()
    }

    /// A grant made in System Settings reaches a process only when it starts.
    public func relaunchForSystemAudio() {
        Task {
            do {
                try await accessibilityManager.relaunchApplication()
            } catch {
                notify(DictationNotice(kind: .failure, message: "Couldn't relaunch OpenRamble: \(error.localizedDescription)"))
            }
        }
    }

    /// The Settings row's one action, by what it found.
    public func performSystemAudioAction() {
        switch systemAudioPermission {
        case .declined: setSystemAudioDeclined(false)
        case .unheard: openSystemAudioSettings()
        case .unsupported, .notChecked, .working: break
        }
    }

    func refreshSystemAudioPermission() {
        switch systemAudioMode {
        case .unsupported: systemAudioPermission = .unsupported
        case .declined: systemAudioPermission = .declined
        case .enabled:
            switch defaults.string(forKey: Self.systemAudioLastResultKey) {
            case "working": systemAudioPermission = .working
            case "unheard": systemAudioPermission = .unheard
            default: systemAudioPermission = .notChecked
            }
        }
    }

    /// Start recording. Refuses nothing silently: a missing microphone
    /// permission asks for it and says so; a full disk says so; a microphone
    /// that will not start says why; a tap that will not start costs the other
    /// side and says so, never the recording.
    public func startRecording(includingSystemAudio: Bool) {
        guard meetingState == .idle, let meetingStore else { return }
        guard microphoneGranted else {
            notify(DictationNotice(kind: .warning, message: "Allow the microphone to record."))
            requestMicrophone()
            return
        }
        let metadata = MeetingRecordingMetadata(
            startedAt: Date(),
            systemAudio: SystemAudioSummary(wasRequested: includingSystemAudio),
            transcriptionState: .live
        )
        let directory = meetingStore.incompleteDirectory(for: metadata.id)
        do {
            try meetingStore.write(metadata, incomplete: true)
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't start recording: \(error.localizedDescription)"))
            return
        }
        let capture = makeMeetingCapture(
            directory,
            preferredInputDeviceID,
            includingSystemAudio,
            { [weak self] levels in
                Task { @MainActor in self?.liveLevels = levels }
            },
            { [weak self] segment in
                Task { @MainActor in self?.segmentReady(segment) }
            },
            { [weak self] failure in
                Task { @MainActor in self?.recordingFailed(failure) }
            }
        )
        meetingCapture = capture
        meetingState = .starting
        systemAudioStartFailure = nil
        lastAnnouncedHealth = nil
        lastProbeAt = .now
        liveCaptureHealth = includingSystemAudio ? .verifying : .notRequested
        beginTranscription(for: metadata.id, directory: directory)
        Task { [weak self] in
            do {
                try await capture.start()
                await MainActor.run {
                    guard let self else { return }
                    self.liveRecording = metadata
                    self.liveDuration = 0
                    self.liveRecordingStartedAt = .now
                    self.meetingState = .recording
                    self.startLiveDurationTimer()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.meetingCapture = nil
                    self.meetingState = .idle
                    self.abandonTranscription()
                    // Nothing was recorded: the directory prepared for it is
                    // not a recording anyone wants back.
                    try? FileManager.default.removeItem(at: directory)
                    self.notify(DictationNotice(kind: .failure, message: Self.recordingStartFailureMessage(error)))
                }
            }
        }
    }

    /// End the recording and file it.
    ///
    /// The metadata is written and the directory moved into the list in one
    /// go, so the list never holds a half-written entry. Whatever the recorder
    /// reports — a clean stop, a full disk, a writer that failed — the audio
    /// that reached disk is kept and the reason travels with it.
    public func stopRecording() {
        guard meetingState == .recording || meetingState == .paused,
              let capture = meetingCapture,
              let live = liveRecording,
              let meetingStore else { return }
        meetingState = .stopping
        stopLiveDurationTimer()
        Task { [weak self] in
            var metadata = live
            let engineReady = await MainActor.run { self?.isEngineReady ?? false }
            metadata.transcriptionState = engineReady ? .live : .waitingForModel
            do {
                let summary = try await capture.stop()
                metadata.duration = summary.duration
                metadata.microphoneDeviceName = summary.microphoneDeviceName
                metadata.systemAudio = summary.systemAudio
                metadata.gaps = summary.gaps
                metadata.pauses = summary.pauses
                metadata.endReason = summary.endReason
            } catch {
                metadata.endReason = .writeFailed
            }
            await MainActor.run {
                guard let self else { return }
                do {
                    try meetingStore.write(metadata, incomplete: true)
                    try meetingStore.publish(metadata.id)
                } catch {
                    self.notify(DictationNotice(
                        kind: .failure,
                        message: "The recording ended but couldn't be filed: \(error.localizedDescription)"
                    ))
                }
                self.meetingCapture = nil
                self.liveRecording = nil
                self.liveLevels = .silent
                self.liveRecordingStartedAt = nil
                self.liveCaptureHealth = .notRequested
                self.meetingState = .idle
                if metadata.systemAudio.wasRequested {
                    self.defaults.set(
                        metadata.systemAudio.everDeliveredAudio ? "working" : "unheard",
                        forKey: Self.systemAudioLastResultKey
                    )
                    self.refreshSystemAudioPermission()
                }
                self.reloadRecordings()
                self.lastFinishedRecordingID = metadata.id
                self.finishTranscription(for: metadata.id)
                if let notice = Self.endNotice(for: metadata.endReason) { self.notify(notice) }
                if self.terminationPending {
                    self.terminationPending = false
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    public func pauseRecording() {
        guard meetingState == .recording, let capture = meetingCapture else { return }
        Task { [weak self] in
            do {
                try await capture.pause()
                await MainActor.run { self?.meetingState = .paused }
            } catch {
                await MainActor.run {
                    self?.notify(DictationNotice(kind: .failure, message: "Couldn't pause the recording."))
                }
            }
        }
    }

    public func resumeRecording() {
        guard meetingState == .paused, let capture = meetingCapture else { return }
        Task { [weak self] in
            do {
                try await capture.resume()
                await MainActor.run { self?.meetingState = .recording }
            } catch {
                await MainActor.run {
                    self?.notify(DictationNotice(kind: .failure, message: Self.recordingStartFailureMessage(error)))
                }
            }
        }
    }

    /// Whether ⌘Q has to wait. A recording that is only starting or only
    /// stopping is left to the launch-time recovery: the file is on disk
    /// either way.
    public var isRecordingInProgress: Bool {
        meetingState == .recording || meetingState == .paused
    }

    /// Called by the app delegate after the person chose to stop and quit;
    /// the reply to AppKit is sent when the recording has been filed.
    public func stopRecordingBeforeTermination() {
        terminationPending = true
        stopRecording()
    }

    public func reloadRecordings() {
        guard let meetingStore else { return }
        recordings = meetingStore.list()
        recordingsBytes = meetingStore.totalBytes()
    }

    public func recordingAudioURL(_ id: UUID) -> URL? {
        meetingStore?.audioURL(for: id)
    }

    public func recordingPeaksURL(_ id: UUID) -> URL? {
        meetingStore?.peaksURL(for: id)
    }

    public func recordingBytes(_ id: UUID) -> Int64? {
        meetingStore?.bytes(for: id)
    }

    public func renameRecording(_ id: UUID, title: String?) {
        guard let meetingStore else { return }
        do {
            try meetingStore.rename(id, title: title)
            reloadRecordings()
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't rename the recording."))
        }
    }

    /// To the Trash — the person's own, where it can come back from.
    public func trashRecording(_ id: UUID) {
        guard let meetingStore else { return }
        do {
            try meetingStore.trash(id)
            reloadRecordings()
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't move the recording to the Trash."))
        }
    }

    public func revealRecording(_ id: UUID) {
        guard let meetingStore else { return }
        let target = meetingStore.audioURL(for: id) ?? meetingStore.directory(for: id)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Live transcript

    /// The transcript for a recording — live while it is being made or
    /// drained, from disk otherwise (see `loadTranscript`).
    public func transcript(for id: UUID) -> [MeetingUtterance] {
        id == transcribingRecordingID ? liveTranscript : (loadedTranscripts[id] ?? [])
    }

    public func loadTranscript(_ id: UUID) {
        guard id != transcribingRecordingID, let meetingStore else { return }
        loadedTranscripts[id] = meetingStore.transcript(for: id)?.utterances ?? []
    }

    /// Host-only and concealed, like every copy this app makes: a meeting
    /// transcript is precisely what Universal Clipboard must never carry off.
    public func copyTranscript(_ id: UUID) {
        let utterances = transcript(for: id)
        guard !utterances.isEmpty else { return }
        do {
            try HostOnlyPasteboard().copyHostOnly(MeetingTranscriptFormatter.plainText(utterances))
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't copy the transcript."))
        }
    }

    // MARK: - Leaving the Mac

    /// The name a file takes when it leaves: the person's own title, or the
    /// date they would recognise it by.
    public func exportName(_ id: UUID) -> String {
        let recording = recordings.first { $0.id == id } ?? liveRecording
        return MeetingExportNaming.fileName(
            recording?.title ?? "",
            fallback: RecordingsPlaceholder.defaultTitle(for: recording?.startedAt ?? Date())
        )
    }

    /// The transcript as Markdown, with the one line that must survive being
    /// pasted somewhere else: that the other side was never captured.
    public func transcriptMarkdown(_ id: UUID) -> String? {
        let utterances = transcript(for: id)
        guard !utterances.isEmpty, let recording = recordings.first(where: { $0.id == id }) else { return nil }
        let subtitle = [
            recording.startedAt.formatted(date: .long, time: .shortened),
            RecordingTime.brief(recording.duration),
            recording.isMeeting ? "Meeting" : "Voice note",
        ].joined(separator: " · ")
        return MeetingTranscriptFormatter.markdown(
            utterances,
            title: recording.title ?? RecordingsPlaceholder.defaultTitle(for: recording.startedAt),
            subtitle: subtitle,
            note: RecordingsPlaceholder.degradedNote(for: recording)
        )
    }

    public func exportTranscript(_ id: UUID, to url: URL) {
        guard let markdown = transcriptMarkdown(id) else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            notify(DictationNotice(kind: .failure, message: "Couldn't save the transcript."))
        }
    }

    /// Encode the recording to m4a at `url`. Long enough on a two-hour
    /// meeting to need a progress figure and a way out of it.
    public func exportAudio(_ id: UUID, to url: URL) {
        guard let source = recordingAudioURL(id), audioExportProgress == nil else { return }
        audioExportProgress = 0
        audioExportCancelled.value = false
        let cancelled = audioExportCancelled
        Task { [weak self] in
            do {
                try await Self.encode(from: source, to: url, cancelled: cancelled) { progress in
                    Task { @MainActor in self?.audioExportProgress = progress }
                }
                await MainActor.run { self?.audioExportProgress = nil }
            } catch MeetingAudioExporter.Failure.cancelled {
                await MainActor.run { self?.audioExportProgress = nil }
            } catch {
                await MainActor.run {
                    self?.audioExportProgress = nil
                    self?.notify(DictationNotice(kind: .failure, message: "Couldn't save the audio."))
                }
            }
        }
    }

    public func cancelAudioExport() {
        audioExportCancelled.value = true
    }

    private static func encode(
        from source: URL,
        to destination: URL,
        cancelled: UncheckedBox<Bool>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try MeetingAudioExporter.export(
                from: source,
                to: destination,
                isCancelled: { cancelled.value },
                progress: progress
            )
        }.value
    }

    /// Take the held segments up again after failures paused the queue.
    public func resumeTranscription() {
        guard let queue = transcriptionQueue else { return }
        isTranscriptionPaused = false
        Task { await queue.resume() }
    }

    private func beginTranscription(for id: UUID, directory: URL) {
        guard let meetingStore else { return }
        closedUtterances = []
        utteranceAssembler = MeetingUtteranceAssembler()
        liveTranscript = []
        transcriptBacklogSeconds = 0
        isTranscriptionPaused = false
        transcriptWriteFailureReported = false
        transcribingRecordingID = id
        let incompleteAudio = directory.appending(path: MeetingWriter.audioFileName, directoryHint: .notDirectory)
        let transcriber = self.transcriber
        let pipeline = makePipeline()
        let arbiter = engineArbiter
        transcriptionQueue = MeetingTranscriptionQueue(
            read: { segment in
                // The file moves out of .incomplete/ when the recording ends;
                // resolve where it is now, every time.
                let url = meetingStore.audioURL(for: id) ?? incompleteAudio
                return try MeetingPCMWindowReader(url: url).read(segment)
            },
            decode: { samples in
                guard let transcriber else { throw ASREngineError.modelsNotLoaded }
                let result = try await transcriber.transcribe(samples: samples)
                // The same dictionary and typography as dictation; the
                // trailing command a dictation may end with is not a thing a
                // meeting says.
                return pipeline.run(result.text).output.text
            },
            awaitTurn: { await arbiter.awaitMeetingTurn() },
            emit: { [weak self] segment, outcome in
                await MainActor.run { self?.segmentDecoded(segment, outcome) }
            }
        )
        // The engine is wanted now and stays until this is done.
        shouldStayUnloadedUntilUse = false
        prepareEngineIfIdleAndCold()
        rescheduleIdleUnload()
    }

    private func abandonTranscription() {
        transcriptionQueue = nil
        transcribingRecordingID = nil
        liveTranscript = []
        transcriptBacklogSeconds = 0
        isTranscriptionPaused = false
        rescheduleIdleUnload()
    }

    private func segmentReady(_ segment: MeetingSegmentRef) {
        guard let queue = transcriptionQueue else { return }
        transcriptBacklogSeconds += Double(segment.frameCount) / Double(MeetingWriter.sampleRate)
        Task { await queue.submit(segment) }
    }

    private func segmentDecoded(_ segment: MeetingSegmentRef, _ outcome: MeetingTranscriptionQueue.Outcome) {
        let rate = Double(MeetingWriter.sampleRate)
        transcriptBacklogSeconds = max(0, transcriptBacklogSeconds - Double(segment.frameCount) / rate)
        let start = Double(segment.startFrame) / rate
        let end = Double(segment.endFrame) / rate
        let piece: MeetingUtteranceAssembler.Segment
        switch outcome {
        case let .decoded(text):
            piece = .init(channel: segment.channel, start: start, end: end, text: text)
        case .failed:
            piece = .init(channel: segment.channel, start: start, end: end, text: "", isFailed: true)
        }
        closedUtterances += utteranceAssembler.append(piece)
        publishLiveTranscript()
        if let queue = transcriptionQueue {
            Task { [weak self] in
                let paused = await queue.isPaused
                await MainActor.run { self?.isTranscriptionPaused = paused }
            }
        }
    }

    private func publishLiveTranscript() {
        liveTranscript = closedUtterances + (utteranceAssembler.pending.map { [$0] } ?? [])
        guard let id = transcribingRecordingID, let meetingStore else { return }
        loadedTranscripts[id] = liveTranscript
        do {
            try meetingStore.write(
                MeetingTranscript(utterances: liveTranscript),
                for: id,
                incomplete: !meetingStore.isPublished(id)
            )
        } catch {
            // Text that cannot be written is text that would be lost at quit.
            // Said once; the audio is still being recorded regardless.
            guard !transcriptWriteFailureReported else { return }
            transcriptWriteFailureReported = true
            notify(DictationNotice(kind: .warning, message: "The transcript can't be saved. The recording continues."))
        }
    }

    /// After the recording is filed: let the backlog drain, close the last
    /// paragraph, and say on disk how it went.
    private func finishTranscription(for id: UUID) {
        guard let queue = transcriptionQueue, let meetingStore else { return }
        Task { [weak self] in
            await queue.drain()
            let paused = await queue.isPaused
            await MainActor.run {
                guard let self, self.transcribingRecordingID == id else { return }
                self.closedUtterances += self.utteranceAssembler.flush()
                self.publishLiveTranscript()
                if var metadata = meetingStore.metadata(for: id) {
                    metadata.transcriptionState = paused ? .partial : .complete
                    try? meetingStore.write(metadata)
                }
                self.transcriptionQueue = nil
                self.transcribingRecordingID = nil
                self.isTranscriptionPaused = false
                self.transcriptBacklogSeconds = 0
                self.reloadRecordings()
                self.rescheduleIdleUnload()
            }
        }
    }

    private func recordingFailed(_ failure: MeetingCapture.Failure) {
        switch failure {
        case .diskFull, .writeFailed:
            // The recorder has already stopped writing on its own. End the
            // recording so what reached disk is filed and listed; the notice
            // that follows says why.
            stopRecording()
        case let .microphone(reason):
            notify(DictationNotice(
                kind: .warning,
                message: "The microphone stopped (\(Self.describe(reason))). The recording continues on the default microphone."
            ))
        case let .systemAudio(reason):
            systemAudioStartFailure = Self.describe(reason)
            notify(DictationNotice(
                kind: .warning,
                message: "The other side isn't being recorded (\(Self.describe(reason))). Only your microphone is."
            ))
        case .notIdle, .notRecording, .cannotCreateDirectory:
            notify(DictationNotice(kind: .failure, message: "Recording failed: \(failure)"))
        }
    }

    private static func describe(_ reason: MeetingSourceFailure) -> String {
        switch reason {
        case let .unavailable(message), let .startFailed(message), let .conversionFailed(message):
            return message
        case .configurationChanged:
            return "the device changed"
        }
    }

    private static func recordingStartFailureMessage(_ error: Error) -> String {
        guard let failure = error as? MeetingCapture.Failure else {
            return "Couldn't start recording: \(error.localizedDescription)"
        }
        switch failure {
        case .diskFull:
            return "Not enough free space to record. Free up at least 500 MB and try again."
        case let .microphone(reason):
            return "Couldn't start the microphone: \(describe(reason))."
        case let .systemAudio(reason):
            return "Couldn't record the other side: \(describe(reason))."
        case let .cannotCreateDirectory(message), let .writeFailed(message):
            return "Couldn't start recording: \(message)"
        case .notIdle:
            return "A recording is already running."
        case .notRecording:
            return "No recording is running."
        }
    }

    private static func endNotice(for reason: MeetingEndReason?) -> DictationNotice? {
        switch reason {
        case .diskFull:
            return DictationNotice(
                kind: .warning,
                message: "Recording stopped: this Mac ran out of space. Everything up to that moment was kept."
            )
        case .writeFailed:
            return DictationNotice(
                kind: .warning,
                message: "Recording stopped: it could no longer be written. Everything up to that moment was kept."
            )
        default:
            return nil
        }
    }

    private func startLiveDurationTimer() {
        stopLiveDurationTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let capture = self.meetingCapture else { return }
                let frames = await capture.frameCount
                self.liveDuration = Double(frames) / Double(MeetingWriter.sampleRate)
                await self.refreshCaptureHealth(capture)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveDurationTimer = timer
    }

    /// Is the other side arriving? Announced when the answer changes — a
    /// blind person cannot see a meter that stopped moving, and this is the
    /// one thing about a meeting recorder that must not be discovered
    /// afterwards.
    private func refreshCaptureHealth(_ capture: any MeetingCapturing) async {
        guard let live = liveRecording else { return }
        let health = await capture.health(of: .system)
        let elapsed = liveRecordingStartedAt.map { started -> TimeInterval in
            let duration = started.duration(to: .now)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        } ?? 0
        let next = CaptureHealth.make(
            isSupported: SystemAudioAvailability.isSupported,
            requested: live.systemAudio.wasRequested,
            startFailure: systemAudioStartFailure,
            elapsed: elapsed,
            health: health,
            now: .now
        )
        if case .unheard = next, lastProbeAt.map({ $0.duration(to: .now) >= .seconds(10) }) ?? true {
            lastProbeAt = .now
            playSystemAudioProbe()
        }
        guard next != liveCaptureHealth else { return }
        liveCaptureHealth = next
        if let announcement = next.announcement, announcement != lastAnnouncedHealth {
            lastAnnouncedHealth = announcement
            announcer.announce(announcement, urgent: next.role == .attention)
        }
    }

    private func stopLiveDurationTimer() {
        liveDurationTimer?.invalidate()
        liveDurationTimer = nil
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
            applyRecordingShortcut()
        } else {
            hotkeyMonitor.stop()
            copyShortcutMonitor?.stop()
            recordingShortcutMonitor?.stop()
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

        // Only hands-free, and only while actually listening. A held key means
        // the person has not finished; a state that is not listening has no
        // recording for silence to end.
        guard stopsOnSilence, isHandsFreeActive, dictationState == .listening else {
            silence.reset()
            return
        }
        if silence.observe(peak: peak, at: .now) {
            silence.reset()
            stopCurrentRecording()
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

import AppKit
import DictationAudio
import DictationCore
import Foundation
import LocalASR

/// Own crash-WAV: payload has already been dumped to disk, but the dimensions in the header are still
/// zero because the process did not reach `WAVWriter.close()`.
func writeAbandonedTestWAV(to url: URL, sampleBytes: Int = 3200) throws {
    var data = Data()
    func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    u32(36)
    data.append(contentsOf: "WAVEfmt ".utf8)
    u32(16)
    u16(1)
    u16(1)
    u32(16_000)
    u32(32_000)
    u16(2)
    u16(16)
    data.append(contentsOf: "data".utf8)
    u32(0)
    data.append(Data(repeating: 7, count: sampleBytes))
    try data.write(to: url)
}

// False edges of the system.
//
// Application sources are compiled directly into the test bundle, so import
// there is no application here: everything is in one module.

/// General call log.
///
/// Needed where the order between different edges is important: for example, focus must
/// return before we touch the clipboard.
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

// MARK: - Source of keyboard events

@MainActor
final class FakeHotkeyEventSource: HotkeyEventSource {
    var isTrusted = true
    /// Whether to give away a subscription token. `false` - the system has failed.
    var grantsFlagsMonitor = true
    var grantsKeyMonitor = true

    private(set) var flagsMonitorCount = 0
    private(set) var keyMonitorCount = 0
    private(set) var removedTokens: [String] = []

    private var flagsHandler: (@MainActor (HotkeyEvent) -> Void)?
    private var keyHandler: (@MainActor (HotkeyEvent) -> Void)?

    /// How many subscriptions are currently alive.
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

    /// Send a modifier event, as the system would do.
    func sendFlags(_ event: HotkeyEvent) {
        flagsHandler?(event)
    }

    func sendKeyDown(_ event: HotkeyEvent) {
        keyHandler?(event)
    }
}

// MARK: - Edges of text insertion

/// False edges of the system for insertion.
///
/// A class with a castle, not an actor: the `InputSystem` methods are synchronous - that’s how they are
/// is called by insertion, but the actor cannot be accessed synchronously.
final class FakeInputSystem: InputSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var secureInput = false
    private var trusted = true
    private var frontmost: TargetApplication?
    private var activateResult = true
    /// What `heldModifiers()` will return on each call. Last element
    /// is repeated further.
    private var heldPlan: [CGEventFlags] = [[]]
    private var heldCalls = 0
    private var postError: TextInsertionError?
    private var posted: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []

    let log: CallLog

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    // MARK: Settings

    func setSecureInput(_ value: Bool) { withLock { secureInput = value } }
    func setTrusted(_ value: Bool) { withLock { trusted = value } }
    func setFrontmost(_ value: TargetApplication?) { withLock { frontmost = value } }
    func setActivateResult(_ value: Bool) { withLock { activateResult = value } }
    func setHeldPlan(_ plan: [CGEventFlags]) { withLock { heldPlan = plan.isEmpty ? [[]] : plan } }
    func setPostError(_ error: TextInsertionError?) { withLock { postError = error } }

    // MARK: Observation

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
    private var restoreError: TextInsertionError?
    private var transactions: [PasteboardTransaction] = []
    var onBegin: (@Sendable () -> Void)?

    let log: CallLog

    init(log: CallLog = CallLog()) {
        self.log = log
    }

    func setError(_ error: TextInsertionError?) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }

    func setRestoreError(_ error: TextInsertionError?) {
        lock.lock()
        defer { lock.unlock() }
        restoreError = error
    }

    var writtenTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func beginHostOnlyWrite(_ text: String) throws -> PasteboardTransaction {
        log.record("pasteboard")
        lock.lock()
        let failure = error
        if failure == nil { written.append(text) }
        lock.unlock()
        if let failure { throw failure }
        let transaction = PasteboardTransaction()
        lock.lock()
        transactions.append(transaction)
        lock.unlock()
        onBegin?()
        return transaction
    }

    func restore(_ transaction: PasteboardTransaction) throws {
        log.record("restore")
        lock.lock()
        transactions.removeAll { $0 == transaction }
        let failure = restoreError
        lock.unlock()
        if let failure { throw failure }
    }
}

// MARK: - Dictation edges

actor FakeCapture: AudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var abortCount = 0
    /// Is the microphone listening right now.
    ///
    /// This is what the "recording light goes off when we're not listening" promise rests on:
    /// you need to check it not by the state on the screen, but by whether the capture is closed.
    private(set) var isRecording = false
    /// What to return as recording duration.
    ///
    /// Shorter than the limit - and the session will end without recognition. This is how it is checked
    /// full circle of dictation without touching the real model.
    private var duration: TimeInterval = 2.0

    private let file = FileManager.default.temporaryDirectory
        .appending(path: "openramble-test-take-\(UUID().uuidString).wav")

    func setDuration(_ value: TimeInterval) { duration = value }

    func startRecording() async throws -> URL {
        startCount += 1
        isRecording = true
        return file
    }

    func stopRecording() async throws -> (url: URL, duration: TimeInterval) {
        stopCount += 1
        isRecording = false
        try Data("RIFF-test-audio".utf8).write(to: file, options: .atomic)
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
    /// How to refuse. Insertion failure is not uncommon: protected input revoked
    /// access, closed recipient window.
    private var error: TextInsertionError?
    /// Keep the insertion open until the test lets it finish.
    ///
    /// In life, `.inserting` lasts as long as ⌘V takes in someone else's application -
    /// long enough for a person to press Escape. Without a hold, the state passes
    /// between two lines of the test, and what the application says at this moment
    /// cannot be checked at all.
    private var isHolding = false
    private var held: CheckedContinuation<Void, Never>?

    func setError(_ error: TextInsertionError?) { self.error = error }

    func holdInsertions() { isHolding = true }

    func releaseInsertions() {
        isHolding = false
        held?.resume()
        held = nil
    }

    func insert(_ text: String, into target: TargetApplication?) async throws {
        if isHolding {
            await withCheckedContinuation { continuation in
                held = continuation
            }
        }
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

/// Overlay edge that also exposes the recording-feedback channel used by AppState.
@MainActor
final class FakeRecordingFeedbackOverlay: OverlayPresenting, RecordingFeedbackPresenting, @unchecked Sendable {
    private(set) var silenceHintCount = 0
    private var isShowingSilenceHint = false

    nonisolated func present(_ state: DictationState, elapsed: TimeInterval) async {}
    nonisolated func dismiss() async {}
    nonisolated func presentNotice(_ notice: DictationNotice) async {}

    func updateInputLevel(_ level: Float) {
        if level > 0.02 { isShowingSilenceHint = false }
    }

    func showSilenceHint() {
        guard !isShowingSilenceHint else { return }
        isShowingSilenceHint = true
        silenceHintCount += 1
    }

    func hideSilenceHint() {
        isShowingSilenceHint = false
    }
}

/// Installs and drives the sample callback supplied to the capture factory.
final class FakeAudioSampleEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([Float]) -> Void)?

    func install(_ handler: @escaping @Sendable ([Float]) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func emit(_ samples: [Float]) {
        let handler = lock.withLock { self.handler }
        handler?(samples)
    }
}

// MARK: - Permissions and key monitor

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
final class FakeMicrophonePermissionFlow {
    var requestResult = true
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0
    private(set) var activationCount = 0

    func request() async -> Bool {
        requestCount += 1
        return requestResult
    }

    func openSettings() {
        openSettingsCount += 1
    }

    func activateApplication() {
        activationCount += 1
    }
}

@MainActor
final class FakeAccessibilityManager: AccessibilityManaging {
    var requestResult = false
    var resetError: Error?
    var relaunchError: Error?

    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0
    private(set) var revealApplicationCount = 0
    private(set) var resetCount = 0
    private(set) var relaunchCount = 0

    func requestAccess() -> Bool {
        requestCount += 1
        return requestResult
    }

    func openSettings() {
        openSettingsCount += 1
    }

    func revealApplication() {
        revealApplicationCount += 1
    }

    func resetAccess() async throws {
        resetCount += 1
        if let resetError { throw resetError }
    }

    func relaunchApplication() async throws {
        relaunchCount += 1
        if let relaunchError { throw relaunchError }
    }
}

// MARK: - Entire application

/// Dummy application environment.
///
/// Collected in one place so that different sets of checks do not disperse in
/// how the application sees the computer. Notification centers are their own here, not
/// system: the check should neither hear the real sleep of the machine nor wake it up
/// other people's subscribers.
/// A dummy field of someone else's application: counts how many times it has been looked into.
///
/// We count the captures, not the result: the promise “turned off means not
/// read” breaks down already when accessing the field, even if you throw away what you read.
@MainActor
final class FakeFocusedField: FocusedFieldReading {
    var value: String?
    private(set) var captured = 0

    func captureFocusedField() -> FocusedFieldHandle? {
        captured += 1
        return FocusedFieldHandle { [weak self] in self?.value }
    }
}

@MainActor
final class AppHarness {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let focusedField = FakeFocusedField()
    let permissions = FakePermissions()
    let microphonePermissionFlow = FakeMicrophonePermissionFlow()
    let accessibilityManager = FakeAccessibilityManager()
    let monitor = FakeHotkeyMonitor()
    let overlay = FakeOverlay()
    let audioSamples = FakeAudioSampleEmitter()
    let capture = FakeCapture()
    let inserter = FakeInserter()
    let workspaceNotifications = NotificationCenter()
    let notifications = NotificationCenter()
    let downloader = BlockingModelDownloader()

    /// Zero - permission polling is disabled: in the check they are changed by us, not
    /// system.
    var permissionPollInterval: TimeInterval = 0
    var overlayOverride: (any OverlayPresenting)?

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(
                path: "openramble-harness-\(UUID().uuidString)",
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

    /// Sweep up the settings files left over from previous runs.
    ///
    /// Cleaning at the end of the test does not take everything: the settings service writes out
    /// empty file to disk after the test is over, and catch up
    /// she can't. Therefore, we sweep at the beginning - by this moment all the past has already
    /// added. Without this, each run left a couple of dozen files in
    /// the developer’s personal folder, and during the work they accumulated nearly a thousand.
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
        // The domain is removed from the settings, but the file remains: the settings service still
        // writes the empty plist to disk. One run - one file; in time
        // there were nearly a thousand of them working on the project. We remove the file too.
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

    /// What recognition “hears”. There is no real model in the test, and there is no answer
    /// the dictation would break off halfway and the path to the insertion would remain unchecked.
    let transcription = FakeTranscription()

    /// Engine for warming up. It is not needed for routine checks: without it, warming up
    /// is considered passed. It is set where the heating itself is checked.
    var warmUpEngine: (any ASREngineAdapting)?

    func makeState() -> AppState {
        let selectedOverlay = overlayOverride ?? overlay
        return AppState(
            environment: AppEnvironment(
                defaults: defaults,
                paths: AppPaths(root: root),
                permissions: permissions,
                accessibilityManager: accessibilityManager,
                hotkeyMonitor: monitor,
                inserter: inserter,
                overlay: selectedOverlay,
                makeCapture: { [capture, audioSamples] _, _, onSamples in
                    audioSamples.install(onSamples)
                    return capture
                },
                transcribe: { [transcription] _, _ in
                    { _ in
                        if let delay = transcription.delay {
                            try await Task.sleep(for: delay)
                        }
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
                requestMicrophoneAccess: { [permissions, microphonePermissionFlow] in
                    let granted = await microphonePermissionFlow.request()
                    if granted { permissions.microphoneGranted = true }
                    return granted
                },
                openMicrophoneSettings: { [microphonePermissionFlow] in
                    microphonePermissionFlow.openSettings()
                },
                activateApplication: { [microphonePermissionFlow] in
                    microphonePermissionFlow.activateApplication()
                },
                workspaceNotifications: workspaceNotifications,
                notifications: notifications,
                localTranscriber: warmUpEngine.map { LocalTranscriber(engine: $0) },
                focusedFieldReader: focusedField
            )
        )
    }

    /// Expand the test inventory and the label of the finished model.
    ///
    /// Sparse files: logical size matches manifest, but blocks on
    /// 483 MB does not occupy the disk. Marker captures the same size/mtime that
    /// records a production installation that has passed SHA check.
    func installModelMarker() throws {
        // The product considers the model ready only when both the main and
        // term hint. The test setup marks both.
        try installMarker(for: try ModelManifest.bundled())
        try installMarker(for: try ModelManifest.bundledVocabulary())
    }

    /// State after updating from a build without a hint: main model
    /// worth it, no hint - checking the selection script.
    func installMainModelMarkerOnly() throws {
        try installMarker(for: try ModelManifest.bundled())
    }

    private func installMarker(for manifest: ModelManifest) throws {
        let paths = AppPaths(root: root)
        let layout = try ModelInstallLayout(manifest: manifest, root: try paths.models())
        try FileManager.default.createDirectory(
            at: layout.engineDirectory,
            withIntermediateDirectories: true
        )
        var installedFiles: [ModelReadyMarker.InstalledFile] = []
        for file in manifest.files {
            let url = layout.engineDirectory.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.byteCount))
            try handle.close()
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            installedFiles.append(
                .init(
                    path: file.path,
                    byteCount: file.byteCount,
                    modifiedAt: values.contentModificationDate
                )
            )
        }
        let marker = ModelReadyMarker(
            manifest: manifest,
            verifiedAt: Date(),
            installedFiles: installedFiles.sorted { $0.path < $1.path }
        )
        try JSONEncoder().encode(marker).write(to: layout.readyMarker)
    }
}

// MARK: - Interface voice

/// Dummy VoiceOver.
///
/// Real advertisements go into the system and do not come back: without this
/// substitutions cannot be checked for any of them, and for a blind person they
/// there is the entire dictation interface.
@MainActor
final class FakeAnnouncer: AccessibilityAnnouncing {
    private(set) var announcements: [(message: String, urgent: Bool)] = []

    var messages: [String] { announcements.map(\.message) }

    func announce(_ message: String, urgent: Bool) {
        announcements.append((message, urgent))
    }

    /// Forget what was said. Needed where one ad is checked, and before it
    /// Others were heard on the case.
    func reset() {
        announcements = []
    }
}

// MARK: - Loading the model

/// A loader that doesn’t go anywhere and doesn’t let go until it’s allowed.
///
/// Needed to catch the application in the “loading” state and see
/// what other screens are doing with it at this moment.
final class BlockingModelDownloader: ModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var terminalError: ModelDownloadError = .cancelled

    var hasStarted: Bool { lock.withLock { started } }

    func release(throwing error: ModelDownloadError = .cancelled) {
        lock.withLock {
            terminalError = error
            released = true
        }
    }

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

        // The released download ends with cancellation: bring the installation to
        // there is nothing to check the amounts here - there are no real model files.
        throw lock.withLock { terminalError }
    }
}

@MainActor
final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onSingleTapWhileHandsFree: (() -> Void)?
    var onAbortShortcut: (() -> Void)?
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


/// Pre-known recognition response.
final class FakeTranscription: @unchecked Sendable {
    var text = "Ping test"
    var error: (any Error)?
    var delay: Duration?
}

/// An engine for which Core ML does not load, although the model files on disk are intact.
///
/// Exactly this kind of failure happens in life: the SHA-256 check passed, but the loading
/// fell into the neuromodule. Inspection of the disk cannot detect this condition.
final class FailingASREngine: ASREngineAdapting, @unchecked Sendable {
    func loadModels(from directory: URL) async throws {
        throw ASREngineError.modelsUnavailable("Core ML failed loading")
    }

    func transcribe(samples: [Float]) async throws -> ASRResult {
        throw ASREngineError.modelsNotLoaded
    }

    func unload() async {}
}

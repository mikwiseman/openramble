import AppKit
import AVFoundation
import DictationCore
import Darwin
import LocalASR
import XCTest

/// Application life between dictations.
///
/// It sits in the menu bar for weeks and does nothing. Everything it does in
/// this time is a pure cost, and everything that it does not do upon awakening
/// computer or turning off the headphones - stuck dictation with
/// microphone.
@MainActor
final class AppStateIdleTests: XCTestCase {
    private var harness: AppHarness!

    private var monitor: FakeHotkeyMonitor { harness.monitor }
    private var capture: FakeCapture { harness.capture }
    private var overlay: FakeOverlay { harness.overlay }

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    // MARK: - Poll for permissions

    /// The survey is ongoing and when everything is issued, it was decided deliberately: access cannot be revoked
    /// sends events, and a silent key is indistinguishable from a breakdown. Details
    /// solutions - in the `PermissionPollPolicy` header.
    func testScenario001() {
        harness.permissionPollInterval = 1

        let state = harness.makeState()

        XCTAssertEqual(state.permissionPollingInterval, 1)
        XCTAssertTrue(state.isPollingPermissions)
    }

    /// While there is no permission, the person stands in the system settings and waits for
    /// the screen will respond.
    func testScenario002() {
        harness.permissionPollInterval = 1
        harness.permissions.microphoneGranted = false

        let state = harness.makeState()

        XCTAssertEqual(state.permissionPollingInterval, 1)
    }

    func testScenario003() {
        harness.permissionPollInterval = 1
        harness.permissions.accessibilityGranted = false
        let state = harness.makeState()
        XCTAssertEqual(state.permissionPollingInterval, 1)

        harness.permissions.accessibilityGranted = true
        state.refreshPermissions()

        XCTAssertEqual(state.permissionPollingInterval, 1)
    }

    func testScenario004() {
        harness.permissionPollInterval = 0

        let state = harness.makeState()

        XCTAssertEqual(state.permissionPollingInterval, 0)
        XCTAssertFalse(state.isPollingPermissions)
    }

    // MARK: - Timers at rest

    func testScenario005() async throws {
        let state = try await makeReadyState()
        XCTAssertFalse(state.isCountingDuration)

        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }
        XCTAssertTrue(state.isCountingDuration, "there is nothing to check the hourly limit")

        monitor.onRelease?()
        try await waitFor("dictation ended") { state.dictationState == .idle }

        XCTAssertFalse(state.isCountingDuration, "the timer continues to wake the process after dictation")
    }

    func testSilenceFeedbackPolicyResetsOnSoundAndStopsDeterministically() {
        var policy = SilenceFeedbackPolicy()
        policy.start(at: 100)

        XCTAssertFalse(policy.shouldShowHint(at: 101.999))
        XCTAssertTrue(policy.shouldShowHint(at: 102))

        policy.registerInput(peak: 0.4, at: 101.5)
        XCTAssertFalse(policy.shouldShowHint(at: 103.499))
        XCTAssertTrue(policy.shouldShowHint(at: 103.5))

        policy.stop()
        XCTAssertFalse(policy.shouldShowHint(at: 1_000))
    }

    func testSilenceWatcherExistsOnlyWhileRecording() async throws {
        let state = try await makeReadyState()
        XCTAssertFalse(state.isWatchingSilence)

        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }
        XCTAssertTrue(state.isWatchingSilence)

        monitor.onRelease?()
        try await waitFor("dictation ended") { state.dictationState == .idle }
        XCTAssertFalse(state.isWatchingSilence)
    }

    // MARK: - Microphone

    /// Direct product promise: The recording light turns off when we're not listening.
    func testScenario006() async throws {
        let state = try await makeReadyState()

        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }
        monitor.onRelease?()
        try await waitFor("dictation ended") { state.dictationState == .idle }

        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    func testScenario007() async throws {
        let state = try await makeReadyState()

        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }
        monitor.onEscape?()
        try await waitFor("dictation cancelled") { state.dictationState == .idle }

        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    // MARK: - Sleep and awakening

    /// Mac fell asleep in the middle of dictation.
    ///
    /// The release of a key that happened in a dream will not reach us. Non-stop
    /// the session remains in “listening” forever: microphone is on, recording indicator
    /// is lit, and the only way out of this is via Escape.
    func testScenario008() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        try await waitFor("dictation ended") { state.dictationState == .idle }
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "microphone left on on sleeping machine")
    }

    /// What is written down before bed is not thrown away: the person has already said it.
    func testScenario009() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitFor("dictation ended") { state.dictationState == .idle }

        let stops = await capture.stopCount
        let aborts = await capture.abortCount
        XCTAssertEqual(stops, 1, "the recording was terminated instead of being written to disk")
        XCTAssertEqual(aborts, 0)
        XCTAssertEqual(state.lastNotice?.kind, .info)
        XCTAssertEqual(state.lastNotice?.message.contains("sleep"), true)

        // The explanation must reach the screen. Said in the middle of stopping him
        // does not reach: the kernel immediately redraws the panel under “recognize”.
        try await waitFor("explanation reached the panel") {
            await self.overlay.notices.contains { $0.message.contains("sleep") }
        }
    }

    /// Sleeping in the middle of dictation without holding down a key.
    ///
    /// In this mode, releasing the key does not mean anything: recording continues until
    /// next click. It cannot be stopped in the usual way - appeal
    /// will pass by, and the microphone will remain on until the hour limit.
    func testScenario010() async throws {
        let state = try await makeReadyState()
        monitor.onDoubleTap?()
        try await waitFor("recording has started") { state.dictationState == .listening }
        XCTAssertTrue(state.isHandsFreeActive)

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        try await waitFor("dictation ended") { state.dictationState == .idle }
        let recording = await capture.isRecording
        XCTAssertFalse(recording, "non-hold recording survived computer sleep")
    }

    /// The application caught the dream before the first frame of sound - there was nothing to record.
    func testScenario011() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        XCTAssertEqual(state.dictationState, .preparing)

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)

        try await waitFor("session closed") { state.dictationState == .idle }
        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    func testScenario012() async throws {
        let state = try await makeReadyState()

        harness.workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertNil(state.lastNotice)
        let starts = await capture.startCount
        XCTAssertEqual(starts, 0)
    }

    /// After waking up, tracking starts again.
    ///
    /// The key was released during sleep, but there was no event about it:
    /// the monitor still considers it clamped and will swallow the next press.
    func testScenario013() async throws {
        let state = harness.makeState()
        XCTAssertTrue(monitor.isRunning)
        let stopsBefore = monitor.stopCount

        harness.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await waitFor("monitoring restarted") { self.monitor.stopCount > stopsBefore }

        XCTAssertTrue(monitor.isRunning, "after waking up, the key stopped responding")
        XCTAssertTrue(state.accessibilityGranted)
    }

    // MARK: - Change audio device

    /// The headphones were taken out mid-sentence.
    ///
    /// The engine remains running, but frames no longer come into it: person
    /// speaks into silence and would only know about it by the empty result.
    func testScenario014() async throws {
        let state = try await makeReadyState()
        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }

        harness.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)

        try await waitFor("dictation ended") { state.dictationState == .idle }
        try await waitFor("WAV available for Retry") { state.recoveredRecording != nil }
        XCTAssertEqual(state.lastNotice?.kind, .failure)
        XCTAssertEqual(state.lastNotice?.message.contains("audio device was disconnected"), true)
        let recording = await capture.isRecording
        XCTAssertFalse(recording)
    }

    /// After disconnect, recognition does not start on the trimmed audio.
    func testScenario015() async throws {
        harness.transcription.error = ASREngineError.modelsNotLoaded
        let state = try await makeReadyState(recordingDuration: 2)
        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }

        harness.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await waitFor("dictation ended") { state.dictationState == .idle }

        let notices = await overlay.notices
        XCTAssertTrue(
            notices.contains { $0.message.contains("audio device was disconnected") },
            "we need an exact reason for stopping"
        )
        XCTAssertFalse(
            notices.contains { $0.message.contains("transcribe") },
            "after disconnect ASR should not start"
        )
    }

    /// Devices change and just like that: they connected the monitor, the headphones went into
    /// sleep. As long as we don't listen, it's none of our business.
    func testScenario016() async throws {
        let state = try await makeReadyState()

        harness.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(state.lastNotice)
        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Loading the model

    /// Open settings should not erase a download in progress.
    ///
    /// The Model tab inspects the disk when it appears. Ready marks in
    /// there is no loading time yet, so the inspection declared the model uninstalled -
    /// and the person who came to look at the progress saw a button instead
    /// “Download model”.
    func testScenario017() async throws {
        let state = harness.makeState()
        state.installModel()
        try await waitFor("download has started") {
            if case .downloading = state.modelState { return true }
            return false
        }

        await state.refreshModelState()

        guard case .downloading = state.modelState else {
            XCTFail("disk scan erased loading in progress: \(state.modelState)")
            return
        }

        harness.downloader.release()
        try await waitFor("download finished") { state.modelState == .notInstalled }
    }

    /// A failed install must keep its exact error and Retry action on screen.
    /// Refreshing the empty install directory used to replace this state with
    /// “Model not installed” immediately, making the real network error flash by.
    func testFailedModelDownloadRemainsVisible() async throws {
        let state = harness.makeState()
        state.installModel()
        try await waitFor("download has started") { self.harness.downloader.hasStarted }

        // A permanent failure, deliberately: transient ones are retried now, and
        // a retried download is still a download — it must not flash "failed"
        // between attempts. 404 is not retried, so it surfaces immediately, and
        // that is what this test is about: the failure stays on screen instead
        // of silently resetting to "not installed".
        harness.downloader.release(throwing: .httpStatus(404))
        try await Task.sleep(for: .milliseconds(100))

        guard case let .failed(.download(detail)) = state.modelState else {
            XCTFail("download error did not remain visible: \(state.modelState)")
            return
        }
        XCTAssertTrue(detail.contains("404"), "the reason must reach the user: \(detail)")
    }

    // MARK: - Many cycles in a row

    /// Two hundred dictations in a row.
    ///
    /// The application lives for weeks, and the leak is the size of one object per dictation
    /// is not visible either in the second or in the tenth.
    func testScenario018() async throws {
        let state = try await makeReadyState()

        // Warm-up: the first laps raise internal buffers and caches, and without it
        // their one-time price would look like a leak.
        for _ in 0..<20 { try await runCycle(state) }
        let before = residentBytes()

        for _ in 0..<200 { try await runCycle(state) }

        let after = residentBytes()
        let grown = after > before ? after - before : 0
        XCTAssertLessThan(
            grown,
            4 * 1024 * 1024,
            "over 200 dictations the application grew by \(grown / 1024) KB"
        )

        // Each started recording must be closed - otherwise the microphone remains
        // would be turned on, and the number would invisibly move apart.
        let starts = await capture.startCount
        let stops = await capture.stopCount
        let aborts = await capture.abortCount
        XCTAssertEqual(starts, 220)
        XCTAssertEqual(stops + aborts, starts)

        XCTAssertFalse(state.isCountingDuration)
        XCTAssertEqual(state.dictationState, .idle)
    }

    /// After work, the entire application is released.
    ///
    /// The closures at the edges of the system hold it weakly; it's worth taking one of them
    /// it is strong - and everything remains alive: the controller, the capture, the timers.
    func testScenario019() async throws {
        weak var weakState: AppState?

        try await autoreleasepoolAsync {
            let state = try await makeReadyState()
            weakState = state
            for _ in 0..<5 { try await runCycle(state) }
        }

        // Task tails hold their state for a moment after leaving the area.
        try await waitFor("state released") { weakState == nil }
        XCTAssertNil(weakState)
    }

    // MARK: - Auxiliary

    /// Application with permissions granted and model decomposed.
    ///
    /// The recording duration is below the limit - the session is closed without logging in
    /// recognition: the real model is still not on the disk.
    private func makeReadyState(recordingDuration: TimeInterval = 0.1) async throws -> AppState {
        try harness.installModelMarker()
        await capture.setDuration(recordingDuration)
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.isDictationReady)
        return state
    }

    private func runCycle(_ state: AppState) async throws {
        monitor.onPress?()
        try await waitFor("recording has started") { state.dictationState == .listening }
        monitor.onRelease?()
        try await waitFor("dictation ended") { state.dictationState == .idle }
    }

    private func waitFor(
        _ what: String,
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("didn't wait: \(what)", file: file, line: line)
    }

    /// How much memory is occupied by the process right now.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// `autoreleasepool` does not pass through `await`, so the area
    /// The life of the object here is set by a regular function.
    private func autoreleasepoolAsync(_ body: () async throws -> Void) async rethrows {
        try await body()
    }
}

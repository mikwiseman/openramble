import Combine
import DictationCore
import LocalASR
import XCTest

/// Application wiring: what happens at the edges, where things usually break.
@MainActor
final class AppStateTests: XCTestCase {
    func testScenario001() {
        let message = AppState.captureFailureMessage(
            .unsupportedAudioFormat("48 kHz stereo couldn't be converted")
        )

        XCTAssertTrue(message.contains("audio format"))
        XCTAssertTrue(message.contains("48 kHz stereo"))
        XCTAssertFalse(message.contains("disk space"))
    }

    private var harness: AppHarness!

    private var root: URL { harness.root }
    private var defaults: UserDefaults { harness.defaults }
    private var permissions: FakePermissions { harness.permissions }
    private var accessibilityManager: FakeAccessibilityManager { harness.accessibilityManager }
    private var monitor: FakeHotkeyMonitor { harness.monitor }
    private var overlay: FakeOverlay { harness.overlay }
    private var capture: FakeCapture { harness.capture }

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func makeState() -> AppState { harness.makeState() }

    private func installModelMarker() throws { try harness.installModelMarker() }

    /// WAVs quietly kept for safety after failures and interruptions.
    private func recoveryFiles() -> [String] {
        guard let directory = try? AppPaths(root: root).audioRecovery() else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - Permissions

    func testFirstLaunchDoesNotCoverOnboardingWithPermissionNotice() async {
        permissions.microphoneGranted = false
        permissions.accessibilityGranted = false

        _ = makeState()
        await Task.yield()

        let notices = await overlay.notices
        XCTAssertTrue(notices.isEmpty)
    }

    func testReturningUserSeesOnlyTheMissingPermissionNamed() async {
        defaults.set(true, forKey: "onboardingCompleted")
        permissions.microphoneGranted = true
        permissions.accessibilityGranted = false

        _ = makeState()
        for _ in 0..<20 where await overlay.notices.isEmpty { await Task.yield() }

        let message = await overlay.notices.first?.message
        XCTAssertEqual(message, "Dictation is off: grant Accessibility access in System Settings.")
    }

    func testReturningUserMicrophoneNoticeNamesOnlyMicrophone() async {
        defaults.set(true, forKey: "onboardingCompleted")
        permissions.microphoneGranted = false
        permissions.accessibilityGranted = true

        _ = makeState()
        for _ in 0..<20 where await overlay.notices.isEmpty { await Task.yield() }

        let message = await overlay.notices.first?.message
        XCTAssertEqual(message, "Dictation is off: grant Microphone access in System Settings.")
    }

    func testReturningUserBothPermissionsNoticeNamesBoth() async {
        defaults.set(true, forKey: "onboardingCompleted")
        permissions.microphoneGranted = false
        permissions.accessibilityGranted = false

        _ = makeState()
        for _ in 0..<20 where await overlay.notices.isEmpty { await Task.yield() }

        let message = await overlay.notices.first?.message
        XCTAssertEqual(
            message,
            "Dictation is off: grant Microphone and Accessibility access in System Settings."
        )
    }

    func testScenario002() {
        permissions.accessibilityGranted = false

        let state = makeState()

        XCTAssertFalse(state.accessibilityGranted)
        XCTAssertFalse(state.isDictationReady)
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(state.accessibilityState, .denied)
    }

    /// The permission poll runs forever by design — so an unchanged tick must
    /// publish nothing. `@Published` does not deduplicate, and an unguarded
    /// write here re-rendered the entire menu bar scene once a second for the
    /// whole life of the process.
    func testSteadyStatePermissionTickPublishesNothing() async throws {
        permissions.accessibilityGranted = true
        permissions.microphoneGranted = true
        let state = makeState()
        state.refreshPermissions()
        // Let the launch-time async work (model scan, recovery import) settle
        // so it cannot masquerade as tick-driven churn.
        for _ in 0..<40 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        var publishes = 0
        let subscription = state.objectWillChange.sink { _ in publishes += 1 }
        state.refreshPermissions()
        state.refreshPermissions()
        subscription.cancel()

        XCTAssertEqual(publishes, 0, "an unchanged permission tick must not touch published state")
    }

    func testScenario003() {
        permissions.accessibilityGranted = false
        let state = makeState()

        state.requestAccessibility()

        XCTAssertEqual(accessibilityManager.requestCount, 1)
        XCTAssertEqual(accessibilityManager.openSettingsCount, 1)
        XCTAssertEqual(accessibilityManager.resetCount, 0)
        XCTAssertEqual(state.accessibilityState, .waitingForSettings)
    }

    func testScenario004() async {
        permissions.accessibilityGranted = false
        let state = makeState()
        state.requestAccessibility()

        harness.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(state.accessibilityState, .restartRequired)
    }

    func testScenario005() async {
        permissions.accessibilityGranted = false
        let state = makeState()

        state.restartForAccessibility()
        await Task.yield()

        XCTAssertEqual(accessibilityManager.relaunchCount, 1)
        XCTAssertTrue(defaults.bool(forKey: AppState.accessibilityRelaunchPendingKey))
    }

    func testScenario006() {
        permissions.accessibilityGranted = false
        defaults.set(true, forKey: AppState.accessibilityRelaunchPendingKey)

        let state = makeState()

        XCTAssertEqual(state.accessibilityState, .repairRequired)
        XCTAssertEqual(accessibilityManager.resetCount, 0)
    }

    func testScenario007() {
        permissions.accessibilityGranted = true
        defaults.set(true, forKey: AppState.accessibilityRelaunchPendingKey)

        let state = makeState()

        XCTAssertEqual(state.accessibilityState, .granted)
        XCTAssertFalse(defaults.bool(forKey: AppState.accessibilityRelaunchPendingKey))
    }

    func testScenario008() async {
        permissions.accessibilityGranted = false
        defaults.set(true, forKey: AppState.accessibilityRelaunchPendingKey)
        let state = makeState()
        XCTAssertEqual(accessibilityManager.resetCount, 0)

        state.repairAccessibility()
        for _ in 0..<20 where accessibilityManager.relaunchCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(accessibilityManager.resetCount, 1)
        XCTAssertEqual(accessibilityManager.relaunchCount, 1)
        XCTAssertFalse(defaults.bool(forKey: AppState.accessibilityRelaunchPendingKey))
    }

    func testMicrophoneGrantReturnsFocusToOpenRamble() async throws {
        permissions.microphoneGranted = false
        harness.microphonePermissionFlow.requestResult = true
        let state = makeState()

        state.requestMicrophone()
        for _ in 0..<200 where harness.microphonePermissionFlow.activationCount == 0 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(harness.microphonePermissionFlow.requestCount, 1)
        XCTAssertEqual(harness.microphonePermissionFlow.activationCount, 1)
        XCTAssertEqual(harness.microphonePermissionFlow.openSettingsCount, 0)
        XCTAssertTrue(state.microphoneGranted)
    }

    func testDeniedMicrophoneRequestKeepsSystemSettingsInFront() async throws {
        permissions.microphoneGranted = false
        harness.microphonePermissionFlow.requestResult = false
        let state = makeState()

        state.requestMicrophone()
        for _ in 0..<200 where harness.microphonePermissionFlow.openSettingsCount == 0 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(harness.microphonePermissionFlow.requestCount, 1)
        XCTAssertEqual(harness.microphonePermissionFlow.openSettingsCount, 1)
        XCTAssertEqual(harness.microphonePermissionFlow.activationCount, 0)
        XCTAssertFalse(state.microphoneGranted)
    }

    func testScenario009() async {
        permissions.accessibilityGranted = false
        accessibilityManager.resetError = CocoaError(.fileWriteNoPermission)
        let state = makeState()

        state.repairAccessibility()
        for _ in 0..<20 where state.accessibilityState == .repairing {
            await Task.yield()
        }

        guard case .failed = state.accessibilityState else {
            return XCTFail("Visible recovery error expected")
        }
        XCTAssertEqual(accessibilityManager.relaunchCount, 0)
    }

    func testScenario010() {
        let state = makeState()

        state.revealApplicationForAccessibility()

        XCTAssertEqual(accessibilityManager.revealApplicationCount, 1)
    }

    func testScenario011() {
        permissions.accessibilityGranted = true

        _ = makeState()

        XCTAssertTrue(monitor.isRunning)
    }

    /// Access was denied while the application was running.
    ///
    /// Tracking must stop: the system has stopped sending anyway
    /// events, and a live subscription would create the appearance that the key is working.
    func testScenario012() {
        permissions.accessibilityGranted = true
        let state = makeState()
        XCTAssertTrue(monitor.isRunning)

        permissions.accessibilityGranted = false
        state.refreshPermissions()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertFalse(state.isDictationReady)
    }

    func testScenario013() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .listening)

        permissions.accessibilityGranted = false
        state.refreshPermissions()
        // The WAV reaches safekeeping before the session finishes cleaning up:
        // wait for the idle state too, or a slow machine reads mid-teardown.
        for _ in 0..<200 where recoveryFiles().isEmpty || state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertFalse(recoveryFiles().isEmpty, "the interrupted take must be kept on disk")
    }

    func testScenario014() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .listening)

        permissions.microphoneGranted = false
        state.refreshPermissions()
        // Same as above: safekeeping lands before the session reaches idle.
        for _ in 0..<200 where recoveryFiles().isEmpty || state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertFalse(state.isDictationReady)
        XCTAssertFalse(recoveryFiles().isEmpty, "the interrupted take must be kept on disk")
    }

    func testScenario015() async throws {
        try installModelMarker()
        harness.transcription.delay = .milliseconds(300)
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        monitor.onRelease?()
        for _ in 0..<40 where state.dictationState != .transcribing {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .transcribing)

        permissions.accessibilityGranted = false
        state.refreshPermissions()

        XCTAssertEqual(state.lastNotice?.message.contains("Accessibility access was revoked"), true)
    }

    func testScenario016() {
        permissions.microphoneGranted = false

        let state = makeState()

        XCTAssertFalse(state.isDictationReady)
    }

    /// Pressing a key without permissions should not trigger recording.
    func testScenario017() {
        permissions.accessibilityGranted = false
        permissions.microphoneGranted = false
        let state = makeState()

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - Model

    func testScenario018() async {
        let state = makeState()
        await state.refreshModelState()
        XCTAssertFalse(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: - First successful dictation

    func testScenario019() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertEqual(state.successfulDictationCount, 0)

        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.successfulDictationCount, 0)
        monitor.onRelease?()
        for _ in 0..<60 where state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.successfulDictationCount, 1)
    }

    func testScenario020() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        state.cancelCurrentDictation()
        for _ in 0..<40 where state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(state.lastNotice?.message, "Dictation cancelled. The recording was deleted.")
        XCTAssertEqual(state.successfulDictationCount, 0)
    }

    func testScenario021() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .preparing)
    }

    /// Deleting a model in the middle of a dictation.
    ///
    /// The model is currently in operation. To take it out from under you means to lose it already
    /// said and show a vague loading error instead.
    func testScenario022() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertNotEqual(state.dictationState, .idle)

        state.deleteModel()

        XCTAssertEqual(state.lastNotice?.kind, .warning)
        XCTAssertEqual(state.modelState.isReady, true)
        // The message must reach the screen, and not settle in the field. Shown
        // it is a task, so we let it reach the overlay.
        try await Task.sleep(for: .milliseconds(100))
        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.message.contains("Wait for it to finish") })
    }

    func testScenario023() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        XCTAssertTrue(state.modelState.isReady)

        state.deleteModel()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(state.modelState.isReady)
    }

    func testScenario024() async throws {
        // Previous builds wrote unrecognized text in Recovered/. Promise
        // “recognized text is not written to disk” must also cover their traces.
        let legacy = harness.root.appending(path: "OpenRamble", directoryHint: .isDirectory)
            .appending(path: "Recovered", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("old dictation".utf8).write(to: legacy.appending(path: "recovery-1.txt"))

        _ = makeState()
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: legacy.path) { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacy.path),
            "Dictation texts of old builds should disappear the first time you run them"
        )
    }

    func testScenario025() async throws {
        // The person updated from a build where there was no hint yet: main
        // the model is standing, there is no hint. For him, this is “the model is not ready,” but
        // the button must name the real balance, and not the full 586 MB.
        try harness.installMainModelMarkerOnly()
        let state = makeState()

        await state.refreshModelState()

        XCTAssertFalse(state.modelState.isReady)
        XCTAssertEqual(state.remainingDownloadMegabytes, 103)
    }

    func testScenario026() async throws {
        // The model files are intact, but Core ML does not pick them up. Inspection of the disk is like this
        //cannot see the state: it will say “ready” again.
        try installModelMarker()
        harness.warmUpEngine = FailingASREngine()
        let state = makeState()

        // Warm-up at the start drops and requires explicit restoration.
        for _ in 0..<200 {
            if case .repairRequired = state.modelState { break }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .repairRequired = state.modelState else {
            return XCTFail("Warming up should have ended with repairRequired, not \(state.modelState)")
        }

        // The person opened the settings - the screen updated the state of the model from the disk.
        await state.refreshModelState()

        // The recovery button is not allowed to disappear: dictation does not work,
        // and “I’m preparing a model...” without end is a dead end with no way out.
        guard case .repairRequired = state.modelState else {
            return XCTFail(
                "The disk inspection was overwritten by repairRequired: \(state.modelState). The person was left without a repair button."
            )
        }
        XCTAssertFalse(state.isEngineReady)
    }

    // MARK: - Press when not ready

    /// Wait for a message on the panel. The explanation goes there through the problem, and
    /// immediately after clicking it is not there yet.
    private func waitForNotice(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let messages = await overlay.notices.map(\.message)
            if messages.contains(where: { $0.contains(fragment) }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        let messages = await overlay.notices.map(\.message)
        XCTFail("did not wait for '\(fragment)'. Said: \(messages)", file: file, line: line)
    }

    /// Previously, pressing when not ready did absolutely nothing: the kernel
    /// rejected the start silently, and the person was left with a seemingly working program,
    /// which does not respond to a key.
    func testScenario027() async throws {
        let state = makeState()
        await state.refreshModelState()
        XCTAssertFalse(state.modelState.isReady)

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
        try await waitForNotice(containing: "model isn't downloaded")
    }

    func testScenario028() async throws {
        try installModelMarker()
        harness.permissions.microphoneGranted = false
        let state = makeState()
        await state.refreshModelState()

        monitor.onPress?()

        XCTAssertEqual(state.dictationState, .idle)
        try await waitForNotice(containing: "microphone access")
    }

    /// The same response to a gesture without holding: remain silent on a double tap
    /// dishonest, as usual.
    func testScenario029() async throws {
        let state = makeState()
        await state.refreshModelState()

        monitor.onDoubleTap?()

        XCTAssertEqual(state.dictationState, .idle)
        XCTAssertFalse(state.isHandsFreeActive)
        try await waitForNotice(containing: "model isn't downloaded")
    }

    /// There is nothing to explain in readiness: the panel shows the dictation itself.
    func testScenario030() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        let before = await overlay.notices.count

        monitor.onPress?()
        XCTAssertEqual(state.dictationState, .preparing)

        // Give the explain task a chance to work if it were started.
        try await Task.sleep(for: .milliseconds(50))
        let after = await overlay.notices.count
        XCTAssertEqual(after, before, "ready dictation has no right to explain anything")
    }

    /// Clicking on top of an ongoing dictation is also rejected by the kernel - and here there is silence
    /// appropriate: the panel is on the screen, a person can already see what is happening.
    func testScenario031() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertEqual(state.dictationState, .preparing)
        let before = await overlay.notices.count

        monitor.onPress?()

        try await Task.sleep(for: .milliseconds(50))
        let after = await overlay.notices.count
        XCTAssertEqual(after, before)
    }

    // MARK: - Gestures

    func testScenario032() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        monitor.onDoubleTap?()

        XCTAssertEqual(state.dictationState, .preparing)
        XCTAssertTrue(state.isHandsFreeActive)
    }

    /// The double click comes after the first one has launched the session.
    ///
    /// You cannot start a new one at this moment - it would not pass the test
    /// free state, and the mode without holding would remain unattainable.
    func testScenario033() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()
        XCTAssertFalse(state.isHandsFreeActive)

        monitor.onDoubleTap?()

        XCTAssertTrue(state.isHandsFreeActive)
        XCTAssertTrue(monitor.isHandsFreeActive, "the monitor needs to know the mode, otherwise the next press will start a new dictation instead of stopping")
    }

    func testScenario034() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        // While there is no dictation, Escape is a regular key for someone else's application.
        monitor.onEscape?()

        XCTAssertEqual(state.dictationState, .idle)
        let aborts = await capture.abortCount
        XCTAssertEqual(aborts, 0)
    }

    func testScenario035() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()
        monitor.onPress?()

        monitor.onEscape?()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(state.dictationState, .idle)
    }

    /// Escape during insertion.
    ///
    /// From `.inserting` there is nothing to cancel: ⌘V has already gone into someone
    /// else's window, `DictationStopPolicy` knows this and the kernel ignores the request.
    /// The text appears in the person's document a moment later - so the message about
    /// the deleted recording would say the exact opposite of what he sees, and would
    /// overwrite a real warning about the insertion itself.
    func testScenario061() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        await harness.inserter.holdInsertions()
        monitor.onPress?()
        for _ in 0..<200 where state.dictationState != .inserting {
            if state.dictationState == .listening { monitor.onRelease?() }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.dictationState, .inserting)

        monitor.onEscape?()

        XCTAssertNotEqual(
            state.lastNotice?.message,
            "Dictation cancelled. The recording was deleted.",
            "The insertion was not cancelled, and the text is about to appear in the document"
        )

        await harness.inserter.releaseInsertions()
        for _ in 0..<200 where state.dictationState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"], "The text lands in someone else's window anyway")
    }

    // MARK: - Settings

    func testScenario036() async throws {
        try installModelMarker()
        let spokenTerm = "\u{0437}\u{0435}\u{0442}\u{0430}\u{043F}\u{0440}\u{0430}\u{0439}\u{043C}"
        harness.transcription.text = "open \(spokenTerm) port and check the indexes"
        let state = makeState()
        await state.refreshModelState()

        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        let last = try XCTUnwrap(state.lastDictation)
        XCTAssertTrue(last.insertedText.contains(spokenTerm))

        // The person corrected the term - the dictionary learned exactly this pair.
        let learned = state.learnCorrections(
            editedText: last.insertedText.replacingOccurrences(of: spokenTerm, with: "ZetaPrime")
        )

        XCTAssertEqual(learned, 1)
        XCTAssertTrue(state.replacements.contains { $0.spoken == spokenTerm && $0.written == "ZetaPrime" })

        // Repeating the same edit does not produce duplicates.
        XCTAssertEqual(state.learnCorrections(
            editedText: last.insertedText.replacingOccurrences(of: spokenTerm, with: "ZetaPrime")
        ), 0)
    }

    func testScenario038() {
        let state = makeState()

        XCTAssertFalse(
            state.learnFromEdits,
            """
            Training on edits rereads the contents of the field via Accessibility \
            ANOTHER application. While it's enabled by default, the promise "read exactly\
            bundle id - not screen, not content” is false. Only a person has the right to enable this.
            """
        )
    }

    func testScenario039() {
        let state = makeState()

        state.learnFromEdits = true
        XCTAssertTrue(harness.defaults.bool(forKey: AppState.learnFromEditsKey))

        // "Restart": new AppState with the same defaults.
        XCTAssertTrue(makeState().learnFromEdits, "A person's informed choices should not be reset")

        state.learnFromEdits = false
        XCTAssertFalse(makeState().learnFromEdits)
    }

    /// A turned off toggle switch must mean “the field is not read”, and not “read and kept silent”.
    ///
    /// The difference is visible only from the outside: the observer has no observable trace except
    /// the reference to the field itself. Therefore, we count the captures, not the result.
    func testScenario040() async throws {
        try installModelMarker()
        harness.transcription.text = "Open the post gerz"
        let state = makeState()
        state.learnFromEdits = false
        await state.refreshModelState()

        try await dictateOnce(state)

        XCTAssertEqual(
            harness.focusedField.captured, 0,
            "The toggle switch is turned off - the application does not have the right to look into someone else's field"
        )
    }

    /// Positive control for the previous test: without it it will pass
    /// broken wiring, where the field is never read.
    func testScenario041() async throws {
        try installModelMarker()
        harness.transcription.text = "Open the post gerz"
        let state = makeState()
        state.learnFromEdits = true
        await state.refreshModelState()

        try await dictateOnce(state)

        XCTAssertEqual(harness.focusedField.captured, 1)
    }

    /// One complete dictation: pressed, waited for recording, released, waited for insertion.
    private func dictateOnce(_ state: AppState) async throws {
        monitor.onPress?()
        for _ in 0..<40 where state.dictationState != .listening {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        monitor.onRelease?()
        for _ in 0..<200 where state.lastDictation == nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try XCTUnwrap(state.lastDictation)
    }

    func testScenario042() {
        let state = makeState()
        XCTAssertNil(state.recognitionLanguage, "Default - auto detection")

        state.recognitionLanguage = "en"
        XCTAssertEqual(harness.defaults.string(forKey: AppState.recognitionLanguageKey), "en")

        // "Restart": new AppState with the same defaults.
        let restarted = makeState()
        XCTAssertEqual(restarted.recognitionLanguage, "en")

        // Returning to autodetection removes the key rather than writing an empty string.
        restarted.recognitionLanguage = nil
        XCTAssertNil(harness.defaults.string(forKey: AppState.recognitionLanguageKey))
    }

    func testScenario043() {
        let state = makeState()

        state.hotkey = .leftControl

        XCTAssertEqual(monitor.hotkey, .leftControl)
        XCTAssertEqual(defaults.string(forKey: "hotkey"), "leftControl")
        XCTAssertEqual(makeState().hotkey, .leftControl)
    }

    func testScenario044() {
        defaults.set(1, forKey: "AppleFnUsageType")
        let state = makeState()

        XCTAssertNil(state.hotkeyWarning)

        state.hotkey = .fn

        XCTAssertNotNil(state.hotkeyWarning)
    }

    // MARK: - Dictionary

    func testScenario045() {
        let state = makeState()

        state.addReplacement(spoken: "Sentry", written: "Sentry")

        XCTAssertEqual(state.replacements.map(\.written), ["Sentry"])
        XCTAssertEqual(makeState().replacements.map(\.written), ["Sentry"])
    }

    func testScenario046() {
        let state = makeState()

        state.addReplacement(spoken: "   ", written: "Sentry")
        state.addReplacement(spoken: "sentry", written: " ")

        XCTAssertEqual(state.replacements, [])
    }

    /// An unread dictionary blocks the entire entry.
    ///
    /// Previously, it turned into an empty array, and the very first edit would overwrite
    /// the key to them: a person lost everything accumulated silently and irreversibly.
    func testScenario047() async {
        let broken = "{this is not json"
        defaults.set(Data(broken.utf8), forKey: "replacements")

        let state = makeState()
        XCTAssertFalse(state.isDictionaryEditable)
        XCTAssertNotNil(state.dictionaryProblem)

        state.addReplacement(spoken: "Sentry", written: "Sentry")

        XCTAssertEqual(state.replacements, [])
        XCTAssertEqual(
            defaults.data(forKey: "replacements").map { String(decoding: $0, as: UTF8.self) },
            broken,
            "the original data must remain in place"
        )
    }

    func testScenario048() async {
        defaults.set(Data("{this is not json".utf8), forKey: "replacements")

        _ = makeState()
        // The message is shown by the task, so we let it reach the overlay.
        try? await Task.sleep(for: .milliseconds(100))

        let notices = await overlay.notices
        XCTAssertTrue(notices.contains { $0.message.contains("replacement dictionary") })
    }

    func testScenario049() {
        let future = #"{"version": 99, "items": []}"#
        defaults.set(Data(future.utf8), forKey: "replacements")

        let state = makeState()
        state.addReplacement(spoken: "future", written: "Future")

        XCTAssertFalse(state.isDictionaryEditable)
        XCTAssertEqual(
            defaults.data(forKey: "replacements").map { String(decoding: $0, as: UTF8.self) },
            future
        )
    }

    func testScenario050() {
        let state = makeState()
        state.addReplacement(spoken: "Sentry", written: "Sentry")
        state.addReplacement(spoken: "deploy", written: "deploy")

        state.removeReplacements(at: IndexSet(integer: 0))

        XCTAssertEqual(state.replacements.map(\.written), ["deploy"])
        XCTAssertEqual(makeState().replacements.map(\.written), ["deploy"])
    }

    func testScenario062() async throws {
        try installModelMarker()
        harness.transcription.text = "\u{0412}\u{043A}\u{043B}\u{044E}\u{0447}\u{0438} \u{0444}\u{0438}\u{0447}\u{0435}\u{0440} \u{0444}\u{043B}\u{044D}\u{043A} \u{043D}\u{0430} staging"
        let state = makeState()
        XCTAssertTrue(state.replacements.isEmpty, "built-in vocabulary must not clutter personal replacements")
        await state.refreshModelState()

        try await dictateOnce(state)

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted.last, "\u{0412}\u{043A}\u{043B}\u{044E}\u{0447}\u{0438} feature flag \u{043D}\u{0430} staging")
    }

    func testScenario063() async throws {
        try installModelMarker()
        harness.transcription.text = "\u{0444}\u{0438}\u{0447}\u{0435}\u{0440} \u{0444}\u{043B}\u{044D}\u{043A}"
        let state = makeState()
        state.addReplacement(spoken: "\u{0444}\u{0438}\u{0447}\u{0435}\u{0440} \u{0444}\u{043B}\u{044D}\u{043A}", written: "launch switch")
        await state.refreshModelState()

        try await dictateOnce(state)

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted.last, "Launch switch", "a personal replacement wins over the built-in spelling")
    }

    func testScenario064() async throws {
        try installModelMarker()
        let state = makeState()
        await state.refreshModelState()

        try await dictateOnce(state)

        XCTAssertNotNil(state.lastSpeed, "performance diagnostics stay available in memory")
        let dismissCount = await overlay.dismissCount
        XCTAssertGreaterThan(dismissCount, 0, "successful insertion dismisses instead of showing a result banner")
    }

    // MARK: - Cleaning

    /// Records that survived an application crash are tidied up quietly:
    /// header repaired, moved to safekeeping, nothing announced. A broken
    /// last dictation already surfaced when it happened; a launch-time
    /// announcement with no action attached would be noise.
    func testScenario052() async throws {
        let paths = AppPaths(root: root)
        let orphan = try paths.takes().appending(path: "take-old.wav")
        try writeAbandonedTestWAV(to: orphan, sampleBytes: 32_000)

        _ = makeState()
        for _ in 0..<40 where recoveryFiles().isEmpty {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        let kept = recoveryFiles()
        XCTAssertEqual(kept.count, 1, "the take must move into safekeeping")
        let repaired = try Data(
            contentsOf: paths.audioRecovery().appending(path: XCTUnwrap(kept.first))
        )
        let payloadSize = repaired[40..<44].withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
        XCTAssertEqual(payloadSize, 32_000, "the interrupted WAV header must be repaired")
        let notices = await overlay.notices
        XCTAssertTrue(notices.isEmpty, "safekeeping is silent: \(notices.map(\.message))")
    }

    /// A leftover from a previous launch stays kept — silently.
    func testLeftoverRecordingIsNotAnnouncedOnEveryLaunch() async throws {
        let paths = AppPaths(root: root)
        let leftover = try paths.audioRecovery().appending(path: "recording-old.wav")
        try Data(repeating: 7, count: 64_000).write(to: leftover)

        let state = makeState()
        for _ in 0..<30 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: leftover.path),
            "a fresh leftover stays within the retention window"
        )
        let notices = await overlay.notices
        XCTAssertTrue(
            notices.isEmpty,
            "The past stays quiet at launch: \(notices.map(\.message))"
        )
        XCTAssertNil(state.lastNotice)
    }

    /// A fragment shorter than the recognition minimum does not survive launch.
    ///
    /// An accidental key press killed together with the app is not "a recording
    /// after a failure": the main path deletes such takes silently, and the
    /// import must behave the same.
    func testTooShortFragmentDoesNotBecomeALaunchError() async throws {
        let paths = AppPaths(root: root)
        let blip = try paths.takes().appending(path: "take-blip.wav")
        try writeAbandonedTestWAV(to: blip, sampleBytes: 3200)

        let state = makeState()
        for _ in 0..<30 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(recoveryFiles().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blip.path))
        let notices = await overlay.notices
        XCTAssertTrue(notices.isEmpty, "A fragment is not an event: \(notices.map(\.message))")
        XCTAssertNil(state.lastNotice)
    }
}

/// The saved text remains only in memory with Copy/Retry.
@MainActor
final class RecoveredFileTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws {
        harness = try AppHarness()
    }

    override func tearDown() async throws {
        harness.tearDown()
    }

    private func settle(_ iterations: Int = 30) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testScenario053() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertNil(state.recoveredText, "Nothing has been rescued yet, nothing to show")

        await harness.inserter.setError(.accessibilityPermissionDenied)

        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()

        XCTAssertEqual(state.recoveredText, "Ping test")
    }

    func testScenario054() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        XCTAssertNotNil(state.recoveredText)

        await harness.inserter.setError(nil)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onEscape?()
        await settle()

        XCTAssertEqual(state.recoveredText, "Ping test")
    }

    /// Failed-insert words join Recent Dictations at failure time.
    ///
    /// The single recovery slot is overwritten by the next failure; without
    /// this copy the first failure's words would silently vanish. This is
    /// also why the menu needs no Copy/Delete items for saved text: the words
    /// are copyable from Recent Dictations like any other dictation.
    func testScenario055() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()

        XCTAssertEqual(state.recoveredText, "Ping test")
        XCTAssertEqual(state.recentDictations.map(\.text), ["Ping test"])
    }

    /// Retrying and failing again must not fill the history with copies.
    func testFailedRetryDoesNotDuplicateHistory() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        XCTAssertEqual(state.recoveredText, "Ping test")

        state.retryRecoveredText()
        await settle()

        XCTAssertEqual(state.recoveredText, "Ping test", "the words stay recoverable")
        XCTAssertEqual(
            state.recentDictations.map(\.text), ["Ping test"],
            "repeat failures of the same words keep one history entry"
        )
    }

    /// A successful retry closes the recovery without double bookkeeping.
    func testSuccessfulRetryKeepsOneHistoryEntryAndClearsStaleProvenance() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        XCTAssertEqual(state.recoveredText, "Ping test")
        await harness.inserter.setError(nil)

        state.retryRecoveredText()
        await settle()

        XCTAssertNil(state.recoveredText)
        XCTAssertEqual(
            state.recentDictations.map(\.text), ["Ping test"],
            "the words entered history at failure time; success must not append again"
        )
        XCTAssertNil(
            state.lastDictation,
            "recovered text has no raw provenance — Copy Last as Spoken must not offer the previous dictation's words"
        )
        XCTAssertFalse(state.canCopyRawDictation)
    }

    func testScenario056() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        await harness.inserter.setError(nil)

        state.retryRecoveredText()
        state.retryRecoveredText()
        await settle()

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"])
        XCTAssertNil(state.recoveredText)
    }

    /// A successful new dictation supersedes an older insertion warning. The menu
    /// must not keep saying that the last dictation failed after text landed.
    func testScenario057() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        await harness.inserter.setError(.accessibilityPermissionDenied)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()
        XCTAssertEqual(state.recoveredText, "Ping test")

        await harness.inserter.setError(nil)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()

        XCTAssertNil(state.recoveredText)
        XCTAssertEqual(state.recentDictations.first?.text, "Ping test")
    }
}

/// Saved recognition language.
@MainActor
final class RecognitionLanguageTests: XCTestCase {
    func testScenario058() throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        harness.defaults.set("xx-not-a-language", forKey: AppState.recognitionLanguageKey)

        let state = harness.makeState()

        XCTAssertNil(
            state.recognitionLanguage,
            "Code that the engine doesn't know would drop every dictation and save WAV to the rescue"
        )
    }

    func testScenario059() throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        harness.defaults.set("ru", forKey: AppState.recognitionLanguageKey)

        let state = harness.makeState()

        XCTAssertEqual(state.recognitionLanguage, "ru")
    }
}

/// Editing the dictionary reaches the acoustic prompt without restarting.
@MainActor
final class VocabularyRebuildTests: XCTestCase {
    /// The engine that counts the reassemblies of the tooltip.
    private final class RebuildCountingEngine: ASREngineAdapting, VocabularyBoostCapable, @unchecked Sendable {
        private let lock = NSLock()
        private var _prepares = 0
        private var _modelLoads = 0
        private var _unloads = 0
        private var _lastTermCount = -1
        private var _delayNext = false
        private var _delayedStarts = 0
        var prepares: Int { lock.withLock { _prepares } }
        var modelLoads: Int { lock.withLock { _modelLoads } }
        var unloads: Int { lock.withLock { _unloads } }
        var lastTermCount: Int { lock.withLock { _lastTermCount } }
        var delayedStarts: Int { lock.withLock { _delayedStarts } }

        func delayNextRebuild() { lock.withLock { _delayNext = true } }

        func loadModels(from directory: URL) async throws {
            lock.withLock { _modelLoads += 1 }
        }
        func transcribe(samples: [Float]) async throws -> ASRResult {
            ASRResult(text: "", audioDuration: 0, processingDuration: 0)
        }
        func transcribe(samples: [Float], languageHint: String?) async throws -> ASRResult {
            ASRResult(text: "", audioDuration: 0, processingDuration: 0)
        }
        // A real unload drops the acoustic boost together with the weights —
        // the marker resets so a reload must re-issue the vocabulary to pass.
        func unload() async {
            lock.withLock {
                _unloads += 1
                _lastTermCount = -1
            }
        }
        func loadVocabularyModels(from directory: URL, boost: VocabularyBoost) async throws {
            let shouldDelay = lock.withLock {
                _prepares += 1
                let value = _delayNext
                _delayNext = false
                if value { _delayedStarts += 1 }
                return value
            }
            if shouldDelay { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            lock.withLock {
                _lastTermCount = boost.terms.count
            }
        }
    }

    func testScenario060() async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        try harness.installModelMarker()
        let engine = RebuildCountingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        //Wait for warm-up - the first preparation of the prompter occurs there.
        for _ in 0..<400 where !state.isEngineReady {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.isEngineReady, "Warming must take place")
        let after = engine.prepares

        state.addReplacement(spoken: "Sentry", written: "Sentry")

        for _ in 0..<400 where engine.prepares == after {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(
            engine.prepares, after,
            "Text replacement works immediately - acoustics has no right to wait for a restart"
        )
    }

    func testRapidDictionaryEditsLeaveTheNewestAcousticSnapshotInstalled() async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        try harness.installModelMarker()
        let engine = RebuildCountingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        for _ in 0..<400 where !state.isEngineReady {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        let baseline = engine.lastTermCount
        engine.delayNextRebuild()

        state.addReplacement(spoken: "alpha spoken", written: "AlphaCanonical")
        for _ in 0..<200 where engine.delayedStarts == 0 { await Task.yield() }
        state.addReplacement(spoken: "beta spoken", written: "BetaCanonical")

        for _ in 0..<400 where engine.lastTermCount != baseline + 2 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(engine.lastTermCount, baseline + 2, "an older rebuild completed after the newest edit")
        let notices = await harness.overlay.notices
        XCTAssertFalse(
            notices.contains { $0.message.contains("acoustic boosting") },
            "cancellation of an obsolete rebuild must stay silent"
        )
    }

    /// The full residency round trip: critical memory pressure gives the
    /// weights back, dictation stays enabled, and the press-time reload
    /// restores BOTH the weights and the boosted vocabulary. A dictionary
    /// term must survive the trip — a reload that forgets the boost would
    /// silently degrade recognition of exactly the words the person cared
    /// enough to teach.
    func testBoostedTermSurvivesPressureUnloadAndPressReload() async throws {
        let harness = try AppHarness()
        defer { harness.tearDown() }
        try harness.installModelMarker()
        let engine = RebuildCountingEngine()
        harness.warmUpEngine = engine
        let state = harness.makeState()

        for _ in 0..<400 where !state.isEngineReady {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.isEngineReady)
        XCTAssertEqual(engine.modelLoads, 1, "the first warm-up loads the weights once")

        state.addReplacement(spoken: "open ramble term", written: "OpenRambleTerm")
        let boosted = engine.lastTermCount + 1
        for _ in 0..<400 where engine.lastTermCount != boosted {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(engine.lastTermCount, boosted)

        state.registerMemoryPressure(.critical)
        for _ in 0..<400 where state.isEngineReady {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(state.isEngineReady, "critical pressure on an idle engine must release the memory")
        XCTAssertEqual(engine.unloads, 1)
        XCTAssertTrue(
            state.isDictationReady,
            "an unloaded engine must not block the press — the reload rides under the voice"
        )

        state.warmEngineUnderVoiceIfCold()
        for _ in 0..<400 where !state.isEngineReady {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.isEngineReady, "the press-time reload must complete")
        XCTAssertEqual(engine.modelLoads, 2, "the reload really reloads the weights")
        XCTAssertEqual(
            engine.lastTermCount, boosted,
            "the boosted term survives the unload/reload round trip"
        )
    }
}

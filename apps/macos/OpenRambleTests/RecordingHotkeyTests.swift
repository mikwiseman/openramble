import AppKit
import Carbon.HIToolbox
import XCTest

/// The shortcut that starts and stops a recording from anywhere on the Mac.
@MainActor
final class RecordingHotkeyTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private let rKey = UInt16(kVK_ANSI_R)

    /// A fresh app already has a recording shortcut, so the first meeting
    /// does not require a trip through Settings.
    func testTheDefaultIsShiftCommandR() {
        let state = harness.makeState()
        XCTAssertEqual(
            state.recordingShortcut,
            KeyCombination(keyCode: rKey, modifiers: [.command, .shift])
        )
        XCTAssertEqual(state.recordingShortcut, SettingsDefaults.recordingShortcut)
        XCTAssertEqual(state.recordingShortcut?.displayString, "⇧⌘R")
    }

    /// An empty value is Off, and a missing key is the default — those two
    /// must not collapse into each other, or reverting and clearing become
    /// the same action.
    func testClearingItAndLeavingItUntouchedAreDifferent() {
        harness.defaults.set("", forKey: "recordingShortcut")
        XCTAssertNil(harness.makeState().recordingShortcut)

        harness.defaults.removeObject(forKey: "recordingShortcut")
        XCTAssertEqual(
            harness.makeState().recordingShortcut,
            SettingsDefaults.recordingShortcut
        )
    }

    /// It comes back after a relaunch, including Off.
    func testItSurvivesARelaunch() {
        let shortcut = KeyCombination(keyCode: rKey, modifiers: [.command, .option])
        harness.defaults.set(shortcut.rawValue, forKey: "recordingShortcut")
        XCTAssertEqual(harness.makeState().recordingShortcut, shortcut)
    }

    /// The chosen shortcut reaches the watcher, and clearing it takes the
    /// shortcut back off the keyboard.
    func testTheWatcherFollowsTheSetting() async {
        harness.permissions.accessibilityGranted = true
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()

        XCTAssertEqual(harness.recordingMonitor.shortcut, SettingsDefaults.recordingShortcut)
        XCTAssertTrue(harness.recordingMonitor.isRunning)

        state.recordingShortcut = nil
        XCTAssertFalse(harness.recordingMonitor.isRunning)
    }

    /// Without Accessibility there is nothing to listen with.
    func testTheWatcherStaysDownWithoutAccessibility() async {
        harness.permissions.accessibilityGranted = false
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()
        XCTAssertFalse(harness.recordingMonitor.isRunning)
        XCTAssertEqual(state.recordingShortcut, SettingsDefaults.recordingShortcut)
    }

    /// Press starts a recording; press again stops it. The window is not
    /// involved — the menu-bar badge is the confirmation.
    func testPressStartsAndPressAgainStops() async throws {
        harness.permissions.microphoneGranted = true
        harness.permissions.accessibilityGranted = true
        harness.defaults.set(true, forKey: AppState.systemAudioDeclinedKey)
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()

        harness.recordingMonitor.onPress?()
        try await waitUntil { state.meetingState == .recording }
        XCTAssertFalse(state.isSystemAudioIntroPresented)

        harness.recordingMonitor.onPress?()
        try await waitUntil { state.meetingState == .idle }
    }

    /// The first recording still explains itself. The sheet lives on the
    /// Recordings window, so that press is the one case that must open it.
    func testTheFirstPressPresentsTheIntroInsteadOfStarting() throws {
        harness.permissions.microphoneGranted = true
        let state = harness.makeState()
        guard state.systemAudioMode == .enabled else {
            throw XCTSkip("this Mac cannot record what it plays")
        }
        harness.recordingMonitor.onPress?()
        XCTAssertTrue(state.isSystemAudioIntroPresented)
        XCTAssertEqual(state.meetingState, .idle)
        XCTAssertEqual(harness.meetingCapture.startCount, 0)
    }
}

import XCTest

/// The second key: the one that puts the last dictation back on the clipboard.
///
/// Everything here is about the one way this feature can hurt: two watchers on
/// a single physical key. Both would fire from one press, and the dictation the
/// person actually wanted would be competing with a clipboard write.
@MainActor
final class CopyHotkeyTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    /// Nobody gets a second global key without asking for one.
    func testScenario001() {
        let state = harness.makeState()
        XCTAssertNil(state.copyHotkey)
        XCTAssertFalse(state.copiesToClipboard)
    }

    /// The dictation key cannot also be the copy key.
    func testScenario002() {
        let state = harness.makeState()
        state.hotkey = .rightCommand
        state.copyHotkey = .rightCommand
        XCTAssertNil(state.copyHotkey)
    }

    /// Moving dictation onto the copy key gives dictation the key, not both.
    func testScenario003() {
        let state = harness.makeState()
        state.hotkey = .rightCommand
        state.copyHotkey = .rightOption
        XCTAssertEqual(state.copyHotkey, .rightOption)

        state.hotkey = .rightOption
        XCTAssertNil(state.copyHotkey)
    }

    /// A collision written to disk by an older build does not come back at launch.
    func testScenario004() {
        harness.defaults.set("rightOption", forKey: "hotkey")
        harness.defaults.set("rightOption", forKey: "copyHotkey")
        XCTAssertNil(harness.makeState().copyHotkey)
    }

    /// The chosen key reaches the watcher, and turning it off takes it back.
    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testScenario005() async {
        harness.permissions.accessibilityGranted = true
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()

        state.copyHotkey = .leftControl
        XCTAssertEqual(harness.copyMonitor.hotkey, .leftControl)
        XCTAssertTrue(harness.copyMonitor.isRunning)

        state.copyHotkey = nil
        XCTAssertFalse(harness.copyMonitor.isRunning)
    }

    /// Without Accessibility there is nothing to listen with, and starting the
    /// watcher would only fail quietly.
    func testScenario006() async {
        harness.permissions.accessibilityGranted = false
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()

        state.copyHotkey = .leftControl
        XCTAssertFalse(harness.copyMonitor.isRunning)
    }

    /// Pressing it with nothing dictated says so rather than copying silence.
    func testScenario007() {
        let state = harness.makeState()
        state.copyLastDictation()
        XCTAssertNil(state.lastDictation)
    }
}

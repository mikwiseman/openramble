import XCTest

/// The revert arrow and the value the app starts with must be the same value.
@MainActor
final class SettingsDefaultsTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    /// A fresh app is already at its defaults, so every arrow starts inactive.
    ///
    /// This is the whole contract of the arrow: if a default declared here
    /// differed from what the app actually reads at launch, the arrow would
    /// move the setting somewhere the person never chose — and it would look
    /// like a reset while doing it.
    func testScenario001() {
        let state = harness.makeState()
        XCTAssertEqual(state.hotkey, SettingsDefaults.hotkey)
        XCTAssertEqual(state.copyShortcut, SettingsDefaults.copyShortcut)
        XCTAssertEqual(state.soundsEnabled, SettingsDefaults.soundsEnabled)
        XCTAssertEqual(state.copiesToClipboard, SettingsDefaults.copiesToClipboard)
        XCTAssertEqual(state.appendsTrailingSpace, SettingsDefaults.appendsTrailingSpace)
        XCTAssertEqual(state.overlayPlacement, SettingsDefaults.overlayPlacement)
        XCTAssertEqual(state.appearance, SettingsDefaults.appearance)
    }

    /// Changing a setting and reverting it returns exactly the start value.
    func testScenario002() {
        let state = harness.makeState()
        state.appendsTrailingSpace = true
        state.overlayPlacement = .bottom
        XCTAssertNotEqual(state.appendsTrailingSpace, SettingsDefaults.appendsTrailingSpace)

        state.appendsTrailingSpace = SettingsDefaults.appendsTrailingSpace
        state.overlayPlacement = SettingsDefaults.overlayPlacement
        XCTAssertEqual(state.appendsTrailingSpace, SettingsDefaults.appendsTrailingSpace)
        XCTAssertEqual(state.overlayPlacement, SettingsDefaults.overlayPlacement)
    }

    /// The theme survives a relaunch, or it is not a setting.
    func testScenario003() {
        harness.defaults.set("dark", forKey: "appearance")
        XCTAssertEqual(harness.makeState().appearance, .dark)
    }
}

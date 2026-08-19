import XCTest

/// Choosing a microphone, and what happens when it is gone.
@MainActor
final class AudioInputDevicesTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    /// The default is the system's, which is what the app did before this
    /// setting existed and what almost everyone wants.
    func testScenario001() {
        let state = harness.makeState()
        XCTAssertNil(state.inputDeviceUID)
        XCTAssertNil(state.preferredInputDeviceID)
        XCTAssertNil(state.inputDeviceNotice)
    }

    /// Enumeration answers with real devices on a real Mac, and every one it
    /// reports can be resolved back — a device in the list that cannot be
    /// selected would be a picker entry that silently does nothing.
    func testScenario002() {
        for device in AudioInputDevices.available() {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertNotNil(
                AudioInputDevices.deviceID(forUID: device.uid),
                "listed \(device.name) but could not resolve it"
            )
        }
    }

    /// A microphone that is not on this machine says so rather than being
    /// swapped in silence. Someone who chose a headset and quietly got the
    /// laptop lid would only find out from the transcript.
    func testScenario003() {
        let state = harness.makeState()
        state.inputDeviceUID = "a-device-that-is-not-here"
        XCTAssertNil(state.preferredInputDeviceID)
        XCTAssertNotNil(state.inputDeviceNotice)
    }

    /// It survives a relaunch, or it is not a setting.
    func testScenario004() {
        harness.defaults.set("some-uid", forKey: "inputDeviceUID")
        XCTAssertEqual(harness.makeState().inputDeviceUID, "some-uid")
    }
}

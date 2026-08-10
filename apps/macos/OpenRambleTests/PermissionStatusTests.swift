import XCTest

/// The permission line is the only thing a person does in onboarding
/// with your hands.
final class PermissionStatusTests: XCTestCase {
    private func microphone(granted: Bool) -> PermissionStatus {
        PermissionStatus(title: "Microphone", detail: "To hear your speech.", granted: granted)
    }

    func testScenario001() {
        let status = microphone(granted: false)

        XCTAssertEqual(status.actionTitle, "Grant")
        XCTAssertEqual(status.accessibilityValue, "Permission not granted")
    }

    /// The issued button resolution does not show: there is nothing more to press.
    func testScenario002() {
        let status = microphone(granted: true)

        XCTAssertNil(status.actionTitle)
        XCTAssertNil(status.actionAccessibilityLabel)
        XCTAssertEqual(status.accessibilityValue, "Permission granted")
    }

    /// The VoiceOver checkmark itself doesn't say anything.
    func testScenario003() {
        XCTAssertNotEqual(
            microphone(granted: true).accessibilityValue,
            microphone(granted: false).accessibilityValue
        )
    }

    /// Both buttons on the screen are called "Issue".
    ///
    /// Without a permission name, a blind person hears two identical buttons and does not
    /// knows which one is which.
    func testScenario004() {
        let microphone = microphone(granted: false)
        let accessibility = PermissionStatus(
            title: "Accessibility",
            detail: "To hear the hotkey.",
            granted: false
        )

        XCTAssertEqual(microphone.actionTitle, accessibility.actionTitle)
        XCTAssertEqual(microphone.actionAccessibilityLabel, "Grant access: Microphone")
        XCTAssertEqual(accessibility.actionAccessibilityLabel, "Grant access: Accessibility")
        XCTAssertNotEqual(microphone.actionAccessibilityLabel, accessibility.actionAccessibilityLabel)
    }

    func testScenario005() {
        XCTAssertEqual(
            microphone(granted: false).accessibilityLabel,
            "Microphone. To hear your speech."
        )
    }


    func testScenario006() {
        let status = PermissionStatus.accessibility(
            state: .restartRequired,
            detail: "To hear the hotkey."
        )

        XCTAssertEqual(status.actionTitle, "Relaunch")
        XCTAssertEqual(status.accessibilityValue, "App relaunch required")
    }

    func testScenario007() {
        let status = PermissionStatus.accessibility(
            state: .repairRequired,
            detail: "To hear the hotkey."
        )

        XCTAssertEqual(status.actionTitle, "Repair")
        XCTAssertEqual(status.accessibilityValue, "The system permission entry needs repair")
    }

    func testScenario008() {
        let status = PermissionStatus.accessibility(
            state: .repairing,
            detail: "To hear the hotkey."
        )

        XCTAssertNil(status.actionTitle)
        XCTAssertEqual(status.accessibilityValue, "Repairing the permission")
    }
}

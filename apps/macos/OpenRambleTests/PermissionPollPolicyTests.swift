import XCTest

/// How often to ask the system about permissions.
///
/// The only work the application does is when it is not touched.
final class PermissionPollPolicyTests: XCTestCase {
    func testScenario001() {
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: false, microphoneGranted: true, base: 1),
            1
        )
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: true, microphoneGranted: false, base: 1),
            1
        )
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: false, microphoneGranted: false, base: 1),
            1
        )
    }

    /// Accessibility revoke does not deliver event: interval is always <= 2 seconds.
    func testScenario002() {
        let interval = PermissionPollPolicy.interval(
            accessibilityGranted: true,
            microphoneGranted: true,
            base: 1
        )

        XCTAssertEqual(interval, 1)
        XCTAssertLessThanOrEqual(interval, 2)
    }

    /// But we don’t stop completely: permission is revoked in the system settings, and with
    /// With access revoked, the hotkey silently stops working.
    func testScenario003() {
        XCTAssertGreaterThan(
            PermissionPollPolicy.interval(accessibilityGranted: true, microphoneGranted: true, base: 1),
            0
        )
    }

    /// The main decision of this type, recorded by checking: issued permissions for
    /// polling frequency is not affected at all. Slowing down "when everything is fine" sounds
    /// reasonable and would be a mistake - revoking access does not send events, but
    /// an application with Accessibility revoked appears intact and silently fails
    /// works. If someone returns the dependence on flags, they will fall here.
    func testScenario004() {
        let combinations = [(true, true), (true, false), (false, true), (false, false)]

        let intervals = combinations.map { accessibility, microphone in
            PermissionPollPolicy.interval(
                accessibilityGranted: accessibility,
                microphoneGranted: microphone,
                base: 1
            )
        }

        XCTAssertEqual(Set(intervals).count, 1, "the frequency must be the same for all four cases: \(intervals)")
    }

    /// The base is more than the ceiling is trimmed: the promise “no later than two seconds”
    /// holds even if outside asked to poll once a minute.
    func testScenario005() {
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: true, microphoneGranted: true, base: 60),
            2
        )
    }

    func testScenario006() {
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: true, microphoneGranted: true, base: 0),
            0
        )
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: false, microphoneGranted: false, base: 0),
            0
        )
    }
}

import XCTest

/// Как часто спрашивать систему про разрешения.
///
/// Единственная работа, которую приложение делает, когда его не трогают.
final class PermissionPollPolicyTests: XCTestCase {
    func testПокаЧегоТоНеХватаетСпрашиваемЧасто() {
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

    /// Accessibility revoke не доставляет event: интервал всегда <= 2 секунд.
    func testКогдаВсёВыданоRevokeВсёРавноЗамечаетсяБыстро() {
        let interval = PermissionPollPolicy.interval(
            accessibilityGranted: true,
            microphoneGranted: true,
            base: 1
        )

        XCTAssertEqual(interval, 1)
        XCTAssertLessThanOrEqual(interval, 2)
    }

    /// Но не прекращаем совсем: разрешение отзывают в системных настройках, и с
    /// отозванным доступом горячая клавиша молча перестаёт работать.
    func testОпросНеПрекращаетсяНикогда() {
        XCTAssertGreaterThan(
            PermissionPollPolicy.interval(accessibilityGranted: true, microphoneGranted: true, base: 1),
            0
        )
    }

    func testНулевоеОснованиеВыключаетОпросСовсем() {
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

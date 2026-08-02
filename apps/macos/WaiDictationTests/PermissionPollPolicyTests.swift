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

    /// Всё выдано — ждать больше нечего.
    func testКогдаВсёВыданоСпрашиваемРедко() {
        let interval = PermissionPollPolicy.interval(
            accessibilityGranted: true,
            microphoneGranted: true,
            base: 1
        )

        XCTAssertEqual(interval, 30)
        XCTAssertGreaterThan(interval, 1, "в покое опрос обязан замедляться")
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

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

    /// Главное решение этого типа, записанное проверкой: выданные разрешения на
    /// частоту опроса не влияют вообще. Замедление «когда всё хорошо» звучит
    /// разумно и было бы ошибкой — отзыв доступа не присылает события, а
    /// приложение с отозванным Accessibility выглядит целым и молча не
    /// работает. Если кто-то вернёт зависимость от флагов, упадёт здесь.
    func testВыданныеРазрешенияНеМеняютЧастотуОпроса() {
        let combinations = [(true, true), (true, false), (false, true), (false, false)]

        let intervals = combinations.map { accessibility, microphone in
            PermissionPollPolicy.interval(
                accessibilityGranted: accessibility,
                microphoneGranted: microphone,
                base: 1
            )
        }

        XCTAssertEqual(Set(intervals).count, 1, "частота обязана быть одна на все четыре случая: \(intervals)")
    }

    /// Основание больше потолка урезается: обещание «не позже двух секунд»
    /// держится даже если снаружи попросили опрашивать раз в минуту.
    func testБольшоеОснованиеУрезаетсяДоДвухСекунд() {
        XCTAssertEqual(
            PermissionPollPolicy.interval(accessibilityGranted: true, microphoneGranted: true, base: 60),
            2
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

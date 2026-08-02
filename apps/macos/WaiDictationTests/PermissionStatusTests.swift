import XCTest

/// Строка разрешения — она же единственное, что человек делает в онбординге
/// руками.
final class PermissionStatusTests: XCTestCase {
    private func microphone(granted: Bool) -> PermissionStatus {
        PermissionStatus(title: "Микрофон", detail: "Чтобы услышать вашу речь.", granted: granted)
    }

    func testНевыданноеРазрешениеПредлагаетКнопку() {
        let status = microphone(granted: false)

        XCTAssertEqual(status.actionTitle, "Выдать")
        XCTAssertEqual(status.accessibilityValue, "Разрешение не выдано")
    }

    /// Выданное разрешение кнопки не показывает: нажимать больше нечего.
    func testВыданноеРазрешениеКнопкиНеПоказывает() {
        let status = microphone(granted: true)

        XCTAssertNil(status.actionTitle)
        XCTAssertNil(status.actionAccessibilityLabel)
        XCTAssertEqual(status.accessibilityValue, "Разрешение выдано")
    }

    /// Галочка сама по себе VoiceOver ничего не говорит.
    func testСостояниеРазрешенияЧитаетсяСловами() {
        XCTAssertNotEqual(
            microphone(granted: true).accessibilityValue,
            microphone(granted: false).accessibilityValue
        )
    }

    /// Обе кнопки на экране называются «Выдать».
    ///
    /// Без имени разрешения незрячий человек слышит две одинаковые кнопки и не
    /// знает, какая из них какая.
    func testКнопкиРазныхРазрешенийРазличимыНаСлух() {
        let microphone = microphone(granted: false)
        let accessibility = PermissionStatus(
            title: "Универсальный доступ",
            detail: "Чтобы услышать горячую клавишу.",
            granted: false
        )

        XCTAssertEqual(microphone.actionTitle, accessibility.actionTitle)
        XCTAssertEqual(microphone.actionAccessibilityLabel, "Выдать разрешение: Микрофон")
        XCTAssertEqual(accessibility.actionAccessibilityLabel, "Выдать разрешение: Универсальный доступ")
        XCTAssertNotEqual(microphone.actionAccessibilityLabel, accessibility.actionAccessibilityLabel)
    }

    func testНазваниеИПояснениеЧитаютсяВместе() {
        XCTAssertEqual(
            microphone(granted: false).accessibilityLabel,
            "Микрофон. Чтобы услышать вашу речь."
        )
    }
}

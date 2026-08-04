import XCTest

/// Строка разрешения — она же единственное, что человек делает в онбординге
/// руками.
final class PermissionStatusTests: XCTestCase {
    private func microphone(granted: Bool) -> PermissionStatus {
        PermissionStatus(title: "Microphone", detail: "To hear your speech.", granted: granted)
    }

    func testНевыданноеРазрешениеПредлагаетКнопку() {
        let status = microphone(granted: false)

        XCTAssertEqual(status.actionTitle, "Grant")
        XCTAssertEqual(status.accessibilityValue, "Permission not granted")
    }

    /// Выданное разрешение кнопки не показывает: нажимать больше нечего.
    func testВыданноеРазрешениеКнопкиНеПоказывает() {
        let status = microphone(granted: true)

        XCTAssertNil(status.actionTitle)
        XCTAssertNil(status.actionAccessibilityLabel)
        XCTAssertEqual(status.accessibilityValue, "Permission granted")
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
            title: "Accessibility",
            detail: "To hear the hotkey.",
            granted: false
        )

        XCTAssertEqual(microphone.actionTitle, accessibility.actionTitle)
        XCTAssertEqual(microphone.actionAccessibilityLabel, "Grant access: Microphone")
        XCTAssertEqual(accessibility.actionAccessibilityLabel, "Grant access: Accessibility")
        XCTAssertNotEqual(microphone.actionAccessibilityLabel, accessibility.actionAccessibilityLabel)
    }

    func testНазваниеИПояснениеЧитаютсяВместе() {
        XCTAssertEqual(
            microphone(granted: false).accessibilityLabel,
            "Microphone. To hear your speech."
        )
    }


    func testAccessibilityПослеВозвратаПредлагаетПерезапуск() {
        let status = PermissionStatus.accessibility(
            state: .restartRequired,
            detail: "To hear the hotkey."
        )

        XCTAssertEqual(status.actionTitle, "Relaunch")
        XCTAssertEqual(status.accessibilityValue, "App relaunch required")
    }

    func testAccessibilityСоСтаройЗаписьюПредлагаетИсправление() {
        let status = PermissionStatus.accessibility(
            state: .repairRequired,
            detail: "To hear the hotkey."
        )

        XCTAssertEqual(status.actionTitle, "Repair")
        XCTAssertEqual(status.accessibilityValue, "The system permission entry needs repair")
    }

    func testAccessibilityВоВремяRepairБлокируетПовторнуюКоманду() {
        let status = PermissionStatus.accessibility(
            state: .repairing,
            detail: "To hear the hotkey."
        )

        XCTAssertNil(status.actionTitle)
        XCTAssertEqual(status.accessibilityValue, "Repairing the permission")
    }
}

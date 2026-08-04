import XCTest

final class FnKeyUsageTests: XCTestCase {
    func testЗначенияЧитаютсяИзНастройкиСистемы() {
        XCTAssertEqual(FnKeyUsage(rawValue: nil), .systemDefault)
        XCTAssertEqual(FnKeyUsage(rawValue: 0), .doNothing)
        XCTAssertEqual(FnKeyUsage(rawValue: 1), .changeInputSource)
        XCTAssertEqual(FnKeyUsage(rawValue: 2), .showEmoji)
        XCTAssertEqual(FnKeyUsage(rawValue: 3), .startDictation)
        XCTAssertEqual(FnKeyUsage(rawValue: 7), .unknown(7))
    }

    func testНезнакомоеЗначениеСчитаетсяЗанятым() {
        // Помолчать здесь дороже, чем предупредить лишний раз: система могла
        // завести новое действие, а человек будет думать, что сломались мы.
        XCTAssertTrue(FnKeyUsage.unknown(9).isTakenBySystem)
        XCTAssertTrue(FnKeyUsage.systemDefault.isTakenBySystem)
        XCTAssertFalse(FnKeyUsage.doNothing.isTakenBySystem)
    }

    func testДляОстальныхКлавишПредупрежденийНет() {
        for hotkey in [DictationHotkey.rightCommand, .rightOption, .leftControl] {
            XCTAssertNil(HotkeyAdvice.warning(for: hotkey, fnUsage: .changeInputSource))
            XCTAssertNil(HotkeyAdvice.warning(for: hotkey, fnUsage: .startDictation))
        }
    }

    /// Fn занята системой — диктовка и системное действие сработают вместе.
    func testFnЗанятаяСистемойДаётПредупреждениеСНазваниемДействия() throws {
        let warning = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .changeInputSource))
        XCTAssertTrue(warning.contains("input source switching"))

        let dictation = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .startDictation))
        XCTAssertTrue(dictation.contains("Apple's built-in dictation"))

        let emoji = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .showEmoji))
        XCTAssertTrue(emoji.contains("the emoji panel"))
    }

    func testБезНастройкиПросимПроверитьЕё() throws {
        let warning = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .systemDefault))
        XCTAssertTrue(warning.contains("Keyboard"))
    }

    /// Даже со свободной Fn предупреждение остаётся.
    ///
    /// На внешней клавиатуре без 🌐 — а это обычный случай для Mac mini и
    /// Studio — диктовка не запустится вовсе, и понять почему будет неоткуда.
    func testСвободнаяFnВсёРавноПредупреждаетПроВнешнююКлавиатуру() throws {
        let warning = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .doNothing))
        XCTAssertTrue(warning.contains("external keyboard"))
    }
}

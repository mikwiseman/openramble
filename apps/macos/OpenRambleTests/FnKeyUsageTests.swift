import XCTest

final class FnKeyUsageTests: XCTestCase {
    func testScenario001() {
        XCTAssertEqual(FnKeyUsage(rawValue: nil), .systemDefault)
        XCTAssertEqual(FnKeyUsage(rawValue: 0), .doNothing)
        XCTAssertEqual(FnKeyUsage(rawValue: 1), .changeInputSource)
        XCTAssertEqual(FnKeyUsage(rawValue: 2), .showEmoji)
        XCTAssertEqual(FnKeyUsage(rawValue: 3), .startDictation)
        XCTAssertEqual(FnKeyUsage(rawValue: 7), .unknown(7))
    }

    func testScenario002() {
        // To remain silent here is more expensive than to warn again: the system could
        // start a new action, and the person will think that we are broken.
        XCTAssertTrue(FnKeyUsage.unknown(9).isTakenBySystem)
        XCTAssertTrue(FnKeyUsage.systemDefault.isTakenBySystem)
        XCTAssertFalse(FnKeyUsage.doNothing.isTakenBySystem)
    }

    func testScenario003() {
        for hotkey in [DictationHotkey.rightCommand, .rightOption, .leftControl] {
            XCTAssertNil(HotkeyAdvice.warning(for: hotkey, fnUsage: .changeInputSource))
            XCTAssertNil(HotkeyAdvice.warning(for: hotkey, fnUsage: .startDictation))
        }
    }

    /// Fn is occupied by the system - dictation and system action will work together.
    func testScenario004() throws {
        let warning = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .changeInputSource))
        XCTAssertTrue(warning.contains("input source switching"))

        let dictation = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .startDictation))
        XCTAssertTrue(dictation.contains("Apple's built-in dictation"))

        let emoji = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .showEmoji))
        XCTAssertTrue(emoji.contains("the emoji panel"))
    }

    func testScenario005() throws {
        let warning = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .systemDefault))
        XCTAssertTrue(warning.contains("Keyboard"))
    }

    /// Even with free Fn, the warning remains.
    ///
    /// On an external keyboard without 🌐 - and this is a common case for Mac mini and
    /// Studio - dictation will not start at all, and there will be no way to understand why.
    func testScenario006() throws {
        let warning = try XCTUnwrap(HotkeyAdvice.warning(for: .fn, fnUsage: .doNothing))
        XCTAssertTrue(warning.contains("external keyboard"))
    }
}

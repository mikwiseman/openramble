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

/// Every dictation key must be its own key.
@MainActor
final class DictationHotkeySideBitTests: XCTestCase {
    /// Two keys sharing a side bit would answer to each other: holding the
    /// left Command would start dictation bound to the right one, and the
    /// release of either would stop it. The general `.command` flag cannot
    /// tell them apart — only these bits can — so a duplicate here is a key
    /// that silently does someone else's job.
    func testEverySideBitIsDistinct() {
        var seen: [UInt: DictationHotkey] = [:]
        for key in DictationHotkey.allCases {
            if let clash = seen[key.sideMask] {
                XCTFail("\(key) and \(clash) share side bit \(String(key.sideMask, radix: 16))")
            }
            seen[key.sideMask] = key
        }
        XCTAssertEqual(seen.count, DictationHotkey.allCases.count)
    }

    /// A key held alone starts dictation; the same key inside a chord does not.
    /// Both halves matter for the newly added left-hand modifiers, which are
    /// the ones people actually build shortcuts from.
    func testAChordIsNotAHold() {
        for key in DictationHotkey.allCases where key != .fn {
            XCTAssertTrue(
                key.isExclusivelyPressed(in: key.sideMask | key.kindMaskForTests),
                "\(key) held alone must count"
            )
            // The same key with Shift added is the start of a shortcut.
            let withShift = key.sideMask | key.kindMaskForTests
                | NSEvent.ModifierFlags.shift.rawValue
            XCTAssertFalse(
                key.isExclusivelyPressed(in: withShift),
                "\(key) inside a chord must not start dictation"
            )
        }
    }
}

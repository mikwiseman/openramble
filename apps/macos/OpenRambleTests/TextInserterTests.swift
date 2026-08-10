import AppKit
import Carbon.HIToolbox
import DictationCore
import XCTest

final class TextInserterTests: XCTestCase {
    private var log: CallLog!
    private var system: FakeInputSystem!
    private var pasteboard: FakePasteboard!
    private var inserter: TextInserter!

    private let target = TargetApplication(
        bundleIdentifier: "com.apple.TextEdit",
        processIdentifier: 4242,
        localizedName: "TextEdit"
    )

    override func setUp() {
        log = CallLog()
        system = FakeInputSystem(log: log)
        pasteboard = FakePasteboard(log: log)
        inserter = TextInserter(system: system, pasteboard: pasteboard, restoreDelay: .zero)
        system.setFrontmost(target)
    }

    // MARK: - Failures before writing to buffer

    /// Protected input: password field, terminal with keyboard protection.
    ///
    /// Not a failure, but a normal situation - and the buffer cannot be touched.
    func testScenario001() async {
        system.setSecureInput(true)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.secureInputActive
        )
        XCTAssertEqual(pasteboard.writtenTexts, [])
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testScenario002() async {
        system.setTrusted(false)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.accessibilityPermissionDenied
        )
        XCTAssertEqual(pasteboard.writtenTexts, [])
    }

    /// The receiving application was closed while recognition was in progress.
    ///
    /// You cannot insert “somewhere”: there is now an arbitrary window ahead, up to
    /// to someone else's password field. The buffer must remain untouched - otherwise
    /// a person loses what was copied where the pasting did not take place anyway.
    func testScenario003() async {
        system.setActivateResult(false)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.targetUnavailable
        )
        XCTAssertEqual(pasteboard.writtenTexts, [])
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testScenario004() async throws {
        try await inserter.insert("", into: target)

        XCTAssertEqual(pasteboard.writtenTexts, [])
        XCTAssertEqual(system.postedKeys.count, 0)
        XCTAssertEqual(log.entries, [])
    }

    // MARK: - Order

    func testScenario005() async throws {
        try await inserter.insert("hello", into: target)

        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }

    func testScenario006() async {
        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: nil),
            expected: TextInsertionError.targetUnavailable
        )
        XCTAssertEqual(log.entries, [])
    }

    // MARK: - Waiting for modifiers

    /// Fn must be in the wait mask.
    ///
    /// This is a hotkey available in settings. Without `.maskSecondaryFn`
    /// the wait would end while the key was still being held, and ⌘V would go to
    /// application as Fn+⌘V - that is, a completely different combination.
    func testScenario007() async {
        system.setHeldPlan([.maskSecondaryFn])

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.modifiersStillHeld
        )
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testScenario008() async {
        system.setHeldPlan([.maskCommand])

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.modifiersStillHeld
        )
    }

    func testScenario009() async throws {
        // They held, they held, they let go.
        system.setHeldPlan([.maskSecondaryFn, .maskSecondaryFn, .maskSecondaryFn, []])

        try await inserter.insert("hello", into: target)

        XCTAssertEqual(system.heldModifiersCallCount, 4)
        XCTAssertEqual(system.postedKeys.count, 1)
    }

    func testScenario010() {
        // Separate direct check: the list is easy to “clean” without noticing that
        // this is the key that is assigned as a hot key.
        for flag in [
            CGEventFlags.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
        ] {
            XCTAssertTrue(
                TextInserter.watchedModifiers.contains(flag),
                "there is no \(flag) in the wait mask"
            )
        }
    }

    // MARK: - Clicks

    func testScenario011() async throws {
        try await inserter.insert("hello", into: target)

        XCTAssertEqual(pasteboard.writtenTexts, ["hello"])
        XCTAssertEqual(system.postedKeys.count, 1)
        XCTAssertEqual(system.postedKeys.first?.keyCode, CGKeyCode(kVK_ANSI_V))
        XCTAssertEqual(system.postedKeys.first?.flags, .maskCommand)
    }

    func testScenario012() async {
        pasteboard.setError(.clipboardWriteFailed)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.clipboardWriteFailed
        )
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testScenario013() async {
        let other = TargetApplication(
            bundleIdentifier: "com.apple.Terminal",
            processIdentifier: 999,
            localizedName: "Terminal"
        )
        pasteboard.onBegin = { [system] in system?.setFrontmost(other) }

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.targetChanged
        )

        XCTAssertEqual(system.postedKeys.count, 0)
        XCTAssertEqual(log.entries, ["activate", "pasteboard", "restore"])
    }

    func testScenario014() async {
        pasteboard.setRestoreError(.clipboardWriteFailed)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.insertedButClipboardRestoreFailed
        )

        XCTAssertEqual(system.postedKeys.count, 1, "Paste has already been posted")
    }

    func testScenario015() async {
        let inserter = try! XCTUnwrap(inserter)
        let system = try! XCTUnwrap(system)
        let log = try! XCTUnwrap(log)
        let target = target
        let task = Task {
            try await inserter.insert("hello", into: target)
        }
        for _ in 0..<100 where system.postedKeys.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(system.postedKeys.count, 1, "the test must be canceled after Cmd+V")

        task.cancel()
        do {
            try await task.value
        } catch {
            XCTFail("Cancellation after Cmd+V must not turn a successful paste into a failure: \(error)")
        }

        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }

    func testScenario016() async throws {
        try await inserter.pressReturn()

        XCTAssertEqual(system.postedKeys.count, 1)
        XCTAssertEqual(system.postedKeys.first?.keyCode, CGKeyCode(kVK_Return))
        XCTAssertEqual(system.postedKeys.first?.flags, [])
    }

    func testScenario017() async {
        system.setSecureInput(true)

        await XCTAssertThrowsErrorAsync(
            try await inserter.pressReturn(),
            expected: TextInsertionError.secureInputActive
        )
        XCTAssertEqual(system.postedKeys.count, 0)
    }

    func testScenario018() async {
        system.setTrusted(false)

        await XCTAssertThrowsErrorAsync(
            try await inserter.pressReturn(),
            expected: TextInsertionError.accessibilityPermissionDenied
        )
    }

    func testScenario019() async throws {
        let backgroundRestoringInserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            restoreDelay: .milliseconds(50)
        )

        let marks = try await backgroundRestoringInserter.insertReportingMarks("hello", into: target)

        XCTAssertNotNil(marks.pasteDispatchedAt)
        XCTAssertNil(marks.clipboardRestoredAt)
        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post"])

        for _ in 0..<200 where !log.entries.contains("restore") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }
}

/// An asynchronous analogue of `XCTAssertThrowsError` with checking a specific error.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: TextInsertionError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("an error \(expected) was expected, but there was none", file: file, line: line)
    } catch let error as TextInsertionError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), arrived \(error)", file: file, line: line)
    }
}

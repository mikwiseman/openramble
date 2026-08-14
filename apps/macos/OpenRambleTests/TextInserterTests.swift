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
        XCTAssertEqual(system.postedKeys.first?.targetProcessIdentifier, target.processIdentifier)
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
        let deadline = ContinuousClock.now + .seconds(1)
        while system.postedKeys.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
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
        XCTAssertNil(system.postedKeys.first?.targetProcessIdentifier)
    }

    func testReturnForDictationIsPinnedToTheOriginalApplication() async throws {
        try await inserter.pressReturn(into: target)

        XCTAssertEqual(system.postedKeys.count, 1)
        XCTAssertEqual(system.postedKeys.first?.keyCode, CGKeyCode(kVK_Return))
        XCTAssertEqual(system.postedKeys.first?.targetProcessIdentifier, target.processIdentifier)
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

    /// Two dictations one after another, faster than the deferred restore.
    ///
    /// Two short answers in the chat a second apart - and the second insert falls into
    /// the restore window of the first one. What a person copied before dictation must
    /// survive both: this is his clipboard, and the application borrowed it for a second.
    ///
    /// A real board here, and not a fake one: the whole point is in the ownership counter,
    /// and it belongs to the system, not to us.
    func testScenario020() async throws {
        let boardName = "is.waiwai.dictation.tests.\(UUID().uuidString)"
        let board = NSPasteboard(name: NSPasteboard.Name(boardName))
        defer { board.releaseGlobally() }
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString("what the person copied", forType: .string)

        let inserter = TextInserter(
            system: system,
            pasteboard: HostOnlyPasteboard(name: boardName),
            restoreDelay: .milliseconds(80)
        )
        try await inserter.insert("DICTATION ONE", into: target)
        try await inserter.insert("DICTATION TWO", into: target)

        for _ in 0..<200 where board.string(forType: .string) != "what the person copied" {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(board.string(forType: .string), "what the person copied")
    }

    /// A WindowServer call may return only after the insertion deadline and
    /// after the user has focused another application. The irreversible event
    /// must remain addressed to the app captured at keypress, never to the new
    /// frontmost app.
    func testDelayedPostRemainsTargetedToOriginalApplication() async throws {
        let originalTarget = target
        let delayedSystem = DelayedPostInputSystem(frontmost: originalTarget)
        let pasteboard = FakePasteboard(log: CallLog())
        let inserter = TextInserter(
            system: delayedSystem,
            pasteboard: pasteboard,
            restoreDelay: .zero
        )
        let task = Task {
            try await inserter.insert("hello", into: originalTarget)
        }

        XCTAssertEqual(delayedSystem.postEntered.wait(timeout: .now() + 1), .success)
        task.cancel()
        delayedSystem.setFrontmost(
            TargetApplication(
                bundleIdentifier: "com.apple.Terminal",
                processIdentifier: 999,
                localizedName: "Terminal"
            )
        )
        delayedSystem.allowPost.signal()

        try await task.value
        XCTAssertEqual(delayedSystem.postedTarget, originalTarget.processIdentifier)
    }

    /// A controller deadline can stop waiting while the actual WindowServer
    /// call is still blocked. A later dictation must not replace the clipboard
    /// underneath that old Cmd+V; it fails fast until the real call returns.
    func testTimedOutPasteOwnsTheProcessLaneUntilItsSystemPostReturns() async throws {
        let originalTarget = target
        let delayedSystem = DelayedPostInputSystem(frontmost: originalTarget)
        let pasteboard = FakePasteboard(log: CallLog())
        let lane = TextInsertionLane()
        let inserter = TextInserter(
            system: delayedSystem,
            pasteboard: pasteboard,
            restoreDelay: .zero,
            operationLane: lane
        )
        let first = Task {
            try await inserter.insert("FIRST", into: originalTarget)
        }

        XCTAssertEqual(delayedSystem.postEntered.wait(timeout: .now() + 1), .success)
        first.cancel()

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("SECOND", into: originalTarget),
            expected: .insertionInProgress
        )
        XCTAssertEqual(pasteboard.writtenTexts, ["FIRST"])

        delayedSystem.allowPost.signal()
        try await first.value

        delayedSystem.allowPost.signal()
        try await inserter.insert("THIRD", into: originalTarget)
        XCTAssertEqual(pasteboard.writtenTexts, ["FIRST", "THIRD"])
    }

    /// Restoring the person's clipboard is one destructive transaction: check
    /// ownership, clear our dictated item, then rewrite the snapshot. A second
    /// dictation must not enter after that clear and race its Cmd+V against the
    /// rewrite.
    func testDeferredRestoreOwnsTheProcessLaneAcrossClearAndRewrite() async throws {
        let gatedPasteboard = ClearThenRewriteGatedPasteboard(original: "ORIGINAL")
        let lane = TextInsertionLane()
        let inserter = TextInserter(
            system: system,
            pasteboard: gatedPasteboard,
            restoreDelay: .milliseconds(20),
            operationLane: lane
        )

        try await inserter.insert("FIRST", into: target)
        let clearDeadline = ContinuousClock.now + .seconds(1)
        while !gatedPasteboard.hasClearedRestore, ContinuousClock.now < clearDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(
            gatedPasteboard.hasClearedRestore,
            "the test must pause inside restore after its destructive clear"
        )
        defer { gatedPasteboard.allowRestoreRewrite.signal() }

        for attempt in 0..<32 {
            await XCTAssertThrowsErrorAsync(
                try await inserter.insert("SECOND-\(attempt)", into: target),
                expected: .insertionInProgress
            )
        }
        XCTAssertEqual(gatedPasteboard.writtenTexts, ["FIRST"])
        XCTAssertEqual(system.postedKeys.count, 1, "later attempts must never dispatch Cmd+V")

        gatedPasteboard.allowRestoreRewrite.signal()
        let finishDeadline = ContinuousClock.now + .seconds(1)
        while !gatedPasteboard.hasFinishedRestore, ContinuousClock.now < finishDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(gatedPasteboard.hasFinishedRestore)
        XCTAssertEqual(gatedPasteboard.contents, "ORIGINAL")
    }
}

/// Models the non-atomic system pasteboard sequence inside
/// `HostOnlyPasteboard.restoreSnapshot`: host-only clear, then snapshot write.
/// The gate makes the otherwise tiny corruption window deterministic.
private final class ClearThenRewriteGatedPasteboard: DictationPasteboard, @unchecked Sendable {
    let allowRestoreRewrite = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storedContents: String
    private var storedWrittenTexts: [String] = []
    private var snapshots: [(transaction: PasteboardTransaction, contents: String)] = []
    private var restoreWasCleared = false
    private var restoreWasFinished = false

    init(original: String) {
        storedContents = original
    }

    var contents: String {
        lock.withLock { storedContents }
    }

    var writtenTexts: [String] {
        lock.withLock { storedWrittenTexts }
    }

    var hasClearedRestore: Bool {
        lock.withLock { restoreWasCleared }
    }

    var hasFinishedRestore: Bool {
        lock.withLock { restoreWasFinished }
    }

    func beginHostOnlyWrite(_ text: String) throws -> PasteboardTransaction {
        let transaction = PasteboardTransaction()
        lock.withLock {
            snapshots.append((transaction, storedContents))
            storedContents = text
            storedWrittenTexts.append(text)
        }
        return transaction
    }

    func restore(_ transaction: PasteboardTransaction) throws {
        let snapshot = lock.withLock { () -> String? in
            guard let index = snapshots.firstIndex(where: { $0.transaction == transaction }) else {
                return nil
            }
            let snapshot = snapshots.remove(at: index).contents
            storedContents = ""
            restoreWasCleared = true
            return snapshot
        }
        guard let snapshot else { return }

        allowRestoreRewrite.wait()
        lock.withLock {
            storedContents = snapshot
            restoreWasFinished = true
        }
    }
}

private final class DelayedPostInputSystem: InputSystem, @unchecked Sendable {
    let postEntered = DispatchSemaphore(value: 0)
    let allowPost = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var frontmost: TargetApplication?
    private var storedPostedTarget: Int32?

    init(frontmost: TargetApplication?) {
        self.frontmost = frontmost
    }

    var isSecureInputEnabled: Bool { false }
    var isAccessibilityTrusted: Bool { true }
    var postedTarget: Int32? { lock.withLock { storedPostedTarget } }

    func setFrontmost(_ target: TargetApplication?) {
        lock.withLock { frontmost = target }
    }

    func frontmostApplication() -> TargetApplication? {
        lock.withLock { frontmost }
    }

    func heldModifiers() -> CGEventFlags { [] }
    func activate(_ target: TargetApplication) async -> Bool { true }

    func post(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        targetProcessIdentifier: Int32?
    ) throws {
        postEntered.signal()
        _ = allowPost.wait(timeout: .now() + 2)
        lock.withLock { storedPostedTarget = targetProcessIdentifier }
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

/// A deferred restore that fails must still reach the person.
///
/// The restore runs a second after the paste, detached, with nobody left to
/// throw to. The only branch that reported it threw from the zero-delay path,
/// which production never uses — so on the shipping path the loss was
/// completely silent: the person's clipboard gone, our dictation in its place.
final class DeferredRestoreFailureTests: XCTestCase {
    private let target = TargetApplication(
        bundleIdentifier: "com.apple.TextEdit",
        processIdentifier: 4242,
        localizedName: "TextEdit"
    )

    func testScenario021() async throws {
        let log = CallLog()
        let system = FakeInputSystem(log: log)
        let pasteboard = FakePasteboard(log: log)
        system.setFrontmost(target)
        pasteboard.setRestoreError(.clipboardRestoreFailed)

        let reported = ReportBox()
        let reporter = ClipboardRestoreReporter()
        reporter.onFailure { error in reported.record(error) }
        let inserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            restoreDelay: .milliseconds(20),
            restoreReporter: reporter
        )

        _ = try await inserter.insertReportingMarks("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", into: target)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(
            reported.value, .insertedButClipboardRestoreFailed,
            "losing the person's clipboard has to be said out loud"
        )
    }

    /// A restore that works stays quiet: a warning after every dictation would
    /// be noise, and noise is how real warnings stop being read.
    func testScenario022() async throws {
        let log = CallLog()
        let system = FakeInputSystem(log: log)
        let pasteboard = FakePasteboard(log: log)
        system.setFrontmost(target)

        let reported = ReportBox()
        let reporter = ClipboardRestoreReporter()
        reporter.onFailure { error in reported.record(error) }
        let inserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            restoreDelay: .milliseconds(20),
            restoreReporter: reporter
        )

        _ = try await inserter.insertReportingMarks("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", into: target)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertNil(reported.value)
    }

    private final class ReportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: TextInsertionError?
        var value: TextInsertionError? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func record(_ error: TextInsertionError) {
            lock.lock(); defer { lock.unlock() }
            stored = error
        }
    }
}

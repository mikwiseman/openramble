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
        inserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            readQuiet: .zero,
            readFloor: .zero,
            readLimit: .seconds(1),
            operationLane: TextInsertionLane()
        )
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

    /// ⌘V is a character shortcut, not a key position. On Dvorak the ANSI V
    /// key types ⌘K; the paste must use whatever key types "v" right now.
    func testPasteUsesTheKeyThatTypesVInTheCurrentLayout() async throws {
        system.setPasteKeyCode(47)

        try await inserter.insert("hello", into: target)

        XCTAssertEqual(system.postedKeys.first?.keyCode, 47)
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

    /// Nobody read the paste and the person's clipboard could not be put back
    /// either: nothing landed, and that is what is said.
    func testScenario014() async {
        pasteboard.setReadMode(.never)
        pasteboard.setRestoreError(.clipboardWriteFailed)

        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("hello", into: target),
            expected: TextInsertionError.clipboardRestoreFailed
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
    }

    /// "Send it." presses Return where the paste went: both keys take the same
    /// route, so a panel over a terminal never gets the text while the terminal
    /// runs whatever was on its command line.
    func testReturnFollowsThePaste() async throws {
        try await inserter.insert("hello", into: target)
        try await inserter.pressReturn(into: target)

        XCTAssertEqual(
            system.postedKeys.map(\.keyCode),
            [CGKeyCode(kVK_ANSI_V), CGKeyCode(kVK_Return)]
        )
    }

    /// Return is irreversible. If the dictation's application is no longer in
    /// front, it is not pressed at all.
    func testReturnIsNotPressedOnceTheTargetIsNoLongerInFront() async {
        system.setFrontmost(
            TargetApplication(
                bundleIdentifier: "com.apple.Terminal",
                processIdentifier: 999,
                localizedName: "Terminal"
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await inserter.pressReturn(into: target),
            expected: TextInsertionError.targetChanged
        )
        XCTAssertEqual(system.postedKeys.count, 0)
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
        let marks = try await inserter.insertReportingMarks("hello", into: target)

        let pasted = try XCTUnwrap(marks.pasteDispatchedAt)
        let read = try XCTUnwrap(marks.firstReadAt)
        let restored = try XCTUnwrap(marks.clipboardRestoredAt)
        XCTAssertLessThanOrEqual(pasted, read)
        XCTAssertLessThanOrEqual(read, restored)
        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }

    /// Two dictations one after another, as fast as a person can manage.
    ///
    /// What a person copied before dictation must survive both: this is their
    /// clipboard, and the application borrowed it for a moment.
    ///
    /// A real board here, and not a fake one: the whole point is in the ownership counter,
    /// and it belongs to the system, not to us.
    func testScenario020() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let reader = BoardReader(board: board.name)
        system.onPost = { reader.read(after: .milliseconds(5)) }

        let inserter = board.inserter(system: system)
        try await inserter.insert("DICTATION ONE", into: target)
        try await inserter.insert("DICTATION TWO", into: target)

        let texts = await reader.texts(count: 2)
        XCTAssertEqual(texts, ["DICTATION ONE", "DICTATION TWO"])
        XCTAssertEqual(board.contents, "what the person copied")
    }

    // MARK: - Read receipt

    /// The target reads the paste within milliseconds; the person's clipboard
    /// comes back a moment later instead of a fixed second.
    func testRestoresSoonAfterTheTargetReadsThePaste() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let reader = BoardReader(board: board.name)
        system.onPost = { reader.read(after: .milliseconds(20)) }

        let marks = try await board.inserter(
            system: system,
            readQuiet: TextInserter.readQuiet,
            readFloor: TextInserter.readFloor
        ).insertReportingMarks("DICTATED", into: target)

        XCTAssertEqual(reader.texts, ["DICTATED"])
        XCTAssertEqual(board.contents, "what the person copied")
        let pasted = try XCTUnwrap(marks.pasteDispatchedAt)
        let read = try XCTUnwrap(marks.firstReadAt)
        let restored = try XCTUnwrap(marks.clipboardRestoredAt)
        XCTAssertGreaterThanOrEqual(read.duration(to: restored), TextInserter.readQuiet)
        XCTAssertGreaterThanOrEqual(pasted.duration(to: restored), TextInserter.readFloor)
        // Loose on purpose: shared CI runners are slow. The harness measures the
        // real numbers; this only has to tell "soon" from the old fixed second.
        XCTAssertLessThan(pasted.duration(to: restored), .milliseconds(900))
    }

    /// A slow application that reads well after a second still pastes the
    /// dictation, not whatever the person had copied (VoiceInk #722).
    func testASlowTargetStillGetsTheDictationNotThePersonsClipboard() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let reader = BoardReader(board: board.name)
        system.onPost = { reader.read(after: .milliseconds(1500)) }

        try await board.inserter(system: system, readLimit: .seconds(3))
            .insert("DICTATED", into: target)

        let texts = await reader.texts(count: 1)
        XCTAssertEqual(texts, ["DICTATED"])
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// ⌘V went out and nothing ever read the clipboard: nothing was pasted.
    /// The person hears it, gets their clipboard back, and the dictation does
    /// not linger anywhere.
    func testAPasteNobodyReadsIsReportedAsNotLanded() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }

        await XCTAssertThrowsErrorAsync(
            try await board.inserter(system: system, readLimit: .milliseconds(150))
                .insert("DICTATED", into: target),
            expected: .pasteNotRead
        )

        XCTAssertEqual(board.contents, "what the person copied")
        XCTAssertNotEqual(
            BoardReader(board: board.name).readNowReturning(),
            "DICTATED",
            "an unread dictation must not linger for a later reader"
        )
    }

    /// The person presses the dictation key while an unread paste waits:
    /// nothing has appeared, so they are trying again. The wait ends then,
    /// not at the limit, and the paste nobody read is reported with the
    /// person's clipboard back.
    func testAPressEndsTheWaitForAPasteNobodyReads() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let inserter = board.inserter(
            system: system,
            readFloor: .milliseconds(100),
            readLimit: .seconds(3)
        )
        system.onPost = {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { inserter.endTheReadWait() }
        }

        let started = ContinuousClock.now
        await XCTAssertThrowsErrorAsync(
            try await inserter.insert("DICTATED", into: target),
            expected: .pasteNotRead
        )

        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "the press ended the wait, not the limit")
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// Regression guard: a press just before ⌘V does not cut short a paste
    /// that is about to land. The target still has the floor to read it.
    func testAPressBeforeThePasteLeavesTheTargetTimeToRead() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let reader = BoardReader(board: board.name)
        let inserter = board.inserter(
            system: system,
            readQuiet: TextInserter.readQuiet,
            readFloor: .milliseconds(300),
            readLimit: .seconds(3)
        )
        system.onHeldModifiers = { inserter.endTheReadWait() }
        system.onPost = { reader.read(after: .milliseconds(20)) }

        try await inserter.insert("DICTATED", into: target)

        XCTAssertEqual(reader.texts, ["DICTATED"])
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// A read that lands after the last look but before the restore closes
    /// the transaction still counts: the words landed, and calling them lost
    /// would make the person insert them a second time from the menu.
    func testAReadJustBeforeTheRestoreStillCountsAsLanded() async throws {
        pasteboard.setReadMode(.duringRestore)
        let inserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            readQuiet: .zero,
            readFloor: .zero,
            readLimit: .milliseconds(50),
            operationLane: TextInsertionLane()
        )

        let marks = try await inserter.insertReportingMarks("hello", into: target)

        XCTAssertNotNil(marks.firstReadAt)
        XCTAssertEqual(log.entries, ["activate", "pasteboard", "post", "restore"])
    }

    /// Something that ignores the markers reads the board before the target
    /// does. The receipt is spent, but that is no reason to raise a false
    /// alarm or to snatch the text away from the target a moment later.
    func testAnEarlyReaderDoesNotCutTheTargetsPasteShort() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let watcher = BoardReader(board: board.name)
        let pastingApp = BoardReader(board: board.name)
        system.onHeldModifiers = { watcher.readNow() }
        system.onPost = { pastingApp.read(after: .milliseconds(100)) }
        // A floor far above the target's read keeps this about the rule, not
        // about how fast a shared CI runner serves the main queue.
        let floor = Duration.milliseconds(600)
        let limit = Duration.seconds(2)

        let marks = try await board.inserter(
            system: system,
            readQuiet: TextInserter.readQuiet,
            readFloor: floor,
            readLimit: limit
        ).insertReportingMarks("DICTATED", into: target)

        XCTAssertEqual(watcher.texts, ["DICTATED"])
        XCTAssertEqual(pastingApp.texts, ["DICTATED"], "the target still pastes the dictation")
        let pasted = try XCTUnwrap(marks.pasteDispatchedAt)
        let read = try XCTUnwrap(marks.firstReadAt)
        let restored = try XCTUnwrap(marks.clipboardRestoredAt)
        XCTAssertLessThan(read, pasted)
        XCTAssertGreaterThanOrEqual(pasted.duration(to: restored), floor)
        XCTAssertLessThan(pasted.duration(to: restored), limit, "an early read does not hold the text to the limit")
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// The application serves the read from its main thread. Whatever runs
    /// after the insertion on the main actor (edit learning reads the focused
    /// field) must not start before the target has its text.
    func testInsertReturnsOnlyAfterTheTargetHasRead() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let reader = BoardReader(board: board.name)
        system.onPost = { reader.read(after: .milliseconds(40)) }

        let marks = try await board.inserter(system: system)
            .insertReportingMarks("DICTATED", into: target)
        let returned = ContinuousClock.now

        let read = try XCTUnwrap(marks.firstReadAt, "insert returned before the target read")
        XCTAssertLessThanOrEqual(read, returned)
        let texts = await reader.texts(count: 1)
        XCTAssertEqual(texts, ["DICTATED"])
    }

    /// The real route: another process pastes the way TextEdit does, through
    /// NSTextView.readSelection. Its read is served from this process's main
    /// thread, which an in-process read never exercises.
    func testAnotherProcessPastingThroughATextViewIsTheReceipt() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let otherApp = OtherProcessPaste(board: board.name)
        system.onPost = { otherApp.paste() }

        let marks = try await board.inserter(
            system: system,
            readQuiet: TextInserter.readQuiet,
            readFloor: TextInserter.readFloor,
            readLimit: .seconds(10)
        ).insertReportingMarks("DICTATED", into: target)

        XCTAssertEqual(otherApp.pasted(), "DICTATED")
        let read = try XCTUnwrap(marks.firstReadAt)
        let restored = try XCTUnwrap(marks.clipboardRestoredAt)
        XCTAssertGreaterThanOrEqual(read.duration(to: restored), TextInserter.readQuiet)
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// A save panel or alert of ours holds the main thread in the modal panel
    /// mode, a menu or a drag in the event tracking mode, while the person
    /// dictates into another application. The app has an NSApplication, which
    /// makes both of them common modes, so the target's read is served at
    /// once there too. (This bundle has no host app: without the line below,
    /// neither mode serves the read and the target waits for the panel.)
    func testAModalPanelOrMenuOfOursDoesNotHoldUpTheTargetsRead() async throws {
        await MainActor.run { _ = NSApplication.shared }
        for mode in [RunLoop.Mode.modalPanel, .eventTracking] {
            let board = RealBoard(holding: "what the person copied")
            defer { board.release() }
            let otherApp = OtherProcessPaste(board: board.name)
            let spin = MainThreadSpin(mode)
            system.onPost = {
                spin.start()
                otherApp.paste()
            }

            let inserter = board.inserter(
                system: system,
                readQuiet: TextInserter.readQuiet,
                readFloor: TextInserter.readFloor,
                readLimit: .seconds(10)
            )
            // The spin outlasts the read limit and ends only after the insert
            // returns, so a read that lands was served inside the mode.
            let marks: InsertionMarks
            do {
                marks = try await inserter.insertReportingMarks("DICTATED", into: target)
            } catch {
                await spin.stop()
                throw error
            }
            await spin.stop()

            XCTAssertEqual(otherApp.pasted(), "DICTATED", mode.rawValue)
            XCTAssertNotNil(marks.firstReadAt, mode.rawValue)
            XCTAssertEqual(board.contents, "what the person copied")
        }
    }

    /// Our main thread is busy past the read limit, so the target's read
    /// waits for it. Putting the person's clipboard back in the meantime would
    /// hand that read the person's clipboard: pasted where the dictation
    /// belongs, while we say nothing was. The read is served once the thread
    /// is free, within its turn, and the dictation lands.
    func testATargetWaitingForOurBusyMainThreadGetsTheDictation() async throws {
        await MainActor.run { _ = NSApplication.shared }
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let otherApp = OtherProcessPaste(board: board.name)
        system.onPost = {
            DispatchQueue.main.async { Thread.sleep(forTimeInterval: 1.6) }
            otherApp.paste()
        }

        var outcome = "landed"
        do {
            _ = try await board.inserter(
                system: system,
                readQuiet: TextInserter.readQuiet,
                readFloor: TextInserter.readFloor,
                readLimit: .seconds(1)
            ).insertReportingMarks("DICTATED", into: target)
        } catch {
            outcome = "\(error)"
        }
        let pasted = otherApp.pasted()

        XCTAssertEqual(outcome, "landed")
        XCTAssertEqual(pasted, "DICTATED", "what the target pasted")
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// Our main thread stays busy long after the limit, and nobody reads.
    /// Waiting the stall out would outlive the clipboard snapshot and the
    /// controller's deadline: the person's clipboard would be deleted, with
    /// nobody left to say so. The main thread gets its turn limit; then the
    /// clipboard comes back whole and the paste counts as not read.
    func testAPasteNobodyReadsWhileOurMainThreadStaysBusyGivesTheClipboardBack() async throws {
        await MainActor.run { _ = NSApplication.shared }
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let freed = expectation(description: "our main thread is free again")
        system.onPost = {
            DispatchQueue.main.async {
                Thread.sleep(forTimeInterval: 3)
                freed.fulfill()
            }
        }
        let inserter = TextInserter(
            system: system,
            pasteboard: HostOnlyPasteboard(name: board.name, snapshotLifetime: 2),
            readQuiet: TextInserter.readQuiet,
            readFloor: TextInserter.readFloor,
            readLimit: .milliseconds(300),
            operationLane: TextInsertionLane()
        )

        let started = ContinuousClock.now
        var outcome = "landed"
        do {
            try await inserter.insert("DICTATED", into: target)
        } catch {
            outcome = "\(error)"
        }
        let waited = started.duration(to: .now)
        await fulfillment(of: [freed], timeout: 10)

        XCTAssertEqual(outcome, "pasteNotRead")
        XCTAssertLessThan(waited, .milliseconds(300) + TextInserter.mainThreadTurnLimit + .milliseconds(400))
        XCTAssertEqual(board.contents, "what the person copied")
    }

    /// A panel or menu of ours runs its own loop on the main thread, and
    /// nobody reads the paste. The main thread still serves reads there, so
    /// the wait ends at the limit with the person's clipboard back; it does
    /// not sit out the panel.
    func testAPasteNobodyReadsWhileAPanelOfOursIsOpenEndsAtTheLimit() async throws {
        await MainActor.run { _ = NSApplication.shared }
        for mode in [RunLoop.Mode.modalPanel, .eventTracking] {
            let board = RealBoard(holding: "what the person copied")
            defer { board.release() }
            let spin = MainThreadSpin(mode)
            system.onPost = { spin.start() }

            let started = ContinuousClock.now
            var outcome = "landed"
            do {
                try await board.inserter(
                    system: system,
                    readQuiet: TextInserter.readQuiet,
                    readLimit: .milliseconds(300)
                ).insert("DICTATED", into: target)
            } catch {
                outcome = "\(error)"
            }
            let waited = started.duration(to: .now)
            await spin.stop()

            XCTAssertEqual(outcome, "pasteNotRead", mode.rawValue)
            XCTAssertLessThan(waited, .seconds(2), mode.rawValue)
            XCTAssertEqual(board.contents, "what the person copied", mode.rawValue)
        }
    }

    /// The controller's deadline cancels the insertion while it waits for the
    /// read. The person gets their clipboard back, the dictation never stays
    /// on the board, the lane is free, and the cancellation is not dressed up
    /// as a paste that landed.
    func testCancellingWhileWaitingForTheReadPutsTheClipboardBack() async throws {
        let board = RealBoard(holding: "what the person copied")
        defer { board.release() }
        let lane = TextInsertionLane()
        let inserter = board.inserter(system: system, readLimit: .seconds(5), operationLane: lane)
        let target = target
        let system = try XCTUnwrap(system)
        let task = Task { try await inserter.insert("DICTATED", into: target) }
        let posted = ContinuousClock.now + .seconds(1)
        while system.postedKeys.isEmpty, ContinuousClock.now < posted {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(system.postedKeys.count, 1)

        task.cancel()
        do {
            try await task.value
            XCTFail("an unread paste that was cancelled is not a success")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertEqual(board.contents, "what the person copied")
        XCTAssertTrue(lane.tryAcquire(), "the lane is free again")
        lane.release()
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
            readQuiet: .zero,
            readFloor: .zero,
            readLimit: .seconds(1),
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
    func testRestoreOwnsTheProcessLaneAcrossClearAndRewrite() async throws {
        let gatedPasteboard = ClearThenRewriteGatedPasteboard(original: "ORIGINAL")
        let lane = TextInsertionLane()
        let inserter = TextInserter(
            system: system,
            pasteboard: gatedPasteboard,
            readQuiet: .zero,
            readFloor: .zero,
            readLimit: .seconds(1),
            operationLane: lane
        )
        let target = target

        let first = Task { try await inserter.insert("FIRST", into: target) }
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
        try await first.value
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
    private var readAt: ContinuousClock.Instant?

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

    /// The target reads at once.
    func firstRead(of transaction: PasteboardTransaction) -> ContinuousClock.Instant? {
        lock.withLock {
            if readAt == nil { readAt = .now }
            return readAt
        }
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

    init(frontmost: TargetApplication?) {
        self.frontmost = frontmost
    }

    var isSecureInputEnabled: Bool { false }
    var isAccessibilityTrusted: Bool { true }

    func setFrontmost(_ target: TargetApplication?) {
        lock.withLock { frontmost = target }
    }

    func frontmostApplication() -> TargetApplication? {
        lock.withLock { frontmost }
    }

    func heldModifiers() -> CGEventFlags { [] }
    func activate(_ target: TargetApplication) async -> Bool { true }
    func pasteKeyCode() async -> CGKeyCode { CGKeyCode(kVK_ANSI_V) }

    func post(keyCode: CGKeyCode, flags: CGEventFlags) throws {
        postEntered.signal()
        _ = allowPost.wait(timeout: .now() + 2)
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

/// A real named board holding what the person copied, and the inserter that
/// writes to it. Never the general pasteboard: a test must not touch what the
/// person copied at that moment.
private struct RealBoard {
    let name = "is.waiwai.dictation.tests.\(UUID().uuidString)"

    init(holding contents: String) {
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(contents, forType: .string)
    }

    var contents: String? {
        NSPasteboard(name: NSPasteboard.Name(name)).string(forType: .string)
    }

    func inserter(
        system: any InputSystem,
        readQuiet: Duration = .zero,
        readFloor: Duration = .zero,
        readLimit: Duration = .seconds(2),
        operationLane: TextInsertionLane = TextInsertionLane()
    ) -> TextInserter {
        TextInserter(
            system: system,
            pasteboard: HostOnlyPasteboard(name: name),
            readQuiet: readQuiet,
            readFloor: readFloor,
            readLimit: readLimit,
            operationLane: operationLane
        )
    }

    func release() {
        NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally()
    }
}

/// Plays the target application: reads the board's text from the main
/// thread, the way AppKit serves a paste.
private final class BoardReader: @unchecked Sendable {
    private let name: String
    private let lock = NSLock()
    private var stored: [String?] = []

    init(board name: String) {
        self.name = name
    }

    var texts: [String?] { lock.withLock { stored } }

    /// The reads so far, once `count` of them have finished on the main
    /// thread (or after a second): the receipt is noted inside the read, the
    /// text a moment after it.
    func texts(count: Int) async -> [String?] {
        for _ in 0..<200 where texts.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return texts
    }

    func read(after delay: Duration) {
        let seconds = Double(delay.components.seconds)
            + Double(delay.components.attoseconds) / 1e18
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.readNow() }
    }

    func readNow() {
        let text = readNowReturning()
        lock.withLock { stored.append(text) }
    }

    func readNowReturning() -> String? {
        NSPasteboard(name: NSPasteboard.Name(name)).string(forType: .string)
    }
}

/// Another process that pastes the board through NSTextView.readSelection,
/// TextEdit's own path. It reads a private named board and touches nothing
/// else: no window, no other application, no general pasteboard.
private final class OtherProcessPaste: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let exited = DispatchSemaphore(value: 0)

    init(board name: String) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", """
            ObjC.import('AppKit');
            const view = $.NSTextView.alloc.initWithFrame($.NSMakeRect(0, 0, 400, 100));
            view.richText = true;
            view.readSelectionFromPasteboard($.NSPasteboard.pasteboardWithName('\(name)'))
                ? ObjC.unwrap(view.string) : 'nothing';
            """]
        process.standardOutput = output
        // Not waitUntilExit: it waits on the calling thread's run loop, and on
        // a Swift concurrency thread it can miss the exit and block forever.
        process.terminationHandler = { [exited] _ in exited.signal() }
    }

    func paste() {
        try? process.run()
    }

    func pasted() -> String {
        guard exited.wait(timeout: .now() + 10) == .success else { return "still pasting" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds this process's main thread in one run-loop mode, the way a modal
/// panel or an open menu does, until told to stop.
private final class MainThreadSpin: @unchecked Sendable {
    private let mode: String
    private let lock = NSLock()
    private var stopped = false
    private var ended = false

    init(_ mode: RunLoop.Mode) {
        self.mode = mode.rawValue
    }

    func start() {
        DispatchQueue.main.async {
            let mode = RunLoop.Mode(self.mode)
            let limit = Date().addingTimeInterval(12)
            while !self.lock.withLock({ self.stopped }), Date() < limit {
                _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.01))
            }
            self.lock.withLock { self.ended = true }
        }
    }

    func stop() async {
        lock.withLock { stopped = true }
        while !lock.withLock({ ended }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class ReportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func record() { lock.withLock { stored += 1 } }
}

/// The key that types "v" with ⌘ held, read from the real layouts installed
/// with macOS. Nothing is switched: the layouts are only looked up.
final class PasteKeyTests: XCTestCase {
    func testThePasteKeyIsTheKeyThatTypesVOnRealLayouts() throws {
        let expected: [String: CGKeyCode] = [
            "com.apple.keylayout.ABC": 9,
            "com.apple.keylayout.Russian": 9,
            "com.apple.keylayout.DVORAK-QWERTYCMD": 9,
            "com.apple.keylayout.Dvorak": 47,
            "com.apple.keylayout.Dvorak-Right": 43,
            "com.apple.keylayout.Turkish": 8,
            "com.apple.keylayout.Turkish-Standard": 8,
        ]
        var missing: [String] = []
        for (identifier, keyCode) in expected.sorted(by: { $0.key < $1.key }) {
            guard let layout = Self.layoutData(identifier) else {
                missing.append(identifier)
                continue
            }
            XCTAssertEqual(
                PasteKey.keyCode(translating: PasteKey.characters(in: layout)),
                keyCode,
                identifier
            )
        }
        if !missing.isEmpty {
            throw XCTSkip("not installed on this Mac: \(missing.joined(separator: ", "))")
        }
    }

    func testTheANSIVKeyWinsWhenItTypesV() {
        let keyCode = PasteKey.keyCode { $0 == 9 || $0 == 3 ? "v" : "x" }

        XCTAssertEqual(keyCode, 9)
    }

    func testALayoutWithNoVFallsBackToTheANSIVKey() {
        XCTAssertEqual(PasteKey.keyCode { _ in "ж" }, CGKeyCode(kVK_ANSI_V))
    }

    private static func layoutData(_ identifier: String) -> CFData? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
            as? [TISInputSource],
            let source = sources.first,
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }
}

/// A restore that fails after the paste landed must still reach the person.
///
/// The words are in the target, so the insertion succeeded; what failed is
/// putting the person's own clipboard back. Thrown, it would read as "not
/// inserted"; swallowed, the person would silently lose what they had copied.
final class LandedPasteRestoreFailureTests: XCTestCase {
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

        let reports = ReportCounter()
        let reporter = ClipboardRestoreReporter()
        reporter.onFailure { reports.record() }
        let inserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            readQuiet: .milliseconds(20),
            readFloor: .zero,
            readLimit: .seconds(1),
            restoreReporter: reporter,
            operationLane: TextInsertionLane()
        )

        let marks = try await inserter.insertReportingMarks("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", into: target)

        XCTAssertNotNil(marks.pasteDispatchedAt, "the words landed: an insertion, not a failure")
        XCTAssertNil(marks.clipboardRestoredAt, "the clipboard did not come back")
        XCTAssertEqual(reports.count, 1, "losing the person's clipboard has to be said out loud")
    }

    /// A restore that works stays quiet: a warning after every dictation would
    /// be noise, and noise is how real warnings stop being read.
    func testScenario022() async throws {
        let log = CallLog()
        let system = FakeInputSystem(log: log)
        let pasteboard = FakePasteboard(log: log)
        system.setFrontmost(target)

        let reports = ReportCounter()
        let reporter = ClipboardRestoreReporter()
        reporter.onFailure { reports.record() }
        let inserter = TextInserter(
            system: system,
            pasteboard: pasteboard,
            readQuiet: .milliseconds(20),
            readFloor: .zero,
            readLimit: .seconds(1),
            restoreReporter: reporter,
            operationLane: TextInsertionLane()
        )

        _ = try await inserter.insertReportingMarks("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}", into: target)

        XCTAssertEqual(reports.count, 0)
    }
}

import AppKit
import Carbon.HIToolbox
import XCTest

/// The shortcut that pastes the last take, the rules that decide what may be
/// one, and what "the last take" is.
@MainActor
final class LastTakeShortcutTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private let cKey = UInt16(kVK_ANSI_C)

    /// ⌃⌘V out of the box: one key away from the paste it stands in for, and
    /// the way back to words that could not land.
    func testScenario001() {
        let state = harness.makeState()
        XCTAssertEqual(state.lastTakeShortcut, .controlCommandV)
        XCTAssertEqual(state.lastTakeShortcut?.displayString, "⌃⌘V")
    }

    /// Cleared is Off, and stays Off after a relaunch: an empty value is a
    /// decision, a missing one is a first launch.
    func testClearingTheShortcutSurvivesARelaunch() {
        let state = harness.makeState()
        state.lastTakeShortcut = nil
        XCTAssertNil(harness.makeState().lastTakeShortcut)
    }

    /// "Also copy dictations to the clipboard" is gone: the clipboard holds a
    /// dictation only for the paste. The ways to get one back on purpose —
    /// the last take with its shortcut, and History — both hold it.
    func testEveryDictationStaysOneCopyAway() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()

        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        await settle()

        XCTAssertEqual(state.lastTakeText, "Ping test", "the last take and its shortcut")
        XCTAssertEqual(state.history.first?.text, "Ping test", "History")
    }

    /// A plain key would fire in the middle of a word, and Shift with a letter
    /// is just a capital letter. Both would type into someone's document.
    func testScenario002() {
        XCTAssertFalse(KeyCombination(keyCode: cKey, modifiers: []).isValid)
        XCTAssertFalse(KeyCombination(keyCode: cKey, modifiers: [.shift]).isValid)
        XCTAssertTrue(KeyCombination(keyCode: cKey, modifiers: [.command]).isValid)
        XCTAssertTrue(KeyCombination(keyCode: cKey, modifiers: [.control]).isValid)
        XCTAssertTrue(KeyCombination(keyCode: cKey, modifiers: [.option]).isValid)
    }

    /// The function row types nothing, which is exactly why people bind it.
    func testScenario003() {
        XCTAssertTrue(KeyCombination(keyCode: UInt16(kVK_F13), modifiers: []).isValid)
        XCTAssertTrue(KeyCombination(keyCode: UInt16(kVK_F5), modifiers: []).isValid)
    }

    /// ⌘C must not answer to ⇧⌘C: in most applications that is a different
    /// command, and a shortcut that fires on supersets fires on other people's
    /// shortcuts.
    func testScenario004() {
        let shortcut = KeyCombination(keyCode: cKey, modifiers: [.command, .option])
        XCTAssertTrue(shortcut.matches(
            keyCode: cKey,
            rawFlags: NSEvent.ModifierFlags([.command, .option]).rawValue
        ))
        XCTAssertFalse(shortcut.matches(
            keyCode: cKey,
            rawFlags: NSEvent.ModifierFlags([.command, .option, .shift]).rawValue
        ))
        XCTAssertFalse(shortcut.matches(
            keyCode: cKey,
            rawFlags: NSEvent.ModifierFlags([.command]).rawValue
        ))
    }

    /// Arrow keys and the function row raise `.function` on their own, and
    /// Caps Lock raises its bit whenever it happens to be on. A shortcut that
    /// counted either would stop matching the moment someone pressed Caps Lock.
    func testScenario005() {
        let left = KeyCombination(keyCode: UInt16(kVK_LeftArrow), modifiers: [.command])
        XCTAssertTrue(left.matches(
            keyCode: UInt16(kVK_LeftArrow),
            rawFlags: NSEvent.ModifierFlags([.command, .function, .capsLock]).rawValue
        ))
    }

    /// Modifier glyphs in Apple's order, so it reads like every other menu.
    func testScenario006() {
        let shortcut = KeyCombination(
            keyCode: cKey,
            modifiers: [.command, .shift, .option, .control]
        )
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘C")
        XCTAssertEqual(
            KeyCombination(keyCode: UInt16(kVK_Space), modifiers: [.option]).displayString,
            "⌥Space"
        )
    }

    /// It survives a trip through defaults, which is the only way it survives
    /// a relaunch.
    func testScenario007() {
        let shortcut = KeyCombination(keyCode: cKey, modifiers: [.command, .option])
        let restored = KeyCombination(rawValue: shortcut.rawValue)
        XCTAssertEqual(restored, shortcut)
        XCTAssertNil(KeyCombination(rawValue: "nonsense"))
        XCTAssertNil(KeyCombination(rawValue: ""))
    }

    /// Escape leaves the binding alone and Delete empties it — which is also
    /// why neither can be recorded.
    func testScenario008() {
        XCTAssertEqual(
            ShortcutRecording.outcome(keyCode: UInt16(kVK_Escape), modifiers: []),
            .cancel
        )
        XCTAssertEqual(
            ShortcutRecording.outcome(keyCode: UInt16(kVK_Delete), modifiers: []),
            .clear
        )
        // With a modifier they are ordinary keys again.
        XCTAssertEqual(
            ShortcutRecording.outcome(keyCode: UInt16(kVK_Escape), modifiers: [.command]),
            .commit(KeyCombination(keyCode: UInt16(kVK_Escape), modifiers: [.command]))
        )
    }

    /// A rejected press keeps the field listening rather than storing nonsense.
    func testScenario009() {
        guard case .reject = ShortcutRecording.outcome(keyCode: cKey, modifiers: []) else {
            return XCTFail("a bare letter must be refused")
        }
    }

    /// The chosen shortcut reaches the watcher, and clearing it takes the
    /// shortcut back off the keyboard.
    func testScenario010() async {
        harness.permissions.accessibilityGranted = true
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()

        let shortcut = KeyCombination(keyCode: cKey, modifiers: [.command, .option])
        state.lastTakeShortcut = shortcut
        XCTAssertEqual(harness.copyMonitor.shortcut, shortcut)
        XCTAssertTrue(harness.copyMonitor.isRunning)

        state.lastTakeShortcut = nil
        XCTAssertFalse(harness.copyMonitor.isRunning)
    }

    /// Without Accessibility there is nothing to listen with, and starting the
    /// watcher would only fail quietly.
    func testScenario011() async {
        harness.permissions.accessibilityGranted = false
        let state = harness.makeState()
        state.refreshPermissions()
        await settle()

        state.lastTakeShortcut = KeyCombination(keyCode: cKey, modifiers: [.command])
        XCTAssertFalse(harness.copyMonitor.isRunning)
    }

    /// It comes back after a relaunch, because a shortcut you have to set
    /// again every morning is not a shortcut.
    func testScenario012() {
        let shortcut = KeyCombination(keyCode: cKey, modifiers: [.command, .option])
        // The name it was stored under as the copy shortcut: a chord someone
        // already chose stays theirs.
        harness.defaults.set(shortcut.rawValue, forKey: "copyShortcut")
        XCTAssertEqual(harness.makeState().lastTakeShortcut, shortcut)
    }

    /// Pressing it with nothing dictated says so rather than pasting silence.
    func testScenario013() async {
        let state = harness.makeState()
        harness.copyMonitor.onPress?()
        await settle()
        XCTAssertNil(state.lastTakeText)
        XCTAssertEqual(state.lastNotice?.message, "Nothing dictated yet.")
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(harness.copied, [])
    }

    /// The chord pastes the last take into the app in front, and leaves the
    /// clipboard to the paste: nothing is copied.
    func testTheChordPastesTheLastTake() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        try await dictate(state, untilHistoryHas: 1)

        harness.copyMonitor.onPress?()
        await settle()

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test", "Ping test"], "the take, then the chord")
        XCTAssertEqual(harness.copied, [])
        XCTAssertEqual(state.lastTakeText, "Ping test", "still the last take: the chord pastes it again")
    }

    /// Protected typing does not stop a paste, so the chord pastes then as
    /// it does at any other time. It used to copy instead, on the belief that
    /// a posted ⌘V could not land.
    func testTheChordPastesWhileTypingIsProtected() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        try await dictate(state, untilHistoryHas: 1)
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")

        harness.copyMonitor.onPress?()
        for _ in 0..<400 {
            if await harness.inserter.insertedTexts.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test", "Ping test"], "the take, then the chord's paste of it")
        XCTAssertEqual(harness.copied, [], "nothing was copied")
    }

    private func dictate(_ state: AppState, untilHistoryHas count: Int) async throws {
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.history.count < count || state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.history.count, count)
    }

    private func offersCopyLast(_ state: AppState) -> Bool {
        let rows = MenuSections.sections(for: state).joined()
        XCTAssertEqual(rows.contains(.pasteLastTake), rows.contains(.copyLastTake), "one take, two verbs")
        return rows.contains(.pasteLastTake)
    }

    /// The last take is the text this run inserted, and the menu offers it
    /// only then. History cannot stand in: it outlives a relaunch and keeps a
    /// take-back's raw words, "Scratch that." included, so the row would
    /// paste words the person took back, and paste something else after a
    /// relaunch. The Library still copies any entry.
    func testCopyLastIsOfferedOnlyForTextThisRunInserted() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        XCTAssertFalse(offersCopyLast(state), "nothing dictated yet")

        try await dictate(state, untilHistoryHas: 1)
        harness.transcription.text = "Ship it Friday. Scratch that."
        try await dictate(state, untilHistoryHas: 2)

        XCTAssertEqual(state.history.map(\.text), ["Ship it Friday. Scratch that.", "Ping test"])
        XCTAssertEqual(state.lastDictation?.insertedText, "Ping test", "a take-back inserts nothing")
        XCTAssertTrue(offersCopyLast(state))

        let relaunched = harness.makeState()
        XCTAssertNil(relaunched.lastDictation, "in memory only")
        XCTAssertEqual(relaunched.history.count, 2, "History kept both")
        XCTAssertFalse(offersCopyLast(relaunched), "nothing inserted in this run")
    }

    /// Copy Last's words live as long as the History entry that keeps them.
    /// Deleting another entry leaves them; deleting theirs takes them too, as
    /// Delete All does, even when that entry was the only one.
    func testDeletingTheTakesHistoryEntryDeletesCopyLast() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        try await dictate(state, untilHistoryHas: 1)
        harness.transcription.text = "Ship it Friday. Scratch that."
        try await dictate(state, untilHistoryHas: 2)

        state.deleteHistoryEntry(state.history[0])
        XCTAssertEqual(state.history.map(\.text), ["Ping test"])
        XCTAssertEqual(state.lastDictation?.insertedText, "Ping test", "its entry is still in History")
        XCTAssertTrue(offersCopyLast(state))

        state.deleteHistoryEntry(state.history[0])
        XCTAssertEqual(state.history, [])
        XCTAssertNil(state.lastDictation, "the only copy left of deleted words")
        XCTAssertFalse(offersCopyLast(state))
    }

    /// Insert Last holds a failed take's words in memory. Deleting the take's
    /// History entry deletes that copy too.
    func testDeletingAFailedTakesHistoryEntryDeletesInsertLast() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        await harness.inserter.setError(.accessibilityPermissionDenied)
        try await dictate(state, untilHistoryHas: 1)
        XCTAssertEqual(state.recoveredText, "Ping test")
        XCTAssertEqual(state.waitingWords?.words, "Ping test")
        XCTAssertTrue(offersCopyLast(state))

        state.deleteHistoryEntry(state.history[0])

        XCTAssertNil(state.recoveredText, "the only copy left of deleted words")
        XCTAssertNil(state.waitingWords, "and the block that showed them")
        XCTAssertFalse(offersCopyLast(state))
    }

    /// Lowering Keep deletes what falls out of it, Copy Last's copy included.
    func testTheKeepLimitDeletesCopyLastWithItsEntry() async throws {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        try await dictate(state, untilHistoryHas: 1)
        harness.transcription.text = "Ship it Friday. Scratch that."
        try await dictate(state, untilHistoryHas: 2)
        XCTAssertTrue(offersCopyLast(state))

        state.historyLimit = 1

        XCTAssertEqual(state.history.map(\.text), ["Ship it Friday. Scratch that."])
        XCTAssertNil(state.lastDictation)
        XCTAssertFalse(offersCopyLast(state))
    }

    /// A take-back as the first take of a run inserts nothing, so Copy Last
    /// still has nothing to copy and is not offered.
    func testATakeBackFirstLeavesNothingToCopy() async throws {
        try harness.installModelMarker()
        harness.transcription.text = "Ship it Friday. Scratch that."
        let state = harness.makeState()
        await state.refreshModelState()

        try await dictate(state, untilHistoryHas: 1)

        XCTAssertNil(state.lastDictation)
        XCTAssertEqual(state.history.count, 1, "History keeps the raw words")
        XCTAssertFalse(offersCopyLast(state))
    }
}

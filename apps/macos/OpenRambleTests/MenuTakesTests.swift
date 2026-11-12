import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest

/// The menu's first rows: the last three takes this run inserted.
///
/// A click pastes a take where the person is and Option-click copies it.
/// They are the words that were inserted, not History's, and each lives only
/// as long as its History entry.
@MainActor
final class MenuTakesTests: XCTestCase {
    private var harness: AppHarness!

    override func setUp() async throws { harness = try AppHarness() }
    override func tearDown() async throws { harness.tearDown() }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func ready() async throws -> AppState {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        return state
    }

    /// Say `words` and wait for the take to end.
    private func dictate(_ words: String, _ state: AppState) async throws {
        let before = state.history.count
        harness.transcription.text = words
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.history.count == before || state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.history.count, before + 1)
    }

    private func takeRows(_ state: AppState) -> [MenuRow] {
        MenuSections.sections(for: state).joined().filter {
            if case .take = $0 { return true }
            return false
        }
    }

    func testTheMenuOffersTheLastThreeTakesNewestFirst() async throws {
        let state = try await ready()
        XCTAssertEqual(state.menuTakes, [])
        XCTAssertEqual(takeRows(state), [])

        for words in ["One.", "Two.", "Three.", "Four."] { try await dictate(words, state) }

        XCTAssertEqual(state.menuTakes, ["Four.", "Three.", "Two."])
        XCTAssertEqual(takeRows(state), [.take(0), .take(1), .take(2)])
        XCTAssertEqual(state.lastTakeText, "Four.", "the first row is the last take, the one the chord pastes")
    }

    func testSayingTheSameThingTwiceIsOneRow() async throws {
        let state = try await ready()
        for words in ["Same.", "Same.", "Other."] { try await dictate(words, state) }

        XCTAssertEqual(state.menuTakes, ["Other.", "Same."])
    }

    func testAClickOnAnEarlierTakePastesItAndTheLastTakeStaysTheLast() async throws {
        let state = try await ready()
        try await dictate("First thought.", state)
        try await dictate("Second thought.", state)

        state.pasteTake(at: 1)
        for _ in 0..<400 {
            if await harness.inserter.insertedTexts.count == 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["First thought.", "Second thought.", "First thought."])
        XCTAssertEqual(state.lastTakeText, "Second thought.")
        XCTAssertEqual(state.menuTakes, ["Second thought.", "First thought."], "pasting does not reorder")
        XCTAssertEqual(harness.copied, [])
    }

    func testTheFirstRowPastesTheLastTakeAsTheChordDoes() async throws {
        let state = try await ready()
        try await dictate("First thought.", state)
        try await dictate("Second thought.", state)

        state.pasteTake(at: 0)
        for _ in 0..<400 {
            if await harness.inserter.insertedTexts.count == 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted.last, "Second thought.")
    }

    func testOptionClickCopiesTheTakeAndPastesNothing() async throws {
        let state = try await ready()
        try await dictate("First thought.", state)
        try await dictate("Second thought.", state)

        state.copyTake(at: 1)
        await settle()

        XCTAssertEqual(harness.copied, ["First thought."])
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["First thought.", "Second thought."], "only the two takes themselves")
        XCTAssertEqual(state.lastNotice?.message, "Copied — to this Mac only.")
    }

    /// Not a second history: a take leaves the menu with its History entry,
    /// by a delete or by Delete All.
    func testATakeLeavesTheMenuWithItsHistoryEntry() async throws {
        let state = try await ready()
        for words in ["One.", "Two.", "Three."] { try await dictate(words, state) }
        XCTAssertEqual(state.menuTakes, ["Three.", "Two.", "One."])

        state.deleteHistoryEntry(try XCTUnwrap(state.history.first { $0.text == "Two." }))
        XCTAssertEqual(state.menuTakes, ["Three.", "One."])

        state.deleteHistoryEntry(try XCTUnwrap(state.history.first { $0.text == "Three." }))
        XCTAssertEqual(state.menuTakes, ["One."], "the last take went with its entry too")

        state.clearHistory()
        XCTAssertEqual(state.menuTakes, [])
        XCTAssertEqual(takeRows(state), [])
    }

    /// History keeps a take the person took back as it was heard, so it can
    /// be undone there. The menu offers only what was inserted.
    func testWordsThePersonTookBackAreNotOffered() async throws {
        let state = try await ready()
        try await dictate("Keep this.", state)
        try await dictate("Ship it Friday. Scratch that.", state)

        XCTAssertEqual(state.history.map(\.text), ["Ship it Friday. Scratch that.", "Keep this."])
        XCTAssertEqual(state.menuTakes, ["Keep this."])
    }

    func testTheTakesAreThisRunsAndARelaunchStartsEmpty() async throws {
        let state = try await ready()
        try await dictate("Before the relaunch.", state)
        XCTAssertEqual(state.menuTakes, ["Before the relaunch."])

        let relaunched = harness.makeState()
        XCTAssertEqual(relaunched.history.count, 1, "History kept it")
        XCTAssertEqual(relaunched.menuTakes, [], "the menu's copies were in memory only")
    }

    /// Words that could not land lead the menu, and the take before them is
    /// still offered. Pasting that earlier take says nothing about the
    /// waiting words: they keep waiting.
    func testAnEarlierTakePastedWhileWordsWaitLeavesThemWaiting() async throws {
        let state = try await ready()
        try await dictate("Earlier words.", state)
        await harness.inserter.setError(.pasteNotRead)
        harness.transcription.text = "Words that wait."
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.waitingWords == nil || state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.menuTakes, ["Words that wait.", "Earlier words."])

        await harness.inserter.setError(nil)
        state.pasteTake(at: 1)
        for _ in 0..<400 where state.dictationState != .idle || state.lastNotice == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted.last, "Earlier words.")
        XCTAssertEqual(state.waitingWords?.words, "Words that wait.", "still waiting for their own paste")
        XCTAssertEqual(state.lastTakeText, "Words that wait.")
    }

    // MARK: The shortcut column

    /// A menu prints a shortcut in its own column when it has a name for the
    /// key. Letters, the named keys and the function row all do.
    func testAShortcutBecomesAMenuShortcut() {
        XCTAssertEqual(
            KeyCombination.controlCommandV.menuShortcut,
            KeyboardShortcut("v", modifiers: [.control, .command])
        )
        XCTAssertEqual(
            KeyCombination.shiftControlCommandR.menuShortcut,
            KeyboardShortcut("r", modifiers: [.control, .command, .shift])
        )
        XCTAssertEqual(
            KeyCombination(keyCode: UInt16(kVK_Space), modifiers: [.option]).menuShortcut,
            KeyboardShortcut(.space, modifiers: [.option])
        )
        let f13 = KeyCombination(keyCode: UInt16(kVK_F13), modifiers: []).menuShortcut
        XCTAssertEqual(f13?.modifiers, [])
        XCTAssertEqual(f13?.key.character.unicodeScalars.first?.value, UInt32(NSF13FunctionKey))
    }
}

import AppKit
import DictationCore
import XCTest

/// The block AppState drives while words wait, recorded.
@MainActor
final class RecordingWaitingOverlay: OverlayPresenting, WaitingWordsPresenting {
    var onWaitingAction: (() -> Void)?
    var onWaitingLater: (() -> Void)?
    private(set) var shown: [WaitingWords?] = []
    private(set) var outcomes: [TakeOutcome] = []
    private(set) var keyDown: [Bool] = []
    private(set) var key: DictationHotkey?

    nonisolated func present(_ state: DictationState, elapsed: TimeInterval) async {}
    nonisolated func dismiss() async {}
    nonisolated func presentNotice(_ notice: DictationNotice) async {}

    func setWaiting(_ waiting: WaitingWords?, key: DictationHotkey) {
        shown.append(waiting)
        self.key = key
    }

    func showOutcome(_ outcome: TakeOutcome) { outcomes.append(outcome) }
    func setKeyDown(_ down: Bool) { keyDown.append(down) }
}

/// Words that could not land wait where the person works.
///
/// One tap of the dictation key pastes them, or copies them while typing is
/// protected. Later keeps them in History, one chord away. Holding the key
/// starts a new take. Nothing sends anyone to the menu bar.
@MainActor
final class AppStateWaitingWordsTests: XCTestCase {
    private var harness: AppHarness!
    private var block: RecordingWaitingOverlay!

    override func setUp() async throws {
        harness = try AppHarness()
        block = RecordingWaitingOverlay()
        harness.overlayOverride = block
        harness.inserter.frontmost = TargetApplication(
            bundleIdentifier: "com.apple.Notes", processIdentifier: 42, localizedName: "Notes"
        )
        // A press here is a tap however slow the machine is. A loaded runner
        // once took longer than a short limit between press and release, and
        // the tap became a hold. The tests about a hold set their own limit.
        harness.waitingTapLimit = .seconds(30)
    }

    override func tearDown() async throws { harness.tearDown() }

    private func settle(_ iterations: Int = 30) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A take whose paste fails with `failure`, at rest again.
    private func takeThatCannotLand(_ failure: TextInsertionError) async throws -> AppState {
        try harness.installModelMarker()
        let state = harness.makeState()
        await state.refreshModelState()
        await harness.inserter.setError(failure)
        harness.monitor.onPress?()
        await settle()
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.waitingWords == nil || state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        return state
    }

    private func tap() async {
        harness.monitor.onPress?()
        await settle(4)
        harness.monitor.onRelease?()
        await settle()
    }

    // MARK: The words stay

    func testWordsThatCannotLandWaitOnTheBlock() async throws {
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")
        let state = try await takeThatCannotLand(.secureInputActive)

        XCTAssertEqual(
            state.waitingWords,
            WaitingWords(words: "Ping test", cause: .typingProtected(by: "Terminal"))
        )
        XCTAssertEqual(block.shown.last, state.waitingWords, "on the block, in full")
        XCTAssertEqual(block.key, .rightCommand, "with the key the person uses")
        XCTAssertEqual(state.lastTakeText, "Ping test")
        XCTAssertEqual(state.history.first?.text, "Ping test", "and already in History")
        XCTAssertEqual(harness.copied, [], "nothing reaches the clipboard unasked")
    }

    /// Whatever the paste itself reported, protected typing is the reason
    /// that decides what the key can do.
    func testProtectedTypingIsTheReasonWhateverThePasteReported() async throws {
        harness.typingProtection = TypingProtection(isOn: true, holder: nil)
        let state = try await takeThatCannotLand(.pasteNotRead)
        XCTAssertEqual(state.waitingWords?.cause, .typingProtected(by: nil))
    }

    /// Change the dictation key while words wait, and the block names the
    /// key that works now.
    func testTheBlockNamesTheKeyInUse() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)
        state.hotkey = .rightOption
        XCTAssertEqual(block.key, .rightOption)
        XCTAssertEqual(block.shown.last, state.waitingWords)
    }

    // MARK: A tap

    func testATapPastesOnceThereIsAField() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)
        XCTAssertEqual(state.waitingWords?.cause, .noTextField)

        await harness.inserter.setError(nil)
        await tap()

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"])
        XCTAssertNil(state.waitingWords)
        XCTAssertEqual(block.outcomes, [.pasted(into: "Notes")])
        let takes = await harness.capture.startCount
        XCTAssertEqual(takes, 1, "the tap opened no microphone")
        XCTAssertEqual(harness.copied, [], "the paste borrows the clipboard and gives it back")
        XCTAssertEqual(state.lastTakeText, "Ping test", "still the last take")
    }

    func testATapCopiesWhileTypingIsProtected() async throws {
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")
        let state = try await takeThatCannotLand(.secureInputActive)

        await tap()

        XCTAssertEqual(harness.copied, ["Ping test"])
        XCTAssertEqual(state.waitingWords?.isCopied, true, "the block says what to press next")
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, [], "a paste of ours could not have landed")
        XCTAssertEqual(block.outcomes, [])
    }

    /// The drawn key answers the real one.
    func testTheKeyCapGoesDownWithTheKey() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)
        await harness.inserter.setError(nil)

        harness.monitor.onPress?()
        await settle(2)
        XCTAssertEqual(block.keyDown, [true])
        harness.monitor.onRelease?()
        await settle()
        XCTAssertEqual(block.keyDown, [true, false])
        XCTAssertNil(state.waitingWords)
    }

    /// The moment typing works again, the same key pastes.
    func testTypingThatWorksAgainTurnsCopyIntoPaste() async throws {
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")
        let state = try await takeThatCannotLand(.secureInputActive)

        harness.typingProtection = .off
        for _ in 0..<200 where state.waitingWords?.cause != .typingWorksAgain {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.waitingWords?.cause, .typingWorksAgain)
        XCTAssertEqual(state.waitingWords?.action, .paste)

        await harness.inserter.setError(nil)
        await tap()

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"])
        XCTAssertEqual(harness.copied, [])
        XCTAssertNil(state.waitingWords)
    }

    /// A tap that fails again leaves the words where they are, with the
    /// reason that is true now.
    func testATapThatFailsKeepsTheWordsWithTheNewReason() async throws {
        let state = try await takeThatCannotLand(.accessibilityPermissionDenied)
        XCTAssertEqual(state.waitingWords?.cause, .notPasted)

        await harness.inserter.setError(.pasteNotRead)
        await tap()

        XCTAssertEqual(state.waitingWords?.words, "Ping test")
        XCTAssertEqual(state.waitingWords?.cause, .noTextField)
        XCTAssertEqual(block.outcomes, [])
        XCTAssertEqual(state.dictationState, .idle)
    }

    /// The monitor swallows a first tap's release when a second follows. That
    /// second tap is the tap: hands-free never starts while words wait, and
    /// no hold is left running to open a microphone with the key up.
    func testADoubleTapIsATapAndNeverHandsFree() async throws {
        harness.waitingTapLimit = .milliseconds(100)
        let state = try await takeThatCannotLand(.pasteNotRead)
        await harness.inserter.setError(nil)

        // Nothing suspends between the press and the second tap, so the hold
        // cannot begin first. The wait is longer than the limit: a hold left
        // running would start a take inside it.
        harness.monitor.onPress?()
        harness.monitor.onDoubleTap?()
        await settle()
        try await Task.sleep(for: .milliseconds(250))

        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"])
        XCTAssertFalse(state.isHandsFreeActive)
        let takes = await harness.capture.startCount
        XCTAssertEqual(takes, 1, "no take started")
        XCTAssertEqual(state.dictationState, .idle)
    }

    // MARK: A hold

    /// Holding the key is dictating again. The waiting words are already in
    /// History; the new take is the news.
    func testAHoldStartsANewTake() async throws {
        harness.waitingTapLimit = .milliseconds(50)
        let state = try await takeThatCannotLand(.pasteNotRead)
        await harness.inserter.setError(nil)

        harness.monitor.onPress?()
        for _ in 0..<400 where state.waitingWords != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()

        XCTAssertNil(state.waitingWords)
        let takes = await harness.capture.startCount
        XCTAssertEqual(takes, 2, "the microphone is open")
        XCTAssertEqual(block.outcomes, [], "filed quietly")

        harness.monitor.onRelease?()
        for _ in 0..<400 where state.dictationState != .idle {
            try await Task.sleep(for: .milliseconds(5))
        }
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"], "the new take landed; the old one stayed in History")
        XCTAssertEqual(state.history.count, 2)
    }

    /// A chord over the held key is a shortcut, not a tap and not a take.
    func testAChordOverWaitingWordsDoesNothing() async throws {
        harness.waitingTapLimit = .milliseconds(100)
        let state = try await takeThatCannotLand(.pasteNotRead)
        await harness.inserter.setError(nil)

        // Nothing suspends between the press and the chord, so the hold cannot
        // begin first. The wait is longer than the limit: a hold the chord
        // did not end would start a take inside it.
        harness.monitor.onPress?()
        harness.monitor.onAbortShortcut?()
        try await Task.sleep(for: .milliseconds(250))
        await settle()

        XCTAssertNotNil(state.waitingWords, "the words still wait")
        let takes = await harness.capture.startCount
        XCTAssertEqual(takes, 1)
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(block.keyDown.last, false)
    }

    /// Copied words have nothing left to press: the key dictates at once.
    func testAfterACopyTheKeyDictatesAgain() async throws {
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")
        let state = try await takeThatCannotLand(.secureInputActive)
        await tap()
        XCTAssertEqual(state.waitingWords?.isCopied, true)

        harness.monitor.onPress?()
        await settle()

        XCTAssertNil(state.waitingWords)
        let takes = await harness.capture.startCount
        XCTAssertEqual(takes, 2, "no half-second wait: the first word is in the start")
        harness.monitor.onRelease?()
        await settle()
    }

    // MARK: Later

    func testLaterKeepsTheWordsOneChordAway() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)

        block.onWaitingLater?()

        XCTAssertNil(state.waitingWords)
        XCTAssertEqual(block.outcomes, [.kept(chord: "⌃⌘V")])
        XCTAssertEqual(state.lastTakeText, "Ping test")

        await harness.inserter.setError(nil)
        harness.copyMonitor.onPress?()
        await settle()
        let inserted = await harness.inserter.insertedTexts
        XCTAssertEqual(inserted, ["Ping test"], "⌃⌘V pastes it")
        XCTAssertEqual(block.outcomes, [.kept(chord: "⌃⌘V")], "a paste that was not waited for lands in silence")
    }

    /// Escape is Later, wherever it can be heard.
    func testEscapeIsLater() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)
        harness.monitor.onEscape?()
        XCTAssertNil(state.waitingWords)
        XCTAssertEqual(block.outcomes, [.kept(chord: "⌃⌘V")])
        XCTAssertNil(state.lastNotice.flatMap { $0.message.contains("cancelled") ? $0 : nil }, "nothing was cancelled")
    }

    /// With the chord cleared, Later does not promise one.
    func testLaterWithoutAChordDoesNotNameOne() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)
        state.lastTakeShortcut = nil
        state.keepWaitingWordsForLater()
        XCTAssertEqual(block.outcomes, [.kept(chord: nil)])
    }

    /// The click on the block's first button is the tap.
    func testClickingTheBlockIsTheTap() async throws {
        let state = try await takeThatCannotLand(.pasteNotRead)
        await harness.inserter.setError(nil)

        block.onWaitingAction?()
        await settle()

        XCTAssertNil(state.waitingWords)
        XCTAssertEqual(block.outcomes, [.pasted(into: "Notes")])
    }

    // MARK: The chord

    /// ⌃⌘V over waiting words is the tap: it copies while typing is
    /// protected, which is the one time a key event monitor would not hear it.
    func testTheChordOverProtectedWordsCopies() async throws {
        harness.typingProtection = TypingProtection(isOn: true, holder: "Terminal")
        let state = try await takeThatCannotLand(.secureInputActive)

        harness.copyMonitor.onPress?()
        await settle()

        XCTAssertEqual(harness.copied, ["Ping test"])
        XCTAssertEqual(state.waitingWords?.isCopied, true)
    }

    // MARK: Leaving

    /// A take that lands is the newest take. Nothing older waits.
    func testANewTakeThatLandsTakesTheBlockAway() async throws {
        harness.waitingTapLimit = .milliseconds(50)
        let state = try await takeThatCannotLand(.pasteNotRead)
        await harness.inserter.setError(nil)
        harness.transcription.text = "Second take"

        harness.monitor.onPress?()
        for _ in 0..<400 where state.waitingWords != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await settle()
        harness.monitor.onRelease?()
        for _ in 0..<400 where state.lastDictation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNil(state.waitingWords)
        XCTAssertNil(state.recoveredText)
        XCTAssertEqual(state.lastTakeText, "Second take")
    }

    /// The rare take History could not keep: the block says so, and Later
    /// does not claim the words are in History.
    func testATakeHistoryCouldNotKeepSaysSoOnTheBlock() async throws {
        let support = try AppPaths(root: harness.root).support()
        FileManager.default.createFile(atPath: support.appending(path: "History").path, contents: Data())
        let state = try await takeThatCannotLand(.pasteNotRead)

        XCTAssertEqual(state.waitingWords?.isKeptNowhereElse, true)
        XCTAssertEqual(state.waitingWords?.note, "This dictation couldn't be saved to History.")

        state.keepWaitingWordsForLater()
        XCTAssertEqual(block.outcomes, [.kept(inHistory: false, chord: "⌃⌘V")])
        XCTAssertEqual(state.lastTakeText, "Ping test", "one chord away, for as long as the app runs")
    }
}

import DictationCore
import XCTest

/// What the take block says, and what the key does, while words wait.
///
/// The redesign started from one notice: "Text not inserted: secure input is
/// active. Your text is saved in the menu." It could not be clicked, left
/// after four seconds, and sent the person to a menu that may not even be on
/// screen. These tests pin the answer: the words stay where the person works,
/// with the reason in plain words and one action on the dictation key.
@MainActor
final class WaitingWordsTests: XCTestCase {
    private let words = "The deploy passed. Let's ship the menu bar fix on Monday."

    /// Our ⌘V went out and nobody read it while typing is protected. The
    /// person's own gets through whatever stopped it, so the key copies.
    func testProtectedTypingMakesTheKeyCopy() {
        let waiting = WaitingWords(words: words, cause: .init(.secureInputActive, protectedBy: "Terminal"))
        XCTAssertEqual(waiting.cause, .typingProtected(by: "Terminal"))
        XCTAssertEqual(waiting.action, .copy)
        XCTAssertEqual(waiting.actionVerb, "copies")
        XCTAssertEqual(waiting.reason(key: "Right ⌘"), "Didn't paste while Terminal protects typing.")
        XCTAssertEqual(waiting.glyph, .waiting)
    }

    /// Secure input is one system-wide state, so the holder is a guess, and
    /// sometimes there is none to make. The sentence never invents one.
    func testAnUnknownHolderIsNotNamed() {
        let waiting = WaitingWords(words: words, cause: .init(.secureInputActive))
        XCTAssertEqual(waiting.reason(key: "Right ⌘"), "Didn't paste while typing is protected.")
    }

    /// ⌘V was sent and nothing read it: focus is not in a text field. The
    /// reason is also the instruction, with the key the person actually uses.
    func testNoTextFieldSaysWhereToClickAndWhatToTap() {
        let waiting = WaitingWords(words: words, cause: .init(.pasteNotRead))
        XCTAssertEqual(waiting.cause, .noTextField)
        XCTAssertEqual(waiting.action, .paste)
        XCTAssertEqual(waiting.actionVerb, "pastes")
        XCTAssertEqual(waiting.reason(key: "Right ⌥"), "No text field. Click one, then tap Right ⌥.")
    }

    /// Every other failure has the same answer: try the paste again.
    func testAnyOtherFailureIsAPasteToTryAgain() {
        for failure in [
            TextInsertionError.targetChanged, .targetUnavailable, .modifiersStillHeld,
            .clipboardWriteFailed, .insertionInProgress, .accessibilityPermissionDenied,
        ] {
            let waiting = WaitingWords(words: words, cause: .init(failure))
            XCTAssertEqual(waiting.cause, .notPasted, "\(failure)")
            XCTAssertEqual(waiting.action, .paste, "\(failure)")
        }
        XCTAssertEqual(WaitingWords.Cause(nil), .notPasted, "a paste that timed out reports nothing")
    }

    /// Once copied, nothing is left to press: the block says what to do with
    /// the person's own hands, and the sign is the copy sign, in ink.
    func testCopiedWordsSayToPressPaste() {
        var waiting = WaitingWords(words: words, cause: .typingProtected(by: "Terminal"))
        waiting.isCopied = true
        XCTAssertEqual(waiting.reason(key: "Right ⌘"), "Copied. Press ⌘V to paste.")
        XCTAssertEqual(waiting.glyph, .copied)
        XCTAssertNil(waiting.glyph.colorRole, "the words still wait, but nothing here is an alarm")
    }

    /// The moment typing works again, the key pastes again.
    func testTypingThatWorksAgainMakesTheKeyPaste() {
        let waiting = WaitingWords(words: words, cause: .typingWorksAgain)
        XCTAssertEqual(waiting.action, .paste)
        XCTAssertEqual(waiting.reason(key: "Right ⌘"), "Typing works again.")
    }

    /// VoiceOver hears the state, the reason and the key's job. Never the
    /// words: they would be read to the room.
    func testVoiceOverHearsEverythingButTheWords() {
        let waiting = WaitingWords(words: words, cause: .typingProtected(by: "Terminal"))
        let label = waiting.accessibilityLabel(keyName: "Right Command", key: "Right ⌘")
        XCTAssertEqual(
            label,
            "Words waiting. Didn't paste while Terminal protects typing. Right Command copies."
        )
        XCTAssertFalse(label.contains("deploy"))
    }

    /// Every sentence exists in Russian, with the same holes.
    func testRussianSaysTheSameThings() {
        let original = L10n.shared.language
        defer { L10n.shared.language = original }
        L10n.shared.language = .russian

        let blocked = WaitingWords(words: words, cause: .typingProtected(by: "Терминал"))
        XCTAssertEqual(blocked.reason(key: "Правый ⌘"), "Не вставилось, пока Терминал защищает ввод.")
        XCTAssertEqual(blocked.actionVerb, "скопирует")
        XCTAssertEqual(DictationHotkey.rightCommand.shortTitle, "Правый ⌘")
        XCTAssertEqual(
            TakeOutcome.kept(chord: "⌃⌘V").message,
            "Сохранено в истории. ⌃⌘V вставит."
        )
        XCTAssertEqual(TakeOutcome.pasted(into: "Заметки").message, "Вставлено в Заметки.")
    }

    // MARK: How it ends

    /// Green is for the paste alone. Kept is not success and not waiting,
    /// and a copy is neither: both are drawn in ink. The glass itself is
    /// never tinted; the glyph is the one place a state has a color.
    func testOnlyAPasteIsGreen() {
        XCTAssertEqual(TakeOutcome.pasted(into: "Notes").glyph, .pasted)
        XCTAssertEqual(TakeOutcome.pasted(into: "Notes").glyph.colorRole, .success)
        XCTAssertEqual(TakeOutcome.kept(chord: "⌃⌘V").glyph, .kept)
        XCTAssertNil(TakeOutcome.kept(chord: "⌃⌘V").glyph.colorRole)
    }

    func testOutcomesSayWhereTheWordsAre() {
        XCTAssertEqual(TakeOutcome.pasted(into: "Notes").message, "Pasted into Notes.")
        XCTAssertEqual(TakeOutcome.pasted(into: nil).message, "Pasted.")
        XCTAssertEqual(TakeOutcome.kept(chord: "⌃⌘V").message, "Kept in History. ⌃⌘V pastes it.")
        XCTAssertEqual(TakeOutcome.kept(chord: nil).message, "Kept in History.")
    }

    /// The rare take History could not keep: the block says so, and Later
    /// never claims the words are somewhere they are not.
    func testATakeHistoryCouldNotKeepIsNotCalledKept() {
        let waiting = WaitingWords(words: words, cause: .notPasted, isKeptNowhereElse: true)
        XCTAssertEqual(waiting.note, "This dictation couldn't be saved to History.")
        XCTAssertNil(WaitingWords(words: words, cause: .notPasted).note)
        XCTAssertEqual(
            TakeOutcome.kept(inHistory: false, chord: "⌃⌘V").message,
            "⌃⌘V pastes it until you quit."
        )
    }

    /// The key cap shows the key the person chose, short enough to draw.
    func testEveryDictationKeyHasACap() {
        XCTAssertEqual(DictationHotkey.rightCommand.shortTitle, "Right ⌘")
        XCTAssertEqual(DictationHotkey.fn.shortTitle, "Fn")
        for key in DictationHotkey.allCases {
            XCTAssertLessThanOrEqual(key.shortTitle.count, 8, "\(key)")
        }
    }

    // MARK: On the block

    private func content(
        state: DictationState = .idle,
        notice: DictationNotice? = nil,
        waiting: WaitingWords? = nil,
        outcome: TakeOutcome? = nil
    ) -> OverlayContent {
        OverlayContent.make(state: state, notice: notice, elapsed: 0, waiting: waiting, outcome: outcome)
    }

    /// Waiting words are the block's whole content: wider, with the orange
    /// bar, and out of every capture for as long as it shows what was said.
    func testTheBlockGrowsToHoldTheWords() {
        let waiting = WaitingWords(words: words, cause: .noTextField)
        let block = content(waiting: waiting)
        XCTAssertEqual(block.waiting, waiting)
        XCTAssertEqual(block.glyph, .waiting)
        XCTAssertEqual(block.glyph?.colorRole, .attention)
        XCTAssertEqual(block.panelWidth, 384)
        XCTAssertTrue(block.showsDictatedWords)
        XCTAssertFalse(content(state: .listening).showsDictatedWords)
        XCTAssertFalse(content(outcome: .kept(chord: nil)).showsDictatedWords)
    }

    /// A take in progress is the news. Words wait only at rest.
    func testALiveTakeOutranksWaitingWords() {
        let waiting = WaitingWords(words: words, cause: .noTextField)
        for state in [DictationState.preparing, .listening, .transcribing] {
            XCTAssertNil(content(state: state, waiting: waiting).waiting, "\(state)")
        }
        XCTAssertNotNil(content(state: .inserting, waiting: waiting).waiting, "the tap's own paste")
    }

    /// How it ended is the last word, over everything.
    func testAnOutcomeIsTheLastWord() {
        let waiting = WaitingWords(words: words, cause: .noTextField)
        let block = content(waiting: waiting, outcome: .pasted(into: "Notes"))
        XCTAssertNil(block.waiting)
        XCTAssertEqual(block.outcome, .pasted(into: "Notes"))
        XCTAssertEqual(block.glyph, .pasted)
        XCTAssertEqual(block.voice, .speech("Pasted into Notes.", urgent: false))
    }
}

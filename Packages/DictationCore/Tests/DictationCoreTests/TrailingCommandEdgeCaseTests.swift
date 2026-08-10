import XCTest
@testable import DictationCore

/// Parsing the final command is the most dangerous part of the pipeline.
///
/// An error in one direction eats a word from the text, in the other direction it presses Return
/// in someone else's window. The click cannot be recalled: the message will go away and the form will be sent.
/// Therefore, the command should be recognized only where the person intended it.
final class TrailingCommandEdgeCaseTests: XCTestCase {

    // MARK: - Command inside a word

    func testWordThatMerelyEndsLikeACommandIsNotACommand() {
        // “Resend” and “send” are common words. If you consider them a team,
        // the word will disappear from the text, and pressing Return will go to the application.
        for text in ["\u{043F}\u{0438}\u{0441}\u{044C}\u{043C}\u{043E} \u{043F}\u{0435}\u{0440}\u{0435}\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}\u{0442}\u{0435}", "\u{043D}\u{0430}\u{0434}\u{043E} \u{043F}\u{0435}\u{0440}\u{0435}\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{0442}\u{044C}"] {
            let result = TrailingCommandParser.parse(text)

            XCTAssertNil(result.command, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442}: \(text)")
            XCTAssertEqual(result.text, text)
        }
    }

    func testCommandGluedToPreviousWordIsNotACommand() {
        // Without a space before the command, it is part of a word, not a separate word.
        let result = TrailingCommandParser.parse("\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertNil(result.command)
        XCTAssertEqual(result.text, "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")
    }

    // MARK: - Register

    func testCommandIsRecognizedRegardlessOfCase() {
        // The model capitalizes the phrase at the beginning and after the period, and the command could
        // be exactly there. The command recognition depends on the register
        // should not, but the text before it must retain its own.
        let result = TrailingCommandParser.parse("\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}, \u{041E}\u{0422}\u{041F}\u{0420}\u{0410}\u{0412}\u{042C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}")
    }

    func testTextKeepsItsOwnCaseAfterCommandIsCutOff() {
        let result = TrailingCommandParser.parse("\u{041F}\u{0438}\u{0448}\u{0438} \u{0414}\u{0438}\u{043C}\u{0435} \u{0432} Telegram \u{041E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{041F}\u{0438}\u{0448}\u{0438} \u{0414}\u{0438}\u{043C}\u{0435} \u{0432} Telegram")
    }

    // MARK: - Unicode

    func testTextWithUnusualLettersIsCutCorrectly() {
        // "İ" becomes two characters when converted to lowercase, and
        // the length of the string changes. If you cut the text according to the positions found in
        // the given copy will be cut off in the wrong place: the user will get crippled
        // a word instead of its own text.
        let result = TrailingCommandParser.parse("\u{041B}\u{0435}\u{0442}\u{0438}\u{043C} \u{0432} İstanbul \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{041B}\u{0435}\u{0442}\u{0438}\u{043C} \u{0432} İstanbul")
    }

    func testEmojiBeforeCommandSurvives() {
        let result = TrailingCommandParser.parse("\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} 🎉 \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} 🎉")
    }

    // MARK: - Several commands in a row

    func testOnlyTheLastCommandIsTakenOff() {
        // The person repeated the command or the model heard it twice. Shoot smoothly
        // one: the rest is text, and it’s up to the user to decide what he meant,
        // we won't.
        let result = TrailingCommandParser.parse("\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")
    }

    func testDifferentCommandsInARowLeaveOnlyTheLastOne() {
        let result = TrailingCommandParser.parse("\u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")
    }

    // MARK: - Empty after the command

    func testDictationConsistingOnlyOfTheCommandStaysText() {
        // Previously, such a dictation went nowhere: there was no text left,
        // and inserting an empty line along with it canceled pressing Return -
        // the person pressed a key, said a word and received nothing.
        //
        // One word is a word. Press Return in someone else's window based on this guess
        // impossible: the sent message is not recalled.
        for text in ["\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", "\u{041E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}.", "\u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"] {
            let result = TrailingCommandParser.parse(text)

            XCTAssertNil(result.command, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442}: \(text)")
            XCTAssertFalse(result.text.isEmpty, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442}: \(text)")
        }
    }

    func testCommandAfterPunctuationOnlyTextStaysText() {
        // After removing the command, only punctuation marks remain - meaning
        // there is no text, and this is the same case as the command alone.
        let result = TrailingCommandParser.parse(", \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertNil(result.command)
    }

    // MARK: - Tail of the phrase

    func testTrailingPunctuationAndSpacesDoNotHideTheCommand() {
        for text in ["\u{0432}\u{0441}\u{0451} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}, \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}.", "\u{0432}\u{0441}\u{0451} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}!  ", "\u{0432}\u{0441}\u{0451} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}: \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}..."] {
            let result = TrailingCommandParser.parse(text)

            XCTAssertEqual(result.command, .pressReturn, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442}: \(text)")
            XCTAssertEqual(result.text, "\u{0432}\u{0441}\u{0451} \u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}", "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442}: \(text)")
        }
    }

    func testEnglishMultiWordCommandWorks() {
        let result = TrailingCommandParser.parse("looks good send it")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "looks good")
    }

    func testNewLineCommandIsRecognizedSeparately() {
        let result = TrailingCommandParser.parse("\u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{0439} \u{043F}\u{0443}\u{043D}\u{043A}\u{0442} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")

        XCTAssertEqual(result.command, .newLine)
        XCTAssertEqual(result.text, "\u{043F}\u{0435}\u{0440}\u{0432}\u{044B}\u{0439} \u{043F}\u{0443}\u{043D}\u{043A}\u{0442}")
    }

    // MARK: - Empty input

    func testEmptyInputHasNeitherTextNorCommand() {
        let result = TrailingCommandParser.parse("   \n  ")

        XCTAssertNil(result.command)
        XCTAssertTrue(result.text.isEmpty)
    }
}

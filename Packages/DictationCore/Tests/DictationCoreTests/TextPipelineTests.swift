import XCTest
@testable import DictationCore

final class TranscriptPolisherTests: XCTestCase {
    func testRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} , \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430} ?"),
            "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}?"
        )
    }

    func testAddsSpaceOnlyBeforeNewSentence() {
        // A capital letter after a dot means a new sentence - there is a space there
        // really needed.
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}.\u{041F}\u{043E}\u{0439}\u{0434}\u{0451}\u{043C} \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"),
            "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}. \u{041F}\u{043E}\u{0439}\u{0434}\u{0451}\u{043C} \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}"
        )
    }

    func testDoesNotBreakNumbersVersionsDomainsAndAbbreviations() {
        // All of the above actually comes from the model: it itself transforms
        // “three and fourteen hundredths” in “3.14”. Previously, processing put a space
        // after any period and collapsed numbers, versions, domains and abbreviations.
        let untouched = [
            "Testing numbers like 3.14 and dates like January 5.",
            "\u{0412}\u{0435}\u{0440}\u{0441}\u{0438}\u{044F} 2.0.1 \u{0432}\u{044B}\u{0448}\u{043B}\u{0430}",
            "\u{0421}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} \u{043D}\u{0430} wai.computer",
            "\u{042D}\u{0442}\u{043E} \u{0442}.\u{0434}. \u{0438} \u{0442}.\u{043F}.",
            "\u{0426}\u{0435}\u{043D}\u{0430} 1,500 \u{0440}\u{0443}\u{0431}\u{043B}\u{0435}\u{0439}",
        ]

        for input in untouched {
            let output = TranscriptPolisher.polish(input)
            XCTAssertEqual(output, input, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0431}\u{044B}\u{043B} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}: \(input)")
        }
    }

    func testSeparatesWordsGluedToAComma() {
        // The model regularly glues the enumeration: “first, second”. Capital
        // no further, and before the space did not appear - the text remained stuck together.
        XCTAssertEqual(TranscriptPolisher.polish("\u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0435},\u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0435}"), "\u{041F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0435}, \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0435}")
        XCTAssertEqual(TranscriptPolisher.polish("\u{0440}\u{0430}\u{0437}, \u{0434}\u{0432}\u{0430},\u{0442}\u{0440}\u{0438},\u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}"), "\u{0420}\u{0430}\u{0437}, \u{0434}\u{0432}\u{0430}, \u{0442}\u{0440}\u{0438}, \u{0447}\u{0435}\u{0442}\u{044B}\u{0440}\u{0435}")
        XCTAssertEqual(TranscriptPolisher.polish("\u{0441}\u{0442}\u{043E}\u{043F}!\u{043F}\u{043E}\u{0435}\u{0445}\u{0430}\u{043B}\u{0438}"), "\u{0421}\u{0442}\u{043E}\u{043F}! \u{043F}\u{043E}\u{0435}\u{0445}\u{0430}\u{043B}\u{0438}")
        XCTAssertEqual(TranscriptPolisher.polish("\u{0447}\u{0442}\u{043E}?\u{043D}\u{0438}\u{0447}\u{0435}\u{0433}\u{043E}"), "\u{0427}\u{0442}\u{043E}? \u{043D}\u{0438}\u{0447}\u{0435}\u{0433}\u{043E}")
        XCTAssertEqual(TranscriptPolisher.polish("\u{0440}\u{0430}\u{0437};\u{0434}\u{0432}\u{0430}"), "\u{0420}\u{0430}\u{0437}; \u{0434}\u{0432}\u{0430}")
    }

    func testDecimalCommaSurvivesTheSameRule() {
        // The only place where the comma is close to the next character
        // to the point, is a decimal fraction. It differs in that the number comes next.
        let untouched = [
            "\u{0421}\u{0442}\u{0430}\u{0432}\u{043A}\u{0430} 3,14 \u{043F}\u{0440}\u{043E}\u{0446}\u{0435}\u{043D}\u{0442}\u{0430}",
            "\u{0426}\u{0435}\u{043D}\u{0430} 1,500 \u{0440}\u{0443}\u{0431}\u{043B}\u{0435}\u{0439}",
            "\u{041A}\u{043E}\u{043E}\u{0440}\u{0434}\u{0438}\u{043D}\u{0430}\u{0442}\u{044B} 55,7558 \u{0438} 37,6173",
        ]
        for input in untouched {
            XCTAssertEqual(TranscriptPolisher.polish(input), input, "\u{041D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}: \(input)")
        }
    }

    func testColonAndPeriodStayConservative() {
        // Colon and period live inside references, times and abbreviations, so
        // they do not add a space to a lowercase letter - the cost of an error is higher than the benefit.
        let untouched = [
            "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} https://wai.computer/openramble/",
            "\u{0412}\u{0441}\u{0442}\u{0440}\u{0435}\u{0447}\u{0430} \u{0432} 12:30",
            "\u{042D}\u{0442}\u{043E} \u{0442}.\u{0434}. \u{0438} \u{0442}.\u{043F}.",
        ]
        for input in untouched {
            XCTAssertEqual(TranscriptPolisher.polish(input), input, "\u{041D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{043E} \u{0438}\u{0437}\u{043C}\u{0435}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}: \(input)")
        }
    }

    func testCollapsesRepeatedSpaces() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0441}\u{043B}\u{0438}\u{0448}\u{043A}\u{043E}\u{043C}   \u{043C}\u{043D}\u{043E}\u{0433}\u{043E}    \u{043F}\u{0440}\u{043E}\u{0431}\u{0435}\u{043B}\u{043E}\u{0432}"),
            "\u{0421}\u{043B}\u{0438}\u{0448}\u{043A}\u{043E}\u{043C} \u{043C}\u{043D}\u{043E}\u{0433}\u{043E} \u{043F}\u{0440}\u{043E}\u{0431}\u{0435}\u{043B}\u{043E}\u{0432}"
        )
    }

    func testKeepsLineBreaks() {
        // Line breaks are meaningful: the user could dictate the list.
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{043F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F}  \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"),
            "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}\n\u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"
        )
    }

    func testCapitalizesOnlyTheFirstLetter() {
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"),
            "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}"
        )
        // We don’t touch the capitalization anymore, we don’t break the abbreviations.
        XCTAssertEqual(TranscriptPolisher.polish("HTTP \u{044D}\u{0442}\u{043E} \u{043F}\u{0440}\u{043E}\u{0442}\u{043E}\u{043A}\u{043E}\u{043B}"), "HTTP \u{044D}\u{0442}\u{043E} \u{043F}\u{0440}\u{043E}\u{0442}\u{043E}\u{043A}\u{043E}\u{043B}")
    }

    func testDoesNotTouchNumbersWrittenAsWords() {
        // We don’t try to expand numerals into numbers: in Russian this is
        // rests on cases and breaks more than it repairs.
        XCTAssertEqual(
            TranscriptPolisher.polish("\u{0434}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{044C} \u{0440}\u{0443}\u{0431}\u{043B}\u{0435}\u{0439}"),
            "\u{0414}\u{0432}\u{0430}\u{0434}\u{0446}\u{0430}\u{0442}\u{044C} \u{043F}\u{044F}\u{0442}\u{044C} \u{0440}\u{0443}\u{0431}\u{043B}\u{0435}\u{0439}"
        )
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(TranscriptPolisher.polish("   "), "")
    }
}

final class DictionaryReplacementsTests: XCTestCase {
    func testReplacesWholeWordsOnly() {
        let replacements = [DictionaryReplacement(spoken: "\u{043A}\u{043E}\u{0434}", written: "code")]

        // "encoding" should not become "encoding".
        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{043A}\u{043E}\u{0434} \u{0438} \u{043A}\u{043E}\u{0434}\u{0438}\u{0440}\u{043E}\u{0432}\u{043A}\u{0430}"),
            "code \u{0438} \u{043A}\u{043E}\u{0434}\u{0438}\u{0440}\u{043E}\u{0432}\u{043A}\u{0430}"
        )
    }

    func testIsCaseInsensitiveOnInput() {
        // Recognition is not case guaranteed, and the result must be stable.
        let replacements = [DictionaryReplacement(spoken: "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", written: "Sentry")]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0421}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438} \u{0443}\u{043F}\u{0430}\u{043B}"),
            "Sentry \u{0443}\u{043F}\u{0430}\u{043B}"
        )
    }

    func testLongerPhrasesWinOverShorterOnes() {
        let replacements = [
            DictionaryReplacement(spoken: "\u{043F}\u{0443}\u{043B}", written: "pull"),
            DictionaryReplacement(spoken: "\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", written: "pull request"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0437}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}"),
            "\u{0437}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B} pull request"
        )
    }

    func testHandlesRussianEnglishMix() {
        // Main product script.
        let replacements = [
            DictionaryReplacement(spoken: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", written: "deploy"),
            DictionaryReplacement(spoken: "\u{0440}\u{0435}\u{0432}\u{044C}\u{044E}", written: "review"),
        ]

        XCTAssertEqual(
            DictionaryReplacements.apply(replacements, to: "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E} \u{0438} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}"),
            "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} review \u{0438} deploy"
        )
    }

    func testEmptyDictionaryLeavesTextIntact() {
        XCTAssertEqual(DictionaryReplacements.apply([], to: "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}"), "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}")
    }
}

final class TrailingCommandParserTests: XCTestCase {
    func testDetectsSendCommandAtTheEnd() {
        let result = TrailingCommandParser.parse("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}")
    }

    func testIgnoresCommandWordInTheMiddle() {
        // "send" in the middle is a regular word, not a command.
        let result = TrailingCommandParser.parse("\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} \u{0435}\u{043C}\u{0443} \u{043F}\u{0438}\u{0441}\u{044C}\u{043C}\u{043E} \u{0437}\u{0430}\u{0432}\u{0442}\u{0440}\u{0430}")

        XCTAssertNil(result.command)
        XCTAssertEqual(result.text, "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} \u{0435}\u{043C}\u{0443} \u{043F}\u{0438}\u{0441}\u{044C}\u{043C}\u{043E} \u{0437}\u{0430}\u{0432}\u{0442}\u{0440}\u{0430}")
    }

    func testToleratesTrailingPunctuation() {
        let result = TrailingCommandParser.parse("\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}, \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}.")

        XCTAssertEqual(result.command, .pressReturn)
        XCTAssertEqual(result.text, "\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}")
    }

    func testTextWithoutCommandStaysWhole() {
        let result = TrailingCommandParser.parse("\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}")

        XCTAssertNil(result.command)
        XCTAssertEqual(result.text, "\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}")
    }
}

final class TextPipelineTests: XCTestCase {
    func testFullPathFromRecognizedToInsertable() {
        let pipeline = TextPipeline(
            replacements: [DictionaryReplacement(spoken: "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}", written: "Sentry")],
            allowPressReturnCommand: true
        )

        let output = pipeline.process("\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438} \u{0441}\u{043D}\u{043E}\u{0432}\u{0430} \u{0443}\u{043F}\u{0430}\u{043B} , \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(output.text, "Sentry \u{0441}\u{043D}\u{043E}\u{0432}\u{0430} \u{0443}\u{043F}\u{0430}\u{043B}, \u{043F}\u{043E}\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438}")
        XCTAssertEqual(output.command, .pressReturn)
    }

    func testCommandIsStrippedBeforeDictionaryRuns() {
        // Order is important: if you apply the dictionary first, it may affect
        // the command word will no longer be recognized.
        let pipeline = TextPipeline(
            replacements: [DictionaryReplacement(spoken: "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}", written: "\u{041E}\u{0422}\u{041F}\u{0420}\u{0410}\u{0412}\u{042C}")],
            allowPressReturnCommand: true
        )

        let output = pipeline.process("\u{0433}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(output.command, .pressReturn)
        XCTAssertEqual(output.text, "\u{0413}\u{043E}\u{0442}\u{043E}\u{0432}\u{043E}")
    }

    func testEmptyRecognitionProducesEmptyOutput() {
        let output = TextPipeline().process("   ")

        XCTAssertEqual(output.text, "")
        XCTAssertNil(output.command)
    }

    func testSafeBetaDoesNotExecuteSpokenSendCommand() {
        let output = TextPipeline().process("\u{0432}\u{0430}\u{0436}\u{043D}\u{043E}\u{0435} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")

        XCTAssertEqual(output.text, "\u{0412}\u{0430}\u{0436}\u{043D}\u{043E}\u{0435} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}")
        XCTAssertNil(output.command)
    }

    func testNewLineCommandActuallyBreaksTheLine() {
        // "New line" at the end of a phrase is the only command that cannot be
        // execute by pressing: Return in someone else's window will send a message, not
        // will wrap the line. Therefore, the line feed goes directly into the text.
        // Previously, words were cut out of the text, but nothing happened.
        let output = TextPipeline().process("\u{0437}\u{0430}\u{043F}\u{0443}\u{0448}\u{0438}\u{043B} \u{0432} \u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")

        XCTAssertEqual(output.text, "\u{0417}\u{0430}\u{043F}\u{0443}\u{0448}\u{0438}\u{043B} \u{0432} \u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431}\n")
        XCTAssertNil(output.command, "\u{041D}\u{0430}\u{0436}\u{0438}\u{043C}\u{0430}\u{0442}\u{044C} \u{0442}\u{0443}\u{0442} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E} — \u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441} \u{0443}\u{0436}\u{0435} \u{0432} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}\u{0435}")
    }

    func testNewLineWithoutTextInsertsNothing() {
        // One command without text is just a word, and there is nothing to wrap.
        let output = TextPipeline().process("\u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")

        XCTAssertEqual(output.text, "\u{041D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}")
        XCTAssertNil(output.command)
    }
}

import XCTest
@testable import DictationCore

/// Clean Verbatim: the cleanup that only ever deletes.
///
/// Every case here is one of two promises. Hesitations, stutters and spoken
/// corrections disappear; nothing the person meant is reworded, reordered or
/// lost. A false deletion is the worse failure, so the meaning-preservation
/// cases outnumber the removal ones.
final class CleanVerbatimTests: XCTestCase {
    // MARK: - Fillers

    func testRemovesALeadingFillerAndCapitalizesWhatFollows() {
        XCTAssertEqual(CleanVerbatim.clean("Um, so the build passed."), "So the build passed.")
        XCTAssertEqual(CleanVerbatim.clean("Uh, the build passed."), "The build passed.")
    }

    func testRemovesAFillerSetOffByCommasTogetherWithItsPause() {
        XCTAssertEqual(CleanVerbatim.clean("We should, um, ship it."), "We should ship it.")
        XCTAssertEqual(CleanVerbatim.clean("We should, uh, ship it."), "We should ship it.")
    }

    func testRemovesABareFillerThatIsNotAWordAnywhere() {
        XCTAssertEqual(CleanVerbatim.clean("Then uh we ship it."), "Then we ship it.")
        XCTAssertEqual(CleanVerbatim.clean("It is hmm fine."), "It is fine.")
    }

    func testAFillerAtASentenceStartInsideTheTakeCapitalizesTheNextWord() {
        XCTAssertEqual(CleanVerbatim.clean("Done. Uh, the next one."), "Done. The next one.")
    }

    func testAFillerCarryingTheFullStopHandsItToTheWordBefore() {
        XCTAssertEqual(CleanVerbatim.clean("I think, uh."), "I think.")
        XCTAssertEqual(CleanVerbatim.clean("I think uh."), "I think.")
        XCTAssertEqual(CleanVerbatim.clean("Is it ready, um?"), "Is it ready?")
    }

    func testRemovesRussianGermanAndFrenchFillers() {
        XCTAssertEqual(CleanVerbatim.clean("Ээ, я думаю, что это работает."), "Я думаю, что это работает.")
        XCTAssertEqual(CleanVerbatim.clean("Я, э, не уверен."), "Я не уверен.")
        XCTAssertEqual(CleanVerbatim.clean("Мм, давай завтра."), "Давай завтра.")
        XCTAssertEqual(CleanVerbatim.clean("Ähm, ich komme morgen."), "Ich komme morgen.")
        XCTAssertEqual(CleanVerbatim.clean("Euh, je pense que oui."), "Je pense que oui.")
    }

    func testATakeThatIsOnlyHesitationBecomesEmpty() {
        XCTAssertEqual(CleanVerbatim.clean("Um."), "")
        XCTAssertEqual(CleanVerbatim.clean("Uh, uh."), "")
    }

    // MARK: - "um" is a real word in German and Portuguese

    func testKeepsGermanAndPortugueseUm() {
        XCTAssertEqual(CleanVerbatim.clean("Um fünf Uhr treffen wir uns."), "Um fünf Uhr treffen wir uns.")
        XCTAssertEqual(CleanVerbatim.clean("Wir gehen um fünf."), "Wir gehen um fünf.")
        XCTAssertEqual(CleanVerbatim.clean("Eu tenho um carro."), "Eu tenho um carro.")
    }

    func testKeepsAnUmThatIsNotSetOffByPunctuation() {
        XCTAssertEqual(CleanVerbatim.clean("So um the build passed."), "So um the build passed.")
    }

    /// The model does not always put a comma before the hesitation; the one
    /// after it is enough to tell it from German and Portuguese "um".
    func testRemovesAnUmCarryingItsOwnComma() {
        XCTAssertEqual(CleanVerbatim.clean("I need you to um, fix it."), "I need you to fix it.")
    }

    // MARK: - Stutters

    func testCollapsesARepeatedFunctionWord() {
        XCTAssertEqual(CleanVerbatim.clean("I I think the the build passed."), "I think the build passed.")
        XCTAssertEqual(CleanVerbatim.clean("The the the deploy failed."), "The deploy failed.")
        XCTAssertEqual(CleanVerbatim.clean("Я я думаю, что и и это тоже."), "Я думаю, что и это тоже.")
    }

    func testAStutterKeepsThePunctuationOfTheWordItDrops() {
        XCTAssertEqual(CleanVerbatim.clean("Ask me and I I."), "Ask me and I.")
    }

    func testKeepsDoublesThatMeanSomething() {
        XCTAssertEqual(CleanVerbatim.clean("That was very very good."), "That was very very good.")
        XCTAssertEqual(CleanVerbatim.clean("I had had enough."), "I had had enough.")
        XCTAssertEqual(CleanVerbatim.clean("I think that that is right."), "I think that that is right.")
        XCTAssertEqual(CleanVerbatim.clean("Да да, конечно."), "Да да, конечно.")
        XCTAssertEqual(CleanVerbatim.clean("Так так, посмотрим."), "Так так, посмотрим.")
    }

    func testKeepsARepeatSeparatedByPunctuation() {
        XCTAssertEqual(CleanVerbatim.clean("No, no, no."), "No, no, no.")
        XCTAssertEqual(CleanVerbatim.clean("The, the answer is yes."), "The, the answer is yes.")
    }

    // MARK: - Spoken corrections

    func testScratchThatAsItsOwnSentenceRemovesThePreviousSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("The deploy failed. Scratch that. The deploy passed."),
            "The deploy passed."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("Встреча в пятницу. Зачеркни это. Встреча в субботу."),
            "Встреча в субботу."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("Встреча в пятницу. Зачеркни. Встреча в субботу."),
            "Встреча в субботу."
        )
    }

    func testScratchThatEndingASentenceRemovesThatSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("So the deploy failed, scratch that. The deploy passed."),
            "The deploy passed."
        )
    }

    /// What Parakeet actually writes: the command between commas, mid-sentence.
    func testScratchThatBetweenCommasRemovesWhatCameBeforeItInTheSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("Um, so that the deploy failed, uh, scratch that, the deploy passed."),
            "The deploy passed."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("This stays. We go Friday, scratch that, we go Monday."),
            "This stays. We go Monday."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("Встреча в пятницу, зачеркни это, в субботу."),
            "В субботу."
        )
    }

    func testScratchThatOpeningASentenceRemovesThePreviousSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("The deploy failed. Scratch that, it passed."),
            "It passed."
        )
        XCTAssertEqual(CleanVerbatim.clean("Scratch that, it passed."), "It passed.")
    }

    func testScratchThatAtTheStartOrEndHasNothingElseToRemove() {
        XCTAssertEqual(CleanVerbatim.clean("Scratch that. Hello there."), "Hello there.")
        XCTAssertEqual(CleanVerbatim.clean("Ship it on Friday. Scratch that"), "")
    }

    func testRepeatedCorrectionsEachRemoveOneSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("First. Second. Scratch that. Scratch that. Third."),
            "Third."
        )
    }

    func testScratchInsideASentenceIsAnOrdinaryWord() {
        XCTAssertEqual(
            CleanVerbatim.clean("Please scratch that line from the file."),
            "Please scratch that line from the file."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("If it chips, scratch that spot and repaint."),
            "If it chips, scratch that spot and repaint."
        )
        XCTAssertEqual(CleanVerbatim.clean("Scratch that itch."), "Scratch that itch.")
        XCTAssertEqual(CleanVerbatim.clean("Зачеркни строку в файле."), "Зачеркни строку в файле.")
    }

    // MARK: - Everything together

    func testTheMessyTakeBecomesWhatWasMeant() {
        XCTAssertEqual(
            CleanVerbatim.clean("Um, so the the deploy failed, uh, scratch that. The deploy passed."),
            "The deploy passed."
        )
    }

    /// Transcripts the shipping model produced from synthesized disfluent
    /// speech (macOS `say`, OpenRamble 0.32.0 CLI), kept as they came out.
    func testRealModelOutput() {
        XCTAssertEqual(
            CleanVerbatim.clean("We should, um, ship it on Friday. I I think that the tests are green, uh, mostly."),
            "We should ship it on Friday. I think that the tests are green mostly."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("Uh, I need you to um, fix the login bug, um, and then update the readme."),
            "I need you to fix the login bug and then update the readme."
        )
        XCTAssertEqual(CleanVerbatim.clean("Um 5 Uhr treffen wir uns im Büro."), "Um 5 Uhr treffen wir uns im Büro.")
    }

    func testAMeetingTranscriptKeepsSpokenCorrections() {
        XCTAssertEqual(
            CleanVerbatim.clean("Um, the deploy failed. Scratch that. It passed.", spokenCorrections: false),
            "The deploy failed. Scratch that. It passed."
        )
        XCTAssertEqual(
            TextPipeline(spokenCorrections: false).process("Uh, it failed, scratch that. It passed.").text,
            "It failed, scratch that. It passed."
        )
    }

    // MARK: - Protected spans are never touched

    func testNeverTouchesProtectedSpans() {
        XCTAssertEqual(CleanVerbatim.clean("Run `uh` now."), "Run `uh` now.")
        XCTAssertEqual(CleanVerbatim.clean("Open /tmp/um/file please."), "Open /tmp/um/file please.")
        XCTAssertEqual(CleanVerbatim.clean("Call AppState AppState twice."), "Call AppState AppState twice.")
        XCTAssertEqual(CleanVerbatim.clean("Run `swift  test`, uh, now."), "Run `swift  test` now.")
    }

    func testAFillerBeforeAnIdentifierDoesNotCapitalizeIt() {
        XCTAssertEqual(CleanVerbatim.clean("Uh, onTextInserted fired."), "onTextInserted fired.")
    }

    // MARK: - Shape of the text

    func testLeavesCleanTextExactlyAsItWas() {
        let samples = [
            "",
            "   ",
            "Hello.",
            "Hello,  world.",
            "first line\nsecond line",
            "Ship it.\n",
        ]
        for sample in samples {
            XCTAssertEqual(CleanVerbatim.clean(sample), sample, sample)
        }
    }

    func testIsIdempotent() {
        let samples = [
            "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
            "We should, um, ship it.",
            "I I think, uh.",
            "Я, э, не уверен.",
        ]
        for sample in samples {
            let once = CleanVerbatim.clean(sample)
            XCTAssertEqual(CleanVerbatim.clean(once), once, sample)
        }
    }

    // MARK: - In the pipeline

    func testRunsAfterTheDictionaryAndBeforeThePolisher() {
        let pipeline = TextPipeline(replacements: [
            DictionaryReplacement(spoken: "sentry", written: "Sentry", inflects: false),
        ])
        XCTAssertEqual(pipeline.process("um, so sentry, uh, is down").text, "So Sentry is down")
    }

    func testTheDictionaryCheckpointIsRecordedBeforeCleanup() {
        let run = TextPipeline().run("Uh, the build passed.")
        XCTAssertEqual(run.provenance.afterDictionary, "Uh, the build passed.")
        XCTAssertEqual(run.output.text, "The build passed.")
    }
}

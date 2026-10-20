import XCTest
@testable import DictationCore

/// Clean Verbatim: the cleanup that only ever deletes.
///
/// Every case here is one of two promises. Hesitations, stutters and spoken
/// corrections disappear; nothing the person meant is reworded, reordered or
/// lost. A false deletion is the worse failure, so the meaning-preservation
/// cases outnumber the removal ones. Many of them came from an adversarial
/// review that tried to make the stage delete something real.
final class CleanVerbatimTests: XCTestCase {
    // MARK: - Fillers

    func testRemovesALeadingFillerAndCapitalizesWhatFollows() {
        XCTAssertEqual(CleanVerbatim.clean("Um, so the build passed."), "So the build passed.")
        XCTAssertEqual(CleanVerbatim.clean("Uh, the build passed."), "The build passed.")
    }

    /// The commas around a hesitation are the pause, so they go with it —
    /// except inside a list, where the comma before it is grammar.
    func testTheCommasAroundAHesitationGoUnlessItSitsInAList() {
        XCTAssertEqual(CleanVerbatim.clean("We should, um, ship it."), "We should ship it.")
        XCTAssertEqual(CleanVerbatim.clean("Don't, uh, deploy on Friday."), "Don't deploy on Friday.")
        XCTAssertEqual(CleanVerbatim.clean("I'll, uh, send the contract on Friday."), "I'll send the contract on Friday.")
        XCTAssertEqual(CleanVerbatim.clean("Мы, э, думаем, что, ээ, надо подождать."), "Мы думаем, что надо подождать.")
        XCTAssertEqual(CleanVerbatim.clean("Send me the, uh, the report."), "Send me the report.")
        XCTAssertEqual(CleanVerbatim.clean("Set the values to 10, 20, um, 30."), "Set the values to 10, 20, 30.")
        XCTAssertEqual(CleanVerbatim.clean("Set it to 10, um, 30."), "Set it to 10, 30.")
        XCTAssertEqual(CleanVerbatim.clean("We need eggs, milk, uh, butter and bread."), "We need eggs, milk, butter and bread.")
        XCTAssertEqual(CleanVerbatim.clean("Fix the files a.swift, b.swift, uh, c.swift."), "Fix the files a.swift, b.swift, c.swift.")
        XCTAssertEqual(CleanVerbatim.clean("Купи хлеб, молоко, э, сыр."), "Купи хлеб, молоко, сыр.")
    }

    /// Recognizers sometimes detach punctuation: "Uh , the build".
    func testDetachedPunctuationIsHandledLikeAttachedPunctuation() {
        XCTAssertEqual(CleanVerbatim.clean("Uh , the build passed."), "The build passed.")
        XCTAssertEqual(CleanVerbatim.clean("Ship it , uh , now"), "Ship it now")
        XCTAssertEqual(CleanVerbatim.clean("I think , uh ."), "I think.")
    }

    /// Two-word interjections are words: "uh huh" means yes.
    func testKeepsTwoWordInterjections() {
        for text in ["Uh huh, ship it.", "Uh huh.", "Mm hmm, sounds good.", "Uh oh, the deploy failed."] {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
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
        XCTAssertEqual(CleanVerbatim.clean("Is it ready, uh?"), "Is it ready?")
    }

    func testRemovesRussianGermanAndFrenchFillers() {
        XCTAssertEqual(CleanVerbatim.clean("Ээ, я думаю, что это работает."), "Я думаю, что это работает.")
        XCTAssertEqual(CleanVerbatim.clean("Я, э, не уверен."), "Я не уверен.")
        XCTAssertEqual(CleanVerbatim.clean("Ммм, давай завтра."), "Давай завтра.")
        XCTAssertEqual(CleanVerbatim.clean("Ähm, ich komme morgen."), "Ich komme morgen.")
        XCTAssertEqual(CleanVerbatim.clean("Euh, je pense que oui."), "Je pense que oui.")
    }

    func testATakeThatIsOnlyHesitationBecomesEmpty() {
        XCTAssertEqual(CleanVerbatim.clean("Uh."), "")
        XCTAssertEqual(CleanVerbatim.clean("Uh, uh."), "")
    }

    // MARK: - "um" is a real word in German and Portuguese

    func testKeepsGermanAndPortugueseUm() {
        let unchanged = [
            "Um fünf Uhr treffen wir uns.",
            "Wir gehen um fünf.",
            "Eu tenho um carro.",
            // Separable verbs put "um" right before the punctuation.
            "Benenne die Funktion um.",
            "Wir ziehen nächste Woche um.",
            "Bau die Funktion um, damit sie async ist.",
            "Wir steigen in Berlin um, dann fahren wir weiter.",
            "Er dreht sich um.",
            "Es geht um Geld.",
            // The Portuguese numeral.
            "Quero um, não dois.",
            "Só preciso de um.",
            "Conta comigo: um, dois, três.",
            "Um, dois, três, quatro.",
            "Mais um?",
            "Mais um, por favor.",
            "Quantos? Um, por favor.",
            "Comprei só um, mas era caro.",
            "Só preciso de um, obrigado.",
            "Schau dich um, vielleicht findest du was.",
            "Sie ziehen um, oder?",
            "Dreh dich um, bitte.",
            // Croatian, Slovak and Slovenian: "um" is "mind".
            "Ljudski um, kao i tijelo, treba odmor.",
            "Ľudský um, ako vieme, je zložitý.",
        ]
        for text in unchanged {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
    }

    func testAGermanHesitationNextToAGermanUmLeavesTheUm() {
        XCTAssertEqual(CleanVerbatim.clean("Es geht um, äh, Geld."), "Es geht um Geld.")
    }

    func testKeepsAnUmThatIsNotSetOffByItsOwnComma() {
        XCTAssertEqual(CleanVerbatim.clean("So um the build passed."), "So um the build passed.")
        XCTAssertEqual(CleanVerbatim.clean("Um."), "Um.")
    }

    /// "word um," is how German separable verbs, the Portuguese "one" and the
    /// Slavic "mind" look too, so it goes only from a take that reads as
    /// English, where "um" is never a word.
    func testAnUmAfterAWordGoesOnlyFromEnglish() {
        XCTAssertEqual(CleanVerbatim.clean("I need you to um, fix it."), "I need you to fix it.")
        XCTAssertEqual(CleanVerbatim.clean("Ljudski um, kao i tijelo, treba odmor."), "Ljudski um, kao i tijelo, treba odmor.")
        XCTAssertEqual(CleanVerbatim.clean("Comprei só um, mas era caro."), "Comprei só um, mas era caro.")
        XCTAssertEqual(CleanVerbatim.clean("Ich will you to um, fix it."), "Ich will you to um, fix it.")
    }

    /// Hesitations in a row are one pause: the comma after the last one sets
    /// them all apart.
    func testHesitationsInARowGoTogether() {
        XCTAssertEqual(CleanVerbatim.clean("Ship it, um uh, now"), "Ship it now")
        XCTAssertEqual(CleanVerbatim.clean("We should um uh, ship it."), "We should ship it.")
    }

    /// The German and Portuguese markers ignore acronyms and English words.
    func testEnglishTakesWithLookalikeMarkersStillLoseTheirUms() {
        XCTAssertEqual(CleanVerbatim.clean("Um, the battery will die soon."), "The battery will die soon.")
        XCTAssertEqual(CleanVerbatim.clean("Um, I studied at MIT."), "I studied at MIT.")
        XCTAssertEqual(CleanVerbatim.clean("Um, the EU rules changed."), "The EU rules changed.")
        XCTAssertEqual(CleanVerbatim.clean("Um, the façade is done."), "The façade is done.")
    }

    // MARK: - Real words that look like fillers

    func testKeepsUnitsLettersAndAcronyms() {
        let unchanged = [
            "Use a 3 mm drill bit and a 10 mm bolt.",
            "The gap is 5 mm, not 6.",
            "Толщина стенки 5 мм.",
            "Format the date as dd mm yyyy.",
            "Слово начинается на э.",
            "Напиши букву э.",
            "Отправь эс эм эс.",
            "We trained an HMM on the data.",
            "We need an ERM framework.",
            "Build an MMM for the marketing team.",
            "Contact HM Revenue and Customs.",
            "I studied at UH.",
            "I studied at UM.",
            "Format the date as dd mmm yyyy.",
            "Гласные: а, о, у, э, ы.",
            "Буквы А, О, У, Э, Ы.",
        ]
        for text in unchanged {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
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
        let unchanged = [
            "That was very very good.",
            "I had had enough.",
            "I think that that is right.",
            "Да да, конечно.",
            "Так так, посмотрим.",
            "What the problem is is that the cache is stale.",
            "What it was was a race condition.",
            "Log in in Safari and check the cookie.",
            "Turn the flag on on staging.",
            "Search for for loops in the codebase.",
            "The movie was so so.",
            "Use and and or instead of the symbols.",
            "My name is Aaron, spelled A A R O N.",
            "Take him to the OR or the ER.",
            "Tell IT it is broken.",
            "Conheço a cidade de A a Z.",
            "Il y a a priori un problème.",
            "Najważniejsze to to, że działa.",
            "Er weiß nicht, was was ist.",
            "Это это?",
            "I told you you were right.",
            "Did I tell you you need to sign?",
            "Before you run it it needs to compile.",
            "When I saw it it was broken.",
            "If you build it it will come.",
            "Thank you you guys are great.",
            "Zmienne i i j są indeksami.",
            "Use i I mean j.",
            "My my, how you have grown.",
            "Read the\nthe report",
        ]
        for text in unchanged {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
    }

    func testKeepsARepeatSeparatedByPunctuation() {
        XCTAssertEqual(CleanVerbatim.clean("No, no, no."), "No, no, no.")
        XCTAssertEqual(CleanVerbatim.clean("The, the answer is yes."), "The answer is yes.")
        XCTAssertEqual(CleanVerbatim.clean("I, I really think so."), "I really think so.")
        XCTAssertEqual(CleanVerbatim.clean("Я, я думаю."), "Я думаю.")
        XCTAssertEqual(CleanVerbatim.clean("Try it, it works."), "Try it, it works.")
        XCTAssertEqual(CleanVerbatim.clean("Between you and I, I think so."), "Between you and I, I think so.")
        XCTAssertEqual(CleanVerbatim.clean("Это сделал он, он сам признался."), "Это сделал он, он сам признался.")
    }

    // MARK: - Spoken corrections

    func testScratchThatAsItsOwnSentenceRemovesThePreviousSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("The deploy failed. Scratch that. The deploy passed."),
            "The deploy passed."
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
    }

    func testScratchThatOpeningASentenceRemovesThePreviousSentence() {
        XCTAssertEqual(CleanVerbatim.clean("The deploy failed. Scratch that, it passed."), "It passed.")
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

    /// "Ah, scratch that" — Parakeet writes a spoken "uh" as "Ah" — still opens
    /// the sentence, and so do the words people lead a correction with.
    func testALeadInBeforeScratchThatStillOpensTheSentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("Um, so that the deploy failed. Ah, scratch that, the deploy passed."),
            "The deploy passed."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("We meet on Friday. Sorry, scratch that, we meet on Monday."),
            "We meet on Monday."
        )
        XCTAssertEqual(CleanVerbatim.clean("Ship it today. No, scratch that."), "")
    }

    /// A sentence of nothing but hesitation is not what "scratch that" takes back.
    func testAHesitationSentenceDoesNotAbsorbTheCorrection() {
        XCTAssertEqual(CleanVerbatim.clean("Ship it. Uh. Scratch that."), "")
        XCTAssertEqual(CleanVerbatim.clean("Ship it. Um. Scratch that. Ship it Monday."), "Ship it Monday.")
    }

    /// Titles before a name do not end a sentence; closing quotes and
    /// brackets do not hide one.
    func testTitlesAndClosingQuotesDoNotMoveSentenceEdges() {
        XCTAssertEqual(CleanVerbatim.clean("I met Dr. Smith today. Scratch that. I met nobody."), "I met nobody.")
        XCTAssertEqual(CleanVerbatim.clean("Call Dr. Smith, scratch that, Dr. Jones."), "Dr. Jones.")
        XCTAssertEqual(
            CleanVerbatim.clean("He said \"stop.\" Then we left, scratch that, we stayed."),
            "He said \"stop.\" We stayed."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("The first test failed (it timed out.) We ship Friday, scratch that, we ship Monday."),
            "The first test failed (it timed out.) We ship Monday."
        )
    }

    /// When it is unclear whether a full stop ends a sentence, it does: then a
    /// correction can only take back too little, never a sentence the person
    /// meant to keep.
    func testWhenInDoubtAFullStopEndsTheSentence() {
        let cases = [
            ("Meet at 3 p.m. Bring snacks. Scratch that. Bring drinks.", "Meet at 3 p.m. Bring drinks."),
            ("I asked twice and he said no. Ship it Friday. Scratch that. Ship it Monday.", "I asked twice and he said no. Ship it Monday."),
            ("Set the timeout to 5. Use port 80. Scratch that. Use port 8080.", "Set the timeout to 5. Use port 8080."),
            ("Upgrade to Python 3.12. Then run the tests. Scratch that. Run the linter.", "Upgrade to Python 3.12. Run the linter."),
            ("Bump the version to 1.4.2. Deploy on Friday, scratch that, on Monday.", "Bump the version to 1.4.2. On Monday."),
            ("The standup is at 9 a.m. We demo Friday, scratch that.", "The standup is at 9 a.m."),
            ("Edit config.yaml. Then restart nginx. Scratch that. Then reload nginx.", "Edit config.yaml. Then reload nginx."),
            ("Buy milk, eggs, etc. Ship on Friday. Scratch that. Ship Monday.", "Buy milk, eggs, etc. Ship Monday."),
            ("Pick plan B. Ship it Friday. Scratch that. Ship it Monday.", "Pick plan B. Ship it Monday."),
            ("We meet at 5. Scratch that. We meet at 6.", "We meet at 6."),
            ("The total is 5. Ship it Friday, scratch that.", "The total is 5."),
            ("Are we shipping today? No. Scratch that. Yes.", "Are we shipping today? Yes."),
            ("Should I merge it? No. Scratch that, yes, merge it.", "Should I merge it? Yes, merge it."),
            ("Meet at 5 p.m. tomorrow. Scratch that. Meet at 6.", "Meet at 5 p.m. Meet at 6."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
        }
    }

    func testAFillerAfterAShortSentenceStillCapitalizesAndKeepsOneFullStop() {
        XCTAssertEqual(CleanVerbatim.clean("Can we ship? No. Uh, not yet."), "Can we ship? No. Not yet.")
        XCTAssertEqual(CleanVerbatim.clean("We met at 5 p.m. Uh, then we left."), "We met at 5 p.m. Then we left.")
        XCTAssertEqual(CleanVerbatim.clean("He said no. Uh. Then he left."), "He said no. Then he left.")
        XCTAssertEqual(CleanVerbatim.clean("The price is 3. Uh. It goes up next week."), "The price is 3. It goes up next week.")
        XCTAssertEqual(CleanVerbatim.clean("1. Install the deps.\n2. Uh, run the tests."), "1. Install the deps.\n2. Run the tests.")
    }

    func testEveryScratchThatInASentenceIsConsidered() {
        XCTAssertEqual(
            CleanVerbatim.clean("I will scratch that off the list, scratch that, I will keep it."),
            "I will keep it."
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
    }

    /// "Зачеркни" tells a reader to cross something out far more often than it
    /// takes back what was just said, so Russian has no spoken correction.
    func testRussianInstructionsToCrossSomethingOutStayText() {
        let unchanged = [
            "В третьей строке опечатка. Зачеркни это, а потом перепиши.",
            "Если в договоре есть пункт про штрафы, зачеркни это.",
            "Видишь лишнее слово? Зачеркни.",
            "Зачеркни строку в файле.",
        ]
        for text in unchanged {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
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
        // Another voice: the model wrote the spoken "uh" as "Ah", a word.
        XCTAssertEqual(
            CleanVerbatim.clean("Ah, I need you to um, fix the login bug, um, and then update the readme."),
            "Ah, I need you to fix the login bug and then update the readme."
        )
    }

    // MARK: - Meetings

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

    /// In a meeting a one-word reply is something a person said.
    func testAMeetingKeepsATurnThatIsOnlyAnInterjection() {
        XCTAssertEqual(CleanVerbatim.clean("Hmm?", spokenCorrections: false), "Hmm?")
        XCTAssertEqual(CleanVerbatim.clean("Uh.", spokenCorrections: false), "Uh.")
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

    func testALineBreakSurvivesARemovalNextToIt() {
        XCTAssertEqual(CleanVerbatim.clean("First paragraph.\n\nUh, second paragraph."), "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(CleanVerbatim.clean("Line one.\nLine two. Scratch that. Line three."), "Line one.\nLine three.")
        XCTAssertEqual(CleanVerbatim.clean("First paragraph.\r\n\r\nUh, second paragraph."), "First paragraph.\r\n\r\nSecond paragraph.")
        XCTAssertEqual(CleanVerbatim.clean("Hello.\r\nUh, there."), "Hello.\r\nThere.")
    }

    func testIsIdempotent() {
        let samples = [
            "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
            "We should, um, ship it.",
            "I I think, uh.",
            "Я, э, не уверен.",
            "Set the values to 10, 20, um, 30.",
            "Ship it, um uh, now",
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

    /// A command with nothing left to act on is just words, as when it is
    /// spoken alone: never an empty insert that reads as "nothing recognized".
    func testACommandAfterOnlyHesitationIsInsertedAsWords() {
        let newLine = TextPipeline().process("Uh, new line.")
        XCTAssertEqual(newLine.text, "New line.")
        XCTAssertNil(newLine.command)

        let send = TextPipeline(allowPressReturnCommand: true).process("Uh, send it.")
        XCTAssertEqual(send.text, "Send it.")
        XCTAssertNil(send.command)
    }

    /// What the person's own dictionary wrote is never a filler or a stutter.
    func testWordsTheDictionaryWroteAreKept() {
        let band = TextPipeline(replacements: [DictionaryReplacement(spoken: "the the", written: "The The", inflects: false)])
        XCTAssertEqual(band.process("I love the the band.").text, "I love The The band.")
        let company = TextPipeline(replacements: [DictionaryReplacement(spoken: "hm labs", written: "Hmm Labs", inflects: false)])
        XCTAssertEqual(company.process("I work at hm labs.").text, "I work at Hmm Labs.")
    }

    func testAStutterAfterARemovedHesitationIsCollapsedInOnePass() {
        XCTAssertEqual(TextPipeline().process("Ship it, um uh, new line").text, "Ship it\n")
    }

    func testAHesitationBeforeATrailingCommandGoes() {
        XCTAssertEqual(TextPipeline().process("We should ship it, um, new line.").text, "We should ship it\n")
    }
}

/// A take whose every word was taken back is not a recognition failure.
@MainActor
final class TakenBackDictationTests: XCTestCase {
    func testATakenBackTakeIsKeptQuietlyAndNotReportedAsUnrecognized() async {
        let inserter = FakeInserter()
        let overlay = FakeOverlay()
        let sounds = FakeSounds()
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in ASRResult(text: "Ship it Friday. Scratch that.", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline() }
        )
        var archived: [String] = []
        controller.onTakeFinished = { text, _ in archived.append(text) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        for _ in 0..<12 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        controller.stop()
        for _ in 0..<24 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        let plays = await sounds.attentionPlays
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(archived, ["Ship it Friday. Scratch that."], "kept in History with what was heard")
        XCTAssertTrue(notices.contains { $0.message.contains("taken back") }, "\(notices)")
        XCTAssertFalse(notices.contains { $0.wordsDidNotLand })
        XCTAssertEqual(plays, 0, "nothing was lost, so no alarm")
    }
}

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

    /// The commas around a hesitation are the pause and go with it, unless the
    /// one before it is grammar: a list, an opening word, a word that needs it.
    func testTheCommaBeforeAHesitationStaysOnlyWhereItIsGrammar() {
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
        XCTAssertEqual(CleanVerbatim.clean("Invite Anna, um, Maria and Bob."), "Invite Anna, Maria and Bob.")
        XCTAssertEqual(CleanVerbatim.clean("Пригласи Анну, э, Марию и Бориса."), "Пригласи Анну, Марию и Бориса.")
        XCTAssertEqual(CleanVerbatim.clean("I'm sorry, um, I love you."), "I'm sorry, I love you.")
        XCTAssertEqual(CleanVerbatim.clean("Hi John, um, can you review this?"), "Hi John, can you review this?")
        XCTAssertEqual(CleanVerbatim.clean("Yes, um, that works for me."), "Yes, that works for me.")
        XCTAssertEqual(CleanVerbatim.clean("Да, ээ, это работает."), "Да, это работает.")
        XCTAssertEqual(CleanVerbatim.clean("We need milk, um, eggs and bread."), "We need milk, eggs and bread.")
        XCTAssertEqual(CleanVerbatim.clean("Купи хлеб, э, молоко и сыр."), "Купи хлеб, молоко и сыр.")
        XCTAssertEqual(CleanVerbatim.clean("Мы думаем, ээ, что надо подождать."), "Мы думаем, что надо подождать.")
        XCTAssertEqual(CleanVerbatim.clean("The build, uh, failed."), "The build failed.")
        XCTAssertEqual(CleanVerbatim.clean("Ну, э, Sentry, э, упал."), "Ну, Sentry упал.")
        XCTAssertEqual(CleanVerbatim.clean("Thanks, John, um, see you tomorrow."), "Thanks, John, see you tomorrow.")
        XCTAssertEqual(CleanVerbatim.clean("Okay, Mike, um, I will check."), "Okay, Mike, I will check.")
        XCTAssertEqual(CleanVerbatim.clean("Hi, Anna, um, quick question."), "Hi, Anna, quick question.")
        XCTAssertEqual(CleanVerbatim.clean("No, no, um, that's wrong."), "No, no, that's wrong.")
        XCTAssertEqual(CleanVerbatim.clean("Well, actually, um, I think so."), "Well, actually, I think so.")
        XCTAssertEqual(CleanVerbatim.clean("Да, конечно, э, сделаю."), "Да, конечно, сделаю.")
        // After an opening word, a word that starts the clause takes no comma.
        XCTAssertEqual(CleanVerbatim.clean("Okay, this, uh, looks good."), "Okay, this looks good.")
        XCTAssertEqual(CleanVerbatim.clean("Yes, it, um, works now."), "Yes, it works now.")
        XCTAssertEqual(CleanVerbatim.clean("Ну, это, э, работает."), "Ну, это работает.")
        XCTAssertEqual(CleanVerbatim.clean("Yes, rename, um, it to FooBar."), "Yes, rename it to FooBar.")
        // "Thanks for", "Sorry for", "Спасибо за" are one phrase.
        XCTAssertEqual(CleanVerbatim.clean("Thanks, um, for the quick reply."), "Thanks for the quick reply.")
        XCTAssertEqual(CleanVerbatim.clean("Sorry, uh, for the delay."), "Sorry for the delay.")
        XCTAssertEqual(CleanVerbatim.clean("Спасибо, э, за помощь."), "Спасибо за помощь.")
        XCTAssertEqual(CleanVerbatim.clean("Okay, thanks, uh, for the quick reply."), "Okay, thanks for the quick reply.")
        XCTAssertEqual(CleanVerbatim.clean("Well, um, the build failed."), "Well, the build failed.")
        XCTAssertEqual(CleanVerbatim.clean("We should, um, ship and celebrate."), "We should ship and celebrate.")
    }

    /// Recognizers sometimes detach punctuation: "Uh , the build".
    func testDetachedPunctuationIsHandledLikeAttachedPunctuation() {
        XCTAssertEqual(CleanVerbatim.clean("Uh , the build passed."), "The build passed.")
        XCTAssertEqual(CleanVerbatim.clean("Ship it , uh , now"), "Ship it now")
        XCTAssertEqual(CleanVerbatim.clean("I think , uh ."), "I think.")
    }

    /// Two-word interjections are words: "uh huh" means yes. "um hmm" stays
    /// even in a take that reads as English, where a lone "um" goes.
    func testKeepsTwoWordInterjections() {
        for text in [
            "Uh huh, ship it.", "Uh huh.", "Mm hmm, sounds good.", "Uh oh, the deploy failed.", "Um hmm.",
            "Um hmm, sounds good.", "Um hmm, that's the plan you know.",
        ] {
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

    func testAnUmWithoutItsOwnCommaGoesOnlyFromAnEnglishTake() {
        XCTAssertEqual(CleanVerbatim.clean("So um the build passed."), "So the build passed.")
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
    /// A capitalized word in the middle of a sentence before "um" is a German
    /// noun with its separable verb ("Stell die Config um"), even in a take
    /// with English in it.
    func testAnUmAfterACapitalizedWordStays() {
        XCTAssertEqual(CleanVerbatim.clean("Stell die Config um, that should fix it."), "Stell die Config um, that should fix it.")
        XCTAssertEqual(CleanVerbatim.clean("And I um, think that works."), "And I think that works.")
        XCTAssertEqual(CleanVerbatim.clean("So I'm um, not sure about that."), "So I'm not sure about that.")
        XCTAssertEqual(CleanVerbatim.clean("I think I'll um, call you tomorrow."), "I think I'll call you tomorrow.")
    }

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

    /// The last item of a letter or format list is never a dangling hesitation.
    func testTheLastItemOfAListIsNotADanglingHesitation() {
        for text in ["Гласные: а, о, у, э", "Date formats: dd, mm, mmm", "Твёрдые гласные а, о, у, ы, э", "Гласные: а́, о́, у́, э, ы́."] {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
    }

    // MARK: - Stutters

    /// A double whose case differs mid-sentence is two words ("220 В в сети"),
    /// and "I I" after a capitalized word is a numeral and a pronoun.
    func testDoublesThatDifferInCaseOrFollowANameStay() {
        for text in ["Напряжение 220 В в сети.", "After World War I I moved to Paris."] {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
        XCTAssertEqual(CleanVerbatim.clean("Then I I moved to Paris."), "Then I moved to Paris.")
    }

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
            ("I opened an MR. Ping the team about it. Scratch that.", "I opened an MR."),
            ("Review the MR. Merge it after lunch. Scratch that, merge it tomorrow.", "Review the MR. Merge it tomorrow."),
            ("Set the timeout to 500 ms. Use three retries. Scratch that.", "Set the timeout to 500 ms."),
            ("I asked the Mrs. She said no. Scratch that, she said yes.", "I asked the Mrs. She said yes."),
            ("Install MS. Office is great. Scratch that.", "Install MS."),
            ("Is it ready? No, scratch that, yes.", "Is it ready? Yes."),
            ("Ship it today. No, scratch that.", ""),
            ("Is it ready? Uh. No, scratch that, yes.", "Is it ready? Yes."),
            ("Is it ready? Hmm. No, scratch that.", "Is it ready?"),
            ("She asked, \"Is it ready?\" No, scratch that, yes.", "She asked, \"Is it ready?\" Yes."),
            ("Is it ready?! No, scratch that, yes.", "Is it ready?! Yes."),
            ("I live at 5 Main Dr. The house is blue. Scratch that.", "I live at 5 Main Dr."),
            ("I met Dr. Will Smith today. Scratch that. I met nobody.", "I met nobody."),
            ("Call Ms. May tomorrow, scratch that, call her today.", "Call her today."),
            ("Ask Dr. Will Jones about it, scratch that.", ""),
            ("We met the new Prof. Students love her. Scratch that.", "We met the new Prof."),
            ("We met the new Prof. She seems nice. Scratch that.", "We met the new Prof."),
            ("Done. 3 tests failed. Scratch that, all passed.", "Done. All passed."),
            ("Okay. \"Ship it\" was the plan. Scratch that, we wait.", "Okay. We wait."),
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

    /// A removal capitalizes what follows only when the removed piece was
    /// itself capitalized: after "e.g." or "vs." a sentence did not start.
    func testARemovalCapitalizesOnlyWhatOpenedASentence() {
        let cases = [
            ("Handle the edge cases, e.g. uh, empty input.", "Handle the edge cases, e.g. empty input."),
            ("Нужно всё переписать, т.е. э, начать заново.", "Нужно всё переписать, т.е. начать заново."),
            ("I think... uh, maybe tomorrow.", "I think... maybe tomorrow."),
            ("Let's meet at 10 a.m. uh, on Monday.", "Let's meet at 10 a.m. on Monday."),
            ("Meet me at 5 p.m. on Monday, scratch that, on Tuesday.", "Meet me at 5 p.m. on Tuesday."),
            ("Compare tea vs. coffee, scratch that, water.", "Compare tea vs. water."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
        }
    }

    func testAFillerAfterAnAbbreviationLeavesOneFullStop() {
        XCTAssertEqual(CleanVerbatim.clean("I'll be there by 9 a.m., uh."), "I'll be there by 9 a.m.")
        XCTAssertEqual(CleanVerbatim.clean("Bring plates, cups, etc., uh."), "Bring plates, cups, etc.")
    }

    /// "scratch that" is a command only when a comma or a sentence edge sets
    /// it apart; a bare hesitation before it is not a pause, and does not hide
    /// the comma before or after it either.
    func testAHesitationAloneDoesNotMakeScratchThatACommand() {
        XCTAssertEqual(CleanVerbatim.clean("If I were you I'd uh scratch that."), "If I were you I'd scratch that.")
        let cases = [
            ("We'll ship it on Friday, uh scratch that, on Monday.", "On Monday."),
            ("Ship it today, uh scratch that.", ""),
            ("Ship it on Friday. Scratch that uh, on Monday.", "On Monday."),
            ("Send it to Anna, um scratch that, to Bob.", "To Bob."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
            XCTAssertEqual(CleanVerbatim.clean(CleanVerbatim.clean(input)), expected, "idempotent: \(input)")
        }
    }

    /// A sentence-final "um" or "э" after a comma goes like ", uh." does; a
    /// letter list keeps its last letter.
    func testASentenceFinalHesitationAfterACommaGoes() {
        XCTAssertEqual(CleanVerbatim.clean("Let me know if that works for you, um."), "Let me know if that works for you.")
        XCTAssertEqual(CleanVerbatim.clean("We should ship it on Friday, um."), "We should ship it on Friday.")
        XCTAssertEqual(CleanVerbatim.clean("Um, I don't know, um."), "I don't know.")
        XCTAssertEqual(CleanVerbatim.clean("Надо подождать, э."), "Надо подождать.")
        XCTAssertEqual(CleanVerbatim.clean("Is it ready, um?"), "Is it ready?")
        for text in ["Гласные: а, о, у, э.", "Quero mais, um.", "Date formats: dd, mm, mmm."] {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
        XCTAssertEqual(TextPipeline().process("Надо подождать, э, новая строка").text, "Надо подождать\n")
        XCTAssertEqual(TextPipeline().process("Это конец, э, новая строка.").text, "Это конец\n")
    }

    func testFillersRepeatUntilNothingChanges() {
        XCTAssertEqual(CleanVerbatim.clean("I think that um um um um"), "I think that")
        XCTAssertEqual(CleanVerbatim.clean("The The um, build failed."), "The build failed.")
        XCTAssertEqual(CleanVerbatim.clean("We We um, should ship it."), "We should ship it.")
        XCTAssertEqual(TextPipeline().process("This is the end um um um um, new line.").text, "This is the end\n")
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

    // MARK: - "New paragraph" (prose apps only)

    func testNewParagraphBreaksTheTextInProse() {
        XCTAssertEqual(
            CleanVerbatim.clean("First point. New paragraph. Second point.", mode: .prose),
            "First point.\n\nSecond point."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("First point, new paragraph, second point.", mode: .prose),
            "First point.\n\nSecond point."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("Первый пункт. Новый абзац. Второй пункт.", mode: .prose),
            "Первый пункт.\n\nВторой пункт."
        )
    }

    func testNewParagraphAfterAFillerStillBreaks() {
        XCTAssertEqual(
            CleanVerbatim.clean("First point. New paragraph. Um, second point.", mode: .prose),
            "First point.\n\nSecond point."
        )
    }

    func testNewParagraphAtTheEdgesHasNothingToSeparate() {
        XCTAssertEqual(CleanVerbatim.clean("New paragraph. Hello there.", mode: .prose), "Hello there.")
        XCTAssertEqual(CleanVerbatim.clean("Hello there. New paragraph.", mode: .prose), "Hello there.")
    }

    func testNewParagraphIsTextWhenItIsPartOfASentence() {
        XCTAssertEqual(
            CleanVerbatim.clean("I added a new paragraph about pricing.", mode: .prose),
            "I added a new paragraph about pricing."
        )
    }

    /// A newline in a terminal can run a command, so verbatim apps keep the words.
    func testNewParagraphStaysWordsInVerbatimApps() {
        XCTAssertEqual(
            CleanVerbatim.clean("First point. New paragraph. Second point.", mode: .verbatim),
            "First point. New paragraph. Second point."
        )
        XCTAssertEqual(
            CleanVerbatim.clean("First point. New paragraph. Second point."),
            "First point. New paragraph. Second point."
        )
    }

    func testAParagraphBreakSurvivesThePolisher() {
        XCTAssertEqual(
            TextPipeline(mode: .prose).process("first point. new paragraph. second point").text,
            "First point.\n\nSecond point"
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

    // MARK: - Review round 6

    /// The comma the recognizer wrote stays unless it can only be the pause:
    /// after a word that cannot end a phrase, in "Thanks, um, for", or after
    /// a sentence's opening subject. Lists, clauses, names and introductory
    /// words keep it.
    func testTheCommaBeforeAHesitationStaysUnlessItCanOnlyBeThePause() {
        let cases = [
            ("Купи хлеб, ээ, молоко, сыр.", "Купи хлеб, молоко, сыр."),
            ("Invite Anna, um, Maria, and Bob.", "Invite Anna, Maria, and Bob."),
            ("Add tests for login, uh, signup, and logout.", "Add tests for login, signup, and logout."),
            ("I met John, um, Paul.", "I met John, Paul."),
            ("Thank you, um, I'll take a look.", "Thank you, I'll take a look."),
            ("Thank you um, I'll take a look.", "Thank you, I'll take a look."),
            ("Refactor the function, uh, it's too long.", "Refactor the function, it's too long."),
            ("Let's use SQLite for now, um, it's simpler.", "Let's use SQLite for now, it's simpler."),
            ("Я не знаю, ээ, может быть завтра.", "Я не знаю, может быть завтра."),
            ("Anna, um, can you review my PR?", "Anna, can you review my PR?"),
            ("Claude, um, please refactor this function.", "Claude, please refactor this function."),
            ("Коллеги, ээ, завтра созвон в десять.", "Коллеги, завтра созвон в десять."),
            ("Hey team, um, quick update.", "Hey team, quick update."),
            ("However, um, the tests still fail.", "However, the tests still fail."),
            ("Кстати, ээ, я забыл ключи.", "Кстати, я забыл ключи."),
            ("Well, basically, um, we ship it on Friday.", "Well, basically, we ship it on Friday."),
            ("Ну, короче, э, давай завтра.", "Ну, короче, давай завтра."),
            ("Hi everyone, um, thanks for joining.", "Hi everyone, thanks for joining."),
            ("Привет, ребята, э, есть минутка?", "Привет, ребята, есть минутка?"),
            ("Dear John, um, thanks for the note.", "Dear John, thanks for the note."),
            ("Honestly, um, I'm not sure.", "Honestly, I'm not sure."),
            ("So Sentry, uh, is down.", "So Sentry is down."),
            ("Es geht um, äh, Geld.", "Es geht um Geld."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
        }
    }

    /// Round eight: the comma before a hesitation goes unless something keeps
    /// it, measured on a judged corpus; restarts across a hesitation; letters
    /// set against letters.
    func testRoundEight() {
        let cases: [(String, String)] = [
            ("Try it, um, it works.", "Try it, it works."),
            ("Ask Uma, uh, Uma knows the answer.", "Ask Uma, Uma knows the answer."),
            ("That's very, um, very kind of you.", "That's very, very kind of you."),
            ("Мы обсудили бюджет, э, бюджет утвердили в пятницу.", "Мы обсудили бюджет, бюджет утвердили в пятницу."),
            ("I bought milk, uh, milk is expensive now.", "I bought milk, milk is expensive now."),
            ("Version 10, um, 10 users signed up.", "Version 10, 10 users signed up."),
            ("I sent the file, um, file names are wrong.", "I sent the file, file names are wrong."),
            ("Я отправил, ммм, отправил договор юристу.", "Я отправил договор юристу."),
            ("Не длиннее пятнадцати, ээ, пятнадцати секунд.", "Не длиннее пятнадцати секунд."),
            ("Сделай отдельный, э, отдельный endpoint.", "Сделай отдельный endpoint."),
            ("So I, um, I think it's fine.", "So I think it's fine."),
            ("It's a, um, an issue.", "It's an issue."),
            ("I gave it to the, to the team.", "I gave it to the team."),
            ("Between you and I, and I mean this, it's fine.", "Between you and I, and I mean this, it's fine."),
            ("The tests pass, um, and the build failed.", "The tests pass and the build failed."),
            ("Get milk, eggs, um, and the bread.", "Get milk, eggs, and the bread."),
            ("The API is done, uh, and the docs are live.", "The API is done, and the docs are live."),
            ("Call the vendor, uh, Sam has the number.", "Call the vendor, Sam has the number."),
            ("Пишется э, а не е.", "Пишется э, а не е."),
            ("Он сказал, э, а не пойти ли нам.", "Он сказал, а не пойти ли нам."),
            ("Напиши мне, э, если что.", "Напиши мне, если что."),
            ("Только, э, если успеем.", "Только если успеем."),
            ("Refer her to Dr. Haddad, uh, scratch that, to Dr. Moreau.", "To Dr. Moreau."),
            ("Не, не надо.", "Не, не надо."),
            ("Это не, не критично.", "Это не критично."),
            ("Use and and or instead of the symbols.", "Use and and or instead of the symbols."),
            ("Fruit, e.g., um, apples.", "Fruit, e.g., apples."),
            ("Нужен ноутбук, т. е., э, лёгкий.", "Нужен ноутбук, т. е. лёгкий."),
            ("Привет, ээ, хотел спросить.", "Привет, хотел спросить."),
            ("Марина, ээ, сказала, что да.", "Марина сказала, что да."),
            ("Маша, э, ты сделала?", "Маша, ты сделала?"),
            ("Я не буду, э, трогать модуль, пока нет тестов.", "Я не буду трогать модуль, пока нет тестов."),
            ("Eu queria uma, hmm, uma sopa.", "Eu queria uma sopa."),
            ("Can you, um, look at the failing test in auth.test.ts?", "Can you look at the failing test in auth.test.ts?"),
            ("Добрый день, ээ, Наталья Сергеевна.", "Добрый день, Наталья Сергеевна."),
            ("Thanks, John, um, see you tomorrow.", "Thanks, John, see you tomorrow."),
            ("Я не знаю, ээ, может быть завтра.", "Я не знаю, может быть завтра."),
            ("На ревью три PR: от Лены, от Тимура, э, от Вадима.", "На ревью три PR: от Лены, от Тимура, от Вадима."),
            ("I booked the flights, uh, and Sam is handling the hotel.", "I booked the flights, and Sam is handling the hotel."),
            ("I like the red car, um, the one with stripes.", "I like the red car, the one with stripes."),
            ("Okay, if it fails, um, we roll back.", "Okay, if it fails, we roll back."),
            ("Okay, this, uh, looks good.", "Okay, this looks good."),
            ("I need, um, a new laptop, and a mouse.", "I need a new laptop, and a mouse."),
            ("Bring a tent, um, a warm jacket, and boots.", "Bring a tent, a warm jacket, and boots."),
            ("В общем, ээ, всё готово.", "В общем, всё готово."),
            ("Of course, um, we can do that.", "Of course, we can do that."),
            ("Мы, эм, честно говоря, не ожидали.", "Мы, честно говоря, не ожидали."),
            ("Это, э, может быть, лучший вариант.", "Это, может быть, лучший вариант."),
            ("Сервер, который мы купили в мае, ээ, сломался.", "Сервер, который мы купили в мае, сломался."),
            ("Дом, который построили для, э, нас.", "Дом, который построили для нас."),
            ("The server, which we set up last week, um, crashed.", "The server, which we set up last week, crashed."),
            ("Tell me, which one, um, you want.", "Tell me, which one you want."),
            ("Высылаю, э, акт сверки.", "Высылаю акт сверки."),
            ("Думаю, э, это сработает.", "Думаю, это сработает."),
            ("Андрей, э, посмотри пулреквест.", "Андрей, посмотри пулреквест."),
            ("We're meeting with the, um, with Kowalski's team.", "We're meeting with Kowalski's team."),
            ("It's a, uh, it's an issue.", "It's an issue."),
            ("Put it in the, uh, in my bag.", "Put it in my bag."),
            ("Talk to the, um, to Anna.", "Talk to Anna."),
            ("It needs a 3 mm, uh, a 3 mm margin.", "It needs a 3 mm margin."),
            ("It fires every, every 15 minutes.", "It fires every 15 minutes."),
            ("Перенести приём на среду, ммм.", "Перенести приём на среду."),
            ("Нам нужны, ммм, два монитора.", "Нам нужны два монитора."),
            ("Meet me at 5 p.m. on Monday, scratch that, on Tuesday.", "Meet me at 5 p.m. on Tuesday."),
            ("When I asked, the agent said mm hmm, uh, and left.", "When I asked, the agent said mm hmm and left."),
            ("Every, um, every time it fails.", "Every time it fails."),
            ("I want the, um, the blue one.", "I want the blue one."),
            ("Use the format dd, mmm.", "Use the format dd, mmm."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
            XCTAssertEqual(CleanVerbatim.clean(CleanVerbatim.clean(input)), expected, "idempotent: " + input)
        }
    }

    /// A restart around a hesitation is one word said twice: the first copy
    /// goes with the hesitation instead of leaving a glued double.
    func testARestartAroundAHesitationKeepsOneCopy() {
        let cases = [
            ("It's a, uh, a memory leak.", "It's a memory leak."),
            ("I'm, uh, I'm not sure.", "I'm not sure."),
            ("I want you to, uh, to add logging.", "I want you to add logging."),
            ("Write a function that, um, that returns the sum.", "Write a function that returns the sum."),
            ("Это, э, это баг.", "Это баг."),
            ("Can you, um, can you check it?", "Can you check it?"),
            ("Make sure, um, make sure it compiles.", "Make sure it compiles."),
            ("Я хотел, э, я хотел сказать.", "Я хотел сказать."),
            ("It's, um, it's not ready.", "It's not ready."),
            ("I, um, I think we should ship it.", "I think we should ship it."),
            ("Я, э, я думаю, что да.", "Я думаю, что да."),
            ("Давай в, э, в субботу.", "Давай в субботу."),
            ("We need a, um, a new plan.", "We need a new plan."),
            ("И, э, и потом мы уйдём.", "И потом мы уйдём."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
        }
    }

    /// A conjunction or preposition opens a phrase of its own, so the word
    /// before it can close the phrase before: "shipped it and, um, it works"
    /// says "it" twice and means both. A phrase stopped on one is begun again
    /// only from a sentence's start or a comma.
    func testAWordSaidAgainAfterAConjunctionAndAHesitationStays() {
        let cases = [
            ("We shipped it and, um, it works.", "We shipped it and it works."),
            ("So we, uh, shipped it and, um, it works.", "So we shipped it and it works."),
            ("We shipped it and uh, it works.", "We shipped it and it works."),
            ("We shipped it but, uh, it crashed on launch.", "We shipped it but it crashed on launch."),
            ("I tested it so, um, it should be fine.", "I tested it so it should be fine."),
            ("We'll ship it when, uh, it is ready.", "We'll ship it when it is ready."),
            ("Ship it if, um, it passes review.", "Ship it if it passes review."),
            ("I can do it or, uh, it can wait.", "I can do it or it can wait."),
            ("We test it then, um, it ships.", "We test it then it ships."),
            ("I'll ask Sam and, uh, Sam will know.", "I'll ask Sam and Sam will know."),
            ("We moved the server and, uh, the server is faster now.", "We moved the server and the server is faster now."),
            ("I told you that, um, you should come.", "I told you that you should come."),
            ("We talked to them about, um, them joining.", "We talked to them about them joining."),
            ("Мы сделали это и, э, это работает.", "Мы сделали это и это работает."),
            ("Позвони ему или, э, ему напишет Лена.", "Позвони ему или ему напишет Лена."),
            // Begun again from the sentence's start or a comma, it is a restart.
            ("I think that, um, I think we should wait.", "I think we should wait."),
            ("Okay, I think that, um, I think we should wait.", "Okay, I think we should wait."),
            ("Let's meet at, uh, let's meet on Monday.", "Let's meet on Monday."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
            XCTAssertEqual(CleanVerbatim.clean(input, spokenCorrections: false), expected, input)
        }
    }

    func testRoundSixKeepsWhatWasMeant() {
        for text in [
            "Is it safe to merge? Uh uh.",
            "Nuh uh, that's not true.",
            "Uh uh, don't merge that.",
            "The old migration is broken. Scratch that? Or fix it?",
            "If I say, scratch that, it should delete the sentence.",
            "When the user says, scratch that, remove the last sentence.",
            "Use the format dd, mmm, yyyy.",
            "The date tokens are dd, mmm, and yyyy.",
            "He he, that's funny.",
            "He he he, nice one.",
            "Гласные: а, о, у, э, ы.",
        ] {
            XCTAssertEqual(CleanVerbatim.clean(text), text, text)
        }
    }

    func testRoundSixRemovesWhatWasNotMeant() {
        let cases = [
            ("Can you come at 9 a.m., um?", "Can you come at 9 a.m.?"),
            ("Is it ready by 5 p.m., uh?", "Is it ready by 5 p.m.?"),
            ("Hi Anna, Dr. Lee is here. Scratch that.", ""),
            ("I asked the team. Dr. Smith said no. Scratch that.", "I asked the team."),
            ("On Monday Dr. Smith called. Scratch that, on Tuesday.", "On Tuesday."),
            ("Invite Anna, Dr. Smith and Bob. Scratch that.", ""),
            ("Call Dr. Uh scratch that, call the nurse.", "Call the nurse."),
            ("Book it with Dr. Scratch that. Book it with the nurse.", "Book it with the nurse."),
            ("That's the plan. Um. Let's see what you think.", "That's the plan. Let's see what you think."),
            ("I don't know. Um... maybe you should ask them.", "I don't know. Maybe you should ask them."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CleanVerbatim.clean(input), expected, input)
            XCTAssertEqual(CleanVerbatim.clean(CleanVerbatim.clean(input)), expected, "idempotent: \(input)")
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
        XCTAssertEqual(TextPipeline().process("This is the end um, new line.").text, "This is the end\n")
        XCTAssertEqual(TextPipeline().process("Гласные: а, о, у, э, новая строка").text, "Гласные: а, о, у, э\n")
        let um = TextPipeline().process("Um, new line.")
        XCTAssertEqual(um.text, "New line.")
        let send = TextPipeline(allowPressReturnCommand: true).process("Um, send it.")
        XCTAssertEqual(send.text, "Send it.")
        XCTAssertNil(send.command, "never type a hesitation and press Return")
    }

    /// In a terminal a hesitation or stutter right before "Send it." is gone
    /// once the text is clean, and what is left is "Send it." as its own final
    /// sentence: Return, not the words typed at the prompt.
    func testAHesitationOrStutterBeforeSendItStillPressesReturn() {
        let terminal = TextPipeline(allowPressReturnCommand: true)
        for said in ["git status. Um, send it.", "git status. Uh, send it.", "git status. Send, send it."] {
            let output = terminal.process(said)
            XCTAssertEqual(output.text, "Git status.", said)
            XCTAssertEqual(output.command, .pressReturn, said)
        }
        // Every other rule still holds: never mid-sentence, never alone,
        // never outside a terminal.
        for said in ["Review the doc, um, send it.", "and then we, uh, send it", "Uh, send it."] {
            XCTAssertNil(terminal.process(said).command, said)
        }
        let elsewhere = TextPipeline().process("git status. Um, send it.")
        XCTAssertNil(elsewhere.command)
        XCTAssertEqual(elsewhere.text, "Git status. Send it.")
    }

    /// Cleanup keeps a hesitation that is also a word ("Um.", "Э.") when it
    /// stands alone, so it can be all that is left before "Send it.". Nothing
    /// but hesitation is nothing to send: the take is typed as words and
    /// Return is not pressed. One real word is enough.
    func testNothingButAHesitationIsNeverTypedAndSent() {
        let terminal = TextPipeline(allowPressReturnCommand: true)
        for said in [
            "Um. Um, send it.", "Um. Uh, send it.", "Um.\u{2029}Uh, send it.", "Um. Send it.",
            "Hmm, um. Send it.", "Er. Send it.", "Mmm. Send it.",
            "\u{042D}. \u{042D}, \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}.",
            "\u{042D}\u{043C}. \u{042D}, \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}.",
        ] {
            XCTAssertNil(terminal.process(said).command, said)
        }
        XCTAssertEqual(terminal.process("Um. Um, send it.").text, "Um. Send it.")
        for said in ["Yes. Um, send it.", "\u{0414}\u{0430}. \u{042D}, \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}."] {
            XCTAssertEqual(terminal.process(said).command, .pressReturn, said)
        }
    }

    /// Return is decided on the cleaned text only when "Send it." was the last
    /// thing said. Words after it that cleanup takes away ("Stop, scratch
    /// that.") mean the person was taking the send back, and a dictionary
    /// entry that writes "send it" was never the command said aloud.
    func testSendItIsReturnOnlyWhenItWasTheLastThingSaid() {
        let terminal = TextPipeline(allowPressReturnCommand: true)
        for said in [
            "Fix the failing test. Send it. Stop, scratch that.",
            "git push --force. Send it. Hold on, scratch that.",
            "git push --force. Send it. Not yet. Scratch that.",
            "rm -rf build. Send it. Uh, hold on, scratch that.",
        ] {
            XCTAssertNil(terminal.process(said).command, said)
        }
        let shipIt = TextPipeline(
            replacements: [DictionaryReplacement(spoken: "ship it", written: "send it", inflects: false)],
            allowPressReturnCommand: true
        )
        for said in ["git status. Ship it.", "git status. Um, ship it."] {
            XCTAssertNil(shipIt.process(said).command, said)
        }
    }

    /// The sentence end before "Send it." has to be one the person said. A
    /// dictionary entry that writes one ("Acme Inc.", ".") is not a sentence
    /// ending in what was said, so "tell acme send it" stays words.
    func testASentenceEndTheDictionaryWroteDoesNotPressReturn() {
        let acme = TextPipeline(
            replacements: [DictionaryReplacement(spoken: "acme", written: "Acme Inc.")],
            allowPressReturnCommand: true
        )
        for said in ["tell acme send it", "ask acme, um, send it"] {
            XCTAssertNil(acme.process(said).command, said)
        }
        let dot = TextPipeline(
            replacements: [DictionaryReplacement(spoken: "dot", written: ".")],
            allowPressReturnCommand: true
        )
        XCTAssertNil(dot.process("git add dot send it").command)
        XCTAssertEqual(acme.process("tell acme. Um, send it.").command, .pressReturn, "a sentence end that was said")
    }

    /// The built-in dictionary writes "commit в" and "Docker и в Kubernetes";
    /// only a word written with a capital is a name to protect, so Russian
    /// stutters still collapse in the shipping app.
    func testTheStarterDictionaryDoesNotProtectConnectingWords() {
        let pipeline = TextPipeline(replacements: StarterDictionary.missing(from: []))
        XCTAssertEqual(pipeline.process("Я и и ты пойдём.").text, "Я и ты пойдём.")
        XCTAssertEqual(pipeline.process("Положи файл в в папку.").text, "Положи файл в папку.")
        let words = CleanVerbatim.protectedWords(from: [
            DictionaryReplacement(spoken: "коммит в", written: "commit в", inflects: false),
            DictionaryReplacement(spoken: "the the", written: "The The", inflects: false),
        ])
        XCTAssertEqual(words, ["the"])
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
            pipeline: { _ in TextPipeline() }
        )
        var archived: [String] = []
        controller.onTakeFinished = { text, _, _ in
            archived.append(text)
            return true
        }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        for _ in 0..<12 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        controller.stop()
        for _ in 0..<24 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }

        let inserted = await inserter.insertedTexts
        let notices = await overlay.notices
        let plays = await sounds.attentionPlays
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(archived, ["Ship it Friday. Scratch that."], "kept in History with what was heard")
        XCTAssertTrue(notices.contains { $0.message == "Nothing left to insert after cleanup." }, "\(notices)")
        XCTAssertFalse(notices.contains { $0.wordsDidNotLand })
        XCTAssertEqual(plays, 0, "nothing was lost, so no alarm")
    }
}

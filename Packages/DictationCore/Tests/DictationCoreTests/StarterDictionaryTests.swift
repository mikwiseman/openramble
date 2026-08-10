import XCTest
@testable import DictationCore

/// Checks on the real output of the model.
///
/// The texts below are not fiction: this is how Parakeet recognized the phrase
/// “You need to make a pull request and run deploy through Sentry”,
/// dictated in Russian. The model writes English words in Cyrillic, and the dictionary
/// exists precisely to return them to their normal appearance.
final class StarterDictionaryTests: XCTestCase {
    func testFixesRealTranscriptionOfDeveloperSpeech() {
        let pipeline = TextPipeline(replacements: StarterDictionary.developer)

        // Exactly what the model returned during the live run.
        let recognized = "\u{041F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044F}\u{044E} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0443}. \u{041D}\u{0443}\u{0436}\u{043D}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442} \u{0438} \u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438}\u{0442}\u{044C} \u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439} \u{0447}\u{0435}\u{0440}\u{0435}\u{0437} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}."

        let output = pipeline.process(recognized)

        XCTAssertEqual(
            output.text,
            "\u{041F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044F}\u{044E} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0443}. \u{041D}\u{0443}\u{0436}\u{043D}\u{043E} \u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0442}\u{044C} pull request \u{0438} \u{0437}\u{0430}\u{043F}\u{0443}\u{0441}\u{0442}\u{0438}\u{0442}\u{044C} deploy \u{0447}\u{0435}\u{0440}\u{0435}\u{0437} Sentry."
        )
    }

    func testHandlesBothSpellingsOfPullRequest() {
        let pipeline = TextPipeline(replacements: StarterDictionary.developer)

        // The model can be written together or separately - both options should work.
        XCTAssertEqual(pipeline.process("\u{0437}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B} \u{043F}\u{0443}\u{043B}\u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}").text, "\u{0417}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B} pull request")
        XCTAssertEqual(pipeline.process("\u{0437}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}").text, "\u{0417}\u{0430}\u{043A}\u{0438}\u{043D}\u{0443}\u{043B} pull request")
    }

    func testDoesNotTouchWordsInsideOtherWords() {
        let pipeline = TextPipeline(replacements: StarterDictionary.developer)

        // “api” is in the dictionary, but “april” and “lapi” cannot be touched.
        let output = pipeline.process("\u{0432} \u{0430}\u{043F}\u{0440}\u{0435}\u{043B}\u{0435} \u{043B}\u{0430}\u{043F}\u{0438}\u{0434}\u{0430}\u{0440}\u{043D}\u{043E}")

        XCTAssertEqual(output.text, "\u{0412} \u{0430}\u{043F}\u{0440}\u{0435}\u{043B}\u{0435} \u{043B}\u{0430}\u{043F}\u{0438}\u{0434}\u{0430}\u{0440}\u{043D}\u{043E}")
    }

    func testContainsNoPointlessSelfReplacements() {
        // Replacing a word with itself does nothing, it just clutters the list,
        // which the user then views with their eyes.
        for replacement in StarterDictionary.developer {
            XCTAssertNotEqual(
                replacement.spoken.lowercased(),
                replacement.written.lowercased(),
                "\u{0411}\u{0435}\u{0441}\u{0441}\u{043C}\u{044B}\u{0441}\u{043B}\u{0435}\u{043D}\u{043D}\u{0430}\u{044F} \u{0437}\u{0430}\u{043C}\u{0435}\u{043D}\u{0430}: \(replacement.spoken)"
            )
        }
    }

    func testMissingSkipsWhatUserAlreadyHas() {
        let existing = [
            DictionaryReplacement(spoken: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", written: "\u{0432}\u{044B}\u{043A}\u{0430}\u{0442}\u{043A}\u{0430}"),
        ]

        let missing = StarterDictionary.missing(from: existing)

        // Our replacement is more important than our workpiece - we do not offer a duplicate.
        XCTAssertFalse(missing.contains { $0.spoken.lowercased() == "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}" })
        XCTAssertTrue(missing.contains { $0.spoken == "\u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}" })
    }

    func testEveryEntryIsUsable() {
        for replacement in StarterDictionary.developer {
            XCTAssertFalse(replacement.spoken.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(replacement.written.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

final class ShortRecordingPolicyTests: XCTestCase {
    func testVeryShortRecordingIsNotWorthTranscribing() {
        // The engine refuses to work with records shorter than 300 ms, but the main thing is not
        // this: the person who pressed and immediately released the key simply changed his mind.
        // Showing him a recognition error is scary out of the blue.
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: 0.1))
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: 0.3))
        XCTAssertTrue(DictationDurationPolicy.isWorthTranscribing(duration: 0.5))
        XCTAssertTrue(DictationDurationPolicy.isWorthTranscribing(duration: 5))
    }
}

/// The sign “do not boost with acoustics” lives in the workpiece data.
final class StarterDictionaryBoostFlagTests: XCTestCase {
    /// Main tripwire of the task.
    ///
    /// The hardcode has been removed from `VocabularyBoost`, and if the sign is not included here,
    /// deploy/Sentry/commit will silently return to acoustics - that is, it will roll back
    /// a measurement that was worth a separate day.
    func testDangerousTermsCarryTheFlagInTheData() {
        let flagged = Set(
            StarterDictionary.developer.filter(\.noAcousticBoost).map(\.written)
        )
        XCTAssertEqual(flagged, ["deploy", "Sentry", "commit"])
    }

    /// All spellings of the dangerous term are marked, not just the first one: “commit” and
    /// "comets" lead to one `commit`, and omitting any would bring it back.
    func testEverySpellingOfAFlaggedTermIsFlagged() {
        for term in StarterDictionary.developer where ["deploy", "Sentry", "commit"].contains(term.written) {
            XCTAssertTrue(term.noAcousticBoost, "\(term.spoken) → \(term.written)")
        }
    }

    func testOrdinaryTermsAreStillBoosted() {
        for term in StarterDictionary.developer where term.written == "Postgres" || term.written == "Docker" {
            XCTAssertFalse(term.noAcousticBoost, term.written)
        }
    }

    /// Dictionaries written before the sign appears are read as “boosts” -
    /// used to solve the list, not the record.
    func testOldDictionariesDecodeWithoutTheFlag() throws {
        let json = """
        {"id":"\(UUID().uuidString)","spoken":"\u{0433}\u{0440}\u{0430}\u{0444}\u{0430}\u{043D}\u{0430}","written":"Grafana"}
        """
        let decoded = try JSONDecoder().decode(DictionaryReplacement.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.noAcousticBoost)
        XCTAssertTrue(decoded.inflects)
    }

    func testFlagSurvivesRoundTrip() throws {
        let original = DictionaryReplacement(
            spoken: "\u{043A}\u{0430}\u{0441}\u{0441}\u{0430}", written: "Kassa", inflects: false, noAcousticBoost: true
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(DictionaryReplacement.self, from: data)
        XCTAssertEqual(restored, original)
    }
}

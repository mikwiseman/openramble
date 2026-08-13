import DictationCore
import Foundation
import XCTest

/// End-to-end dictation tests: real sound, real model, real dictionary.
///
/// Each layer is checked individually, but the joints between them are not. Here
/// exactly what cannot be seen in the test of one layer is checked: does it reach
/// what is said from the file to the insertion in its entirety, in the correct form and without other people’s tails.
@MainActor
final class DictationEndToEndTests: EndToEndScenario {
    // MARK: - Main product scenario

    /// A Russian phrase with English terms is inserted in Latin letters.
    ///
    /// For this reason, there is a dictionary of substitutions: inside the Russian phrase the model is honest
    /// writes the term in Cyrillic - “pull request”, “production” - and the person waits
    /// “pull request” and “production”. You can only check this in its entirety:
    /// the legal model is separate, the dictionary works separately, but they must match
    /// on the same text.
    func testMixedRussianEnglishPhraseArrivesWithLatinTerms() async throws {
        try await speak(Phrase.mixed)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        XCTAssertEqual(texts.count, 1, "\u{041E}\u{0434}\u{043D}\u{0430} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} — \u{043E}\u{0434}\u{043D}\u{0430} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0430}")
        let text = try XCTUnwrap(texts.first)

        for term in Phrase.mixedTerms {
            XCTAssertTrue(
                text.contains(term),
                "\u{0422}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D} «\(term)» \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{043F}\u{0440}\u{0438}\u{0439}\u{0442}\u{0438} \u{043B}\u{0430}\u{0442}\u{0438}\u{043D}\u{0438}\u{0446}\u{0435}\u{0439}. \u{041F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(text)"
            )
        }

        // We check not only the appearance of the Latin alphabet, but also the disappearance of the Cyrillic alphabet:
        // the replacement that added the term next to the old spelling is also broken.
        for spoken in ["\u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442}", "\u{0433}\u{0438}\u{0442}\u{0445}\u{0430}\u{0431}", "\u{043B}\u{0438}\u{043D}\u{0442}\u{0435}\u{0440}", "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{043F}\u{0440}\u{043E}\u{0434}\u{0430}\u{043A}\u{0448}\u{043D}"] {
            XCTAssertFalse(
                text.containsInsensitive(spoken),
                "\u{041A}\u{0438}\u{0440}\u{0438}\u{043B}\u{043B}\u{0438}\u{0447}\u{0435}\u{0441}\u{043A}\u{043E}\u{0435} \u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043D}\u{0438}\u{0435} «\(spoken)» \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{043E}\u{0441}\u{044C} \u{0432} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}\u{0435}: \(text)"
            )
        }

        // Word order - separate check: replacements are made using a regular expression
        // along the entire line and the pieces could be rearranged imperceptibly.
        let positions = Phrase.mixedTerms.compactMap { text.position(of: $0) }
        XCTAssertEqual(positions.count, Phrase.mixedTerms.count)
        XCTAssertEqual(positions, positions.sorted(), "\u{041F}\u{043E}\u{0440}\u{044F}\u{0434}\u{043E}\u{043A} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\u{043E}\u{0432} \u{0432}\u{043E} \u{0444}\u{0440}\u{0430}\u{0437}\u{0435} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}")

        // Length is compared essentially: the model may misspell a word, but not
        // has the rights to lose or double the phrase.
        XCTAssertEqual(
            Double(text.wordCount),
            Double(Phrase.mixed.wordCount),
            accuracy: 3,
            "\u{0414}\u{043B}\u{0438}\u{043D}\u{0430} \u{0440}\u{0430}\u{0437}\u{043E}\u{0448}\u{043B}\u{0430}\u{0441}\u{044C} \u{0441}\u{043E} \u{0441}\u{043A}\u{0430}\u{0437}\u{0430}\u{043D}\u{043D}\u{044B}\u{043C}: \(text)"
        )

        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0, "\u{041A}\u{043E}\u{043C}\u{0430}\u{043D}\u{0434}\u{044B} \u{0432} \u{044D}\u{0442}\u{043E}\u{0439} \u{0444}\u{0440}\u{0430}\u{0437}\u{0435} \u{043D}\u{0435} \u{0431}\u{044B}\u{043B}\u{043E}")

        // The text must go where it was dictated, and not where the focus is now.
        let target = await inserter.insertions.first?.target
        XCTAssertEqual(target?.bundleIdentifier, "com.apple.TextEdit")

        // A dictation that lands makes no sound at all: the text at the
        // cursor is the receipt, and the one signal the product has is
        // reserved for words that never got there.
        let plays = await sounds.attentionPlays
        XCTAssertEqual(plays, 0, "a working dictation is silent end to end")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// Terms in oblique cases reach insertion in Latin letters.
    ///
    /// “In Python”, “without downtime” - this is exactly what the person says, and exactly in
    /// this replacement by exact match never worked. Checked
    /// end-to-end, because the declination comes up not with the test, but with the model.
    func testDeclinedTermsStillReachInsertionInLatin() async throws {
        try await speak(Phrase.declined)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        for term in Phrase.declinedTerms {
            XCTAssertTrue(
                text.contains(term),
                "\u{0422}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D} «\(term)» \u{0432} \u{043A}\u{043E}\u{0441}\u{0432}\u{0435}\u{043D}\u{043D}\u{043E}\u{043C} \u{043F}\u{0430}\u{0434}\u{0435}\u{0436}\u{0435} \u{043D}\u{0435} \u{0437}\u{0430}\u{043C}\u{0435}\u{043D}\u{0438}\u{043B}\u{0441}\u{044F}. \u{041F}\u{0440}\u{0438}\u{0448}\u{043B}\u{043E}: \(text)"
            )
        }
        for spoken in ["\u{0441}\u{0432}\u{0438}\u{0444}\u{0442}", "\u{0431}\u{0438}\u{043B}\u{0434}", "\u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}"] {
            XCTAssertFalse(
                text.containsInsensitive(spoken),
                "\u{041A}\u{0438}\u{0440}\u{0438}\u{043B}\u{043B}\u{0438}\u{0447}\u{0435}\u{0441}\u{043A}\u{043E}\u{0435} \u{043D}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043D}\u{0438}\u{0435} «\(spoken)» \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{043E}\u{0441}\u{044C}: \(text)"
            )
        }

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// An ordinary Russian word similar to a term does not touch the dictionary.
    ///
    /// “In the city center” should not become “in the Sentry city”. Replacements are coming
    /// regular expressions with case tails, and the price of an error here is
    /// corrupted ordinary speech, not just an unreplaced term.
    func testOrdinaryWordThatLooksLikeATermIsLeftAlone() async throws {
        try await speak(Phrase.falseFriend)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        XCTAssertFalse(text.contains("Sentry"), "\u{041E}\u{0431}\u{044B}\u{0447}\u{043D}\u{043E}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E} \u{043F}\u{043E}\u{0434}\u{043C}\u{0435}\u{043D}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} \u{0442}\u{0435}\u{0440}\u{043C}\u{0438}\u{043D}\u{043E}\u{043C}: \(text)")
        XCTAssertTrue(text.containsInsensitive("\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}"), "\u{0421}\u{043B}\u{043E}\u{0432}\u{043E} \u{0438}\u{0437} \u{0444}\u{0440}\u{0430}\u{0437}\u{044B} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{043E}: \(text)")
        XCTAssertTrue(text.containsInsensitive("\u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}"), "\u{0421}\u{043B}\u{043E}\u{0432}\u{043E} \u{0438}\u{0437} \u{0444}\u{0440}\u{0430}\u{0437}\u{044B} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{043E}: \(text)")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// Safe beta does not turn what is spoken into an irreversible sending.
    func testEnglishTrailingSendStaysVerbatimAndNeverPressesReturn() async throws {
        try await speak(Phrase.englishSend, voice: .english)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        XCTAssertTrue(text.contains("pull request"), "\u{0410}\u{043D}\u{0433}\u{043B}\u{0438}\u{0439}\u{0441}\u{043A}\u{0430}\u{044F} \u{0444}\u{0440}\u{0430}\u{0437}\u{0430} \u{043F}\u{0440}\u{0438}\u{0448}\u{043B}\u{0430} \u{043D}\u{0435} \u{0446}\u{0435}\u{043B}\u{0438}\u{043A}\u{043E}\u{043C}: \(text)")
        XCTAssertTrue(text.containsInsensitive("send it"), "\u{041F}\u{0440}\u{043E}\u{0438}\u{0437}\u{043D}\u{0435}\u{0441}\u{0451}\u{043D}\u{043D}\u{044B}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{0430} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{0438}: \(text)")

        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0, "\u{0420}\u{0435}\u{0447}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{0432} safe beta")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// The three-minute dictation comes in its entirety, including the tail.
    ///
    /// The only place where you can see the silent loss of speech at the junction
    /// fifteen second engine windows: the end of the sentence disappears without error and
    /// without warning. Neither a test of one layer nor a short recording of this
    /// caught - you need a real long recording that goes all the way.
    func testThreeMinuteDictationArrivesWholeWithoutLosingTheTail() async throws {
        try await speak(Phrase.veryLong)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)

        // The paragraph is spoken five times - all five must be completed.
        let repeats = text.occurrences(of: "\u{0412}\u{0435}\u{0447}\u{0435}\u{0440}\u{043E}\u{043C} \u{043C}\u{044B} \u{0441}\u{043E}\u{0431}\u{0438}\u{0440}\u{0430}\u{0435}\u{043C} \u{0441}\u{0431}\u{043E}\u{0440}\u{043A}\u{0443}")
        XCTAssertEqual(repeats, 5, "\u{0418}\u{0437} \u{043F}\u{044F}\u{0442}\u{0438} \u{043F}\u{043E}\u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0432} \u{0434}\u{043E}\u{0448}\u{043B}\u{043E} \(repeats): \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043F}\u{043E}\u{0442}\u{0435}\u{0440}\u{044F}\u{043D} \u{043D}\u{0430} \u{0441}\u{0442}\u{044B}\u{043A}\u{0435} \u{043E}\u{043A}\u{043E}\u{043D}")

        let expected = Double(Phrase.long.wordCount * 5)
        XCTAssertGreaterThan(
            Double(text.wordCount),
            expected * 0.9,
            "\u{0418}\u{0437} \(Int(expected)) \u{0441}\u{043B}\u{043E}\u{0432} \u{0434}\u{043E}\u{0448}\u{043B}\u{043E} \(text.wordCount)"
        )

        // The tail is the most vulnerable place: it is it that disappears silently.
        let tail = String(text.suffix(60))
        XCTAssertTrue(tail.containsInsensitive("\u{0437}\u{0430}\u{0440}\u{0430}\u{043D}\u{0435}\u{0435}"), "\u{041A}\u{043E}\u{043D}\u{0435}\u{0446} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438} \u{043D}\u{0435} \u{0434}\u{043E}\u{0448}\u{0451}\u{043B}: …\(tail)")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Command at the end of the phrase

    /// “Submit” remains plain text and never hits Return.
    func testTrailingSendStaysVerbatimAndNeverPressesReturn() async throws {
        try await speak(Phrase.send)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0, "False trigger \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435}")

        XCTAssertTrue(
            text.containsInsensitive("\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}"),
            "\u{041F}\u{0440}\u{043E}\u{0438}\u{0437}\u{043D}\u{0435}\u{0441}\u{0451}\u{043D}\u{043D}\u{043E}\u{0435} \u{0441}\u{043B}\u{043E}\u{0432}\u{043E} \u{0438}\u{0441}\u{0447}\u{0435}\u{0437}\u{043B}\u{043E}: \(text)"
        )
        // The main danger here is cutting off adjacent words along with the command.
        for word in ["\u{041F}\u{0440}\u{043E}\u{0432}\u{0435}\u{0440}\u{044C}", "pull request", "\u{043F}\u{043E}\u{0436}\u{0430}\u{043B}\u{0443}\u{0439}\u{0441}\u{0442}\u{0430}"] {
            XCTAssertTrue(text.containsInsensitive(word), "\u{0421}\u{043B}\u{043E}\u{0432}\u{043E} «\(word)» \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{043E}: \(text)")
        }

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    /// “New line” goes into the text itself, and not into the keystroke.
    ///
    /// You can’t do it by clicking it: Return in someone else’s window sends a message,
    /// does not break the line.
    func testTrailingNewLineCommandGoesIntoTheTextItself() async throws {
        try await speak(Phrase.newLine)
        let controller = makeController()

        await dictate(with: controller)

        let texts = await inserter.texts
        let text = try XCTUnwrap(texts.first)
        XCTAssertTrue(text.hasSuffix("\n"), "\u{041F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{0432} \u{0441}\u{0430}\u{043C}\u{043E}\u{043C} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}\u{0435}: \(text.debugDescription)")
        XCTAssertTrue(text.containsInsensitive("\u{043C}\u{044B}\u{0441}\u{043B}\u{044C}"), "\u{0421}\u{043B}\u{043E}\u{0432}\u{0430} \u{0438}\u{0437} \u{0444}\u{0440}\u{0430}\u{0437}\u{044B} \u{043F}\u{0440}\u{043E}\u{043F}\u{0430}\u{043B}\u{0438}: \(text)")
        XCTAssertFalse(text.containsInsensitive("\u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"), "\u{041A}\u{043E}\u{043C}\u{0430}\u{043D}\u{0434}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} \u{0432} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}\u{0435}: \(text)")

        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0, "Return \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{043B} \u{0431}\u{044B} \u{0441}\u{043E}\u{043E}\u{0431}\u{0449}\u{0435}\u{043D}\u{0438}\u{0435} \u{0432}\u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{043F}\u{0435}\u{0440}\u{0435}\u{043D}\u{043E}\u{0441}\u{0430} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}")

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Cancel

    /// Canceling in the middle of recognizing a long record does not insert anything.
    ///
    /// Cancellation is guaranteed after recognition starts: thirty
    /// the engine parses seconds of speech in a fraction of a second, and without this synchronization
    /// the test would check for cancellation BEFORE recognition - a completely different path.
    func testCancelDuringRealRecognitionInsertsNothing() async throws {
        try await speak(Phrase.long)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitUntil("\u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043F}\u{043E}\u{0448}\u{043B}\u{0430}") { controller.state == .listening }
        controller.stop()
        await waitUntil("\u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435} \u{043D}\u{0430}\u{0447}\u{0430}\u{043B}\u{043E}\u{0441}\u{044C}") { await self.probe.calls == 1 }

        controller.cancel()
        await waitUntil("\u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{043B}\u{0430}\u{0441}\u{044C}") { controller.state == .idle }

        let texts = await inserter.texts
        XCTAssertEqual(texts, [], "\u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442} \u{043D}\u{0438}\u{0447}\u{0435}\u{0433}\u{043E}")
        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0)

        // The microphone is the only thing visible to the user outside the application.
        let aborts = await capture.abortCount
        let recording = await capture.isRecording
        XCTAssertGreaterThanOrEqual(aborts, 1, "\u{0417}\u{0430}\u{0445}\u{0432}\u{0430}\u{0442} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D} \u{0431}\u{044B}\u{0442}\u{044C} \u{043F}\u{043E}\u{0433}\u{0430}\u{0448}\u{0435}\u{043D} \u{044F}\u{0432}\u{043D}\u{043E}")
        XCTAssertFalse(recording, "\u{041C}\u{0438}\u{043A}\u{0440}\u{043E}\u{0444}\u{043E}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{043C} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{044B}")

        // The entry is removed after the session declares itself closed: deletion
        // is in the `defer` of the final task, and the task is set to “free”
        // cancel. We print the gap - it is the found joint defect.
        let delay = await assertNoRecordingsLeft()
        let interrupted = await probe.failures
        print(
            """
            \u{041E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0430} \u{043F}\u{043E}\u{0441}\u{0440}\u{0435}\u{0434}\u{0438} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{044F}:
              \u{0434}\u{0432}\u{0438}\u{0436}\u{043E}\u{043A} \(interrupted.first.map { "\u{043F}\u{0440}\u{0435}\u{0440}\u{0432}\u{0430}\u{043D} — \($0)" } ?? "\u{0443}\u{0441}\u{043F}\u{0435}\u{043B} \u{0434}\u{043E}\u{0433}\u{043E}\u{0432}\u{043E}\u{0440}\u{0438}\u{0442}\u{044C} \u{0441}\u{0430}\u{043C}")
              \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0443}\u{0431}\u{0440}\u{0430}\u{043D}\u{0430} \u{0447}\u{0435}\u{0440}\u{0435}\u{0437} \(Self.milliseconds(delay)) \u{043C}\u{0441} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{0441}\u{043E}\u{0441}\u{0442}\u{043E}\u{044F}\u{043D}\u{0438}\u{044F} «\u{0441}\u{0432}\u{043E}\u{0431}\u{043E}\u{0434}\u{043D}\u{043E}»
            """
        )

        await assertNoFailureNotices()
    }

    /// A canceled dictation does not spoil the next one started immediately after it.
    ///
    /// The most unpleasant connection: the tail of the canceled session wakes up already during
    /// new. It is tested on a real model, because it is this model that creates
    /// the delay during which the tail manages to wake up.
    func testCancelledDictationDoesNotPoisonTheNextOne() async throws {
        try await speak(Phrase.long)
        try await speak(Phrase.other)
        let controller = makeController()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await waitUntil("\u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043F}\u{043E}\u{0448}\u{043B}\u{0430}") { controller.state == .listening }
        controller.stop()
        await waitUntil("\u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435} \u{043D}\u{0430}\u{0447}\u{0430}\u{043B}\u{043E}\u{0441}\u{044C}") { await self.probe.calls == 1 }
        controller.cancel()
        await waitUntil("\u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{0430}\u{044F} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{044F} \u{0437}\u{0430}\u{043A}\u{0440}\u{044B}\u{043B}\u{0430}\u{0441}\u{044C}") { controller.state == .idle }

        await dictate(with: controller)

        let texts = await inserter.texts
        XCTAssertEqual(texts.count, 1, "\u{0412}\u{0441}\u{0442}\u{0430}\u{0432}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{0442}\u{043E}\u{043B}\u{044C}\u{043A}\u{043E} \u{0432}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430}")
        let text = try XCTUnwrap(texts.first)
        XCTAssertTrue(text.containsInsensitive(Phrase.otherMarker), "\u{0412}\u{0441}\u{0442}\u{0430}\u{0432}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} \u{043D}\u{0435} \u{0442}\u{043E}: \(text)")
        XCTAssertFalse(
            text.containsInsensitive(Phrase.longMarker),
            "\u{0412} \u{043D}\u{043E}\u{0432}\u{0443}\u{044E} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0443} \u{043F}\u{0440}\u{043E}\u{0442}\u{0451}\u{043A} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{043E}\u{0442}\u{043C}\u{0435}\u{043D}\u{0451}\u{043D}\u{043D}\u{043E}\u{0439}: \(text)"
        )

        let recording = await capture.isRecording
        XCTAssertFalse(recording, "\u{041C}\u{0438}\u{043A}\u{0440}\u{043E}\u{0444}\u{043E}\u{043D} \u{043E}\u{0441}\u{0442}\u{0430}\u{043B}\u{0441}\u{044F} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0451}\u{043D}\u{043D}\u{044B}\u{043C}")
        await assertNoRecordingsLeft()
    }

    // MARK: - Two dictations in a row

    /// Two dictations in a row arrive completely and do not mix.
    ///
    /// The engine is reused between sessions, and the decoder state is shared
    /// the place where the tail of the first phrase can flow into the second. See this
    /// only possible on two different real records in a row.
    func testTwoDictationsInARowDoNotMix() async throws {
        try await speak(Phrase.mixed)
        try await speak(Phrase.other)
        let controller = makeController()

        await dictate(with: controller)
        await dictate(with: controller)

        let texts = await inserter.texts
        XCTAssertEqual(texts.count, 2, "\u{041E}\u{0431}\u{0435} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0438} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{044B} \u{0434}\u{043E}\u{0439}\u{0442}\u{0438}")

        XCTAssertTrue(texts[0].contains("pull request"), "\u{041F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{043F}\u{0440}\u{0438}\u{0448}\u{043B}\u{0430} \u{043D}\u{0435} \u{043F}\u{043E}\u{043B}\u{043D}\u{043E}\u{0441}\u{0442}\u{044C}\u{044E}: \(texts[0])")
        XCTAssertFalse(
            texts[0].containsInsensitive(Phrase.otherMarker),
            "\u{0412} \u{043F}\u{0435}\u{0440}\u{0432}\u{0443}\u{044E} \u{043F}\u{043E}\u{043F}\u{0430}\u{043B} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442} \u{0432}\u{0442}\u{043E}\u{0440}\u{043E}\u{0439}: \(texts[0])"
        )

        XCTAssertTrue(
            texts[1].containsInsensitive(Phrase.otherMarker),
            "\u{0412}\u{0442}\u{043E}\u{0440}\u{0430}\u{044F} \u{043F}\u{0440}\u{0438}\u{0448}\u{043B}\u{0430} \u{043D}\u{0435} \u{043F}\u{043E}\u{043B}\u{043D}\u{043E}\u{0441}\u{0442}\u{044C}\u{044E}: \(texts[1])"
        )
        for term in ["pull request", "GitHub", "production"] {
            XCTAssertFalse(
                texts[1].containsInsensitive(term),
                "\u{0412}\u{043E} \u{0432}\u{0442}\u{043E}\u{0440}\u{0443}\u{044E} \u{043F}\u{0440}\u{043E}\u{0442}\u{0451}\u{043A} \u{0445}\u{0432}\u{043E}\u{0441}\u{0442} \u{043F}\u{0435}\u{0440}\u{0432}\u{043E}\u{0439} («\(term)»): \(texts[1])"
            )
        }

        let starts = await capture.startCount
        XCTAssertEqual(starts, 2)
        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }

    // MARK: - Edges

    /// I pressed it and immediately released it: it does not reach recognition, there is no file left.
    func testTooShortRecordingNeverReachesRecognition() async throws {
        try await speakBriefly(Phrase.short, seconds: 0.2)
        let controller = makeController()

        await dictate(with: controller)

        let calls = await probe.calls
        XCTAssertEqual(calls, 0, "\u{041E}\u{0431}\u{0440}\u{044B}\u{0432}\u{043E}\u{043A} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0434}\u{043E}\u{0445}\u{043E}\u{0434}\u{0438}\u{0442}\u{044C} \u{0434}\u{043E} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{0438}")
        let texts = await inserter.texts
        XCTAssertEqual(texts, [], "\u{0412}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E}")

        await assertNoRecordingsLeft()
        // The man simply changed his mind - there is no reason to scare him with a mistake.
        await assertNoFailureNotices()
    }

    /// The man remained silent: the model did not invent anything, there was no insertion.
    func testSilentRecordingProducesNoInsertion() async throws {
        try await stayQuiet(seconds: 3)
        let controller = makeController()

        await dictate(with: controller)

        // It’s not the duration that filters out the silence: the recording is complete, and it’s up to the model
        // gets there. It is the model’s response that must be empty.
        let calls = await probe.calls
        XCTAssertEqual(calls, 1, "\u{0422}\u{0440}\u{0451}\u{0445}\u{0441}\u{0435}\u{043A}\u{0443}\u{043D}\u{0434}\u{043D}\u{0430}\u{044F} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{0434}\u{043E}\u{0439}\u{0442}\u{0438} \u{0434}\u{043E} \u{0440}\u{0430}\u{0441}\u{043F}\u{043E}\u{0437}\u{043D}\u{0430}\u{0432}\u{0430}\u{043D}\u{0438}\u{044F}")
        let raw = await probe.rawTexts.first
        XCTAssertEqual(
            raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            "\u{041C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C} \u{0432}\u{044B}\u{0434}\u{0443}\u{043C}\u{0430}\u{043B}\u{0430} \u{0444}\u{0440}\u{0430}\u{0437}\u{0443} \u{0438}\u{0437} \u{0442}\u{0438}\u{0448}\u{0438}\u{043D}\u{044B}: \(raw ?? "—")"
        )

        let texts = await inserter.texts
        XCTAssertEqual(texts, [], "\u{041F}\u{0443}\u{0441}\u{0442}\u{043E}\u{0439} \u{0440}\u{0435}\u{0437}\u{0443}\u{043B}\u{044C}\u{0442}\u{0430}\u{0442} \u{043D}\u{0435} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0435}\u{0442}\u{0441}\u{044F}")
        let presses = await inserter.returnPresses
        XCTAssertEqual(presses, 0)

        await assertNoRecordingsLeft()
        await assertNoFailureNotices()
    }
}

import XCTest
@testable import DictationCore

/// A long pause after a sentence becomes a paragraph.
///
/// The timings below are what the shipping Parakeet model reported for
/// synthesized speech with a measured silence between sentences (macOS `say`,
/// two voices, 300 ms to 3 s). The model folds a pause into the previous word's
/// duration or into a gap before the next word, so both shapes appear here.
final class ParagraphBreaksTests: XCTestCase {
    private func words(_ spans: [(String, TimeInterval, TimeInterval)]) -> [ASRResult.Word] {
        spans.map { ASRResult.Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    func testAPauseFoldedIntoTheLastWordOfASentenceBreaksTheParagraph() {
        // 2 s of silence after "green." — the model stretched the word.
        let text = "The tests are green. Next, we ship."
        let timings = words([
            ("The", 0.0, 0.2), ("tests", 0.2, 0.5), ("are", 0.5, 0.8), ("green.", 0.8, 2.96),
            ("Next,", 2.96, 3.4), ("we", 3.4, 3.6), ("ship.", 3.6, 4.0),
        ])
        XCTAssertEqual(ParagraphBreaks.mark(text, words: timings), "The tests are green.\u{2029}Next, we ship.")
    }

    func testAPauseReportedAsAGapBreaksTheParagraph() {
        // 1.8 s of silence after "it." — the model left a gap instead.
        let text = "Then we test it. Finally we ship."
        let timings = words([
            ("Then", 0.0, 0.2), ("we", 0.2, 0.4), ("test", 0.4, 0.7), ("it.", 0.7, 1.34),
            ("Finally", 2.7, 3.2), ("we", 3.2, 3.4), ("ship.", 3.4, 3.9),
        ])
        XCTAssertEqual(ParagraphBreaks.mark(text, words: timings), "Then we test it.\u{2029}Finally we ship.")
    }

    func testAnOrdinaryPauseBetweenSentencesDoesNot() {
        // 1.2 s of silence measured: "yesterday." 1.68 s long — still one paragraph.
        let text = "We finished yesterday. Tomorrow we start."
        let timings = words([
            ("We", 0.0, 0.2), ("finished", 0.2, 0.7), ("yesterday.", 0.7, 2.38),
            ("Tomorrow", 2.38, 2.9), ("we", 2.9, 3.1), ("start.", 3.1, 3.6),
        ])
        XCTAssertEqual(ParagraphBreaks.mark(text, words: timings), text)
    }

    func testAPauseAfterACommaIsNotAParagraph() {
        let text = "We ship, and then we rest."
        let timings = words([
            ("We", 0.0, 0.2), ("ship,", 0.2, 3.0), ("and", 3.0, 3.2), ("then", 3.2, 3.4),
            ("we", 3.4, 3.5), ("rest.", 3.5, 3.9),
        ])
        XCTAssertEqual(ParagraphBreaks.mark(text, words: timings), text)
    }

    func testNothingFollowsTheLastWord() {
        let text = "We ship."
        XCTAssertEqual(
            ParagraphBreaks.mark(text, words: words([("We", 0.0, 0.2), ("ship.", 0.2, 4.0)])),
            text
        )
    }

    /// When the words cannot be matched to the text one for one, nothing is
    /// guessed: the text goes on unbroken.
    func testWordsThatDoNotMatchTheTextLeaveItAlone() {
        let text = "The tests are green. Next, we ship."
        XCTAssertEqual(ParagraphBreaks.mark(text, words: []), text)
        XCTAssertEqual(
            ParagraphBreaks.mark(text, words: words([("The", 0.0, 0.2), ("tests", 0.2, 5.0)])),
            text
        )
    }

    // MARK: - Through the pipeline

    func testTheMarkBecomesABlankLineInProseAndASpaceElsewhere() {
        let marked = "the tests are green.\u{2029}Next, we ship"
        XCTAssertEqual(TextPipeline(mode: .prose).process(marked).text, "The tests are green.\n\nNext, we ship")
        XCTAssertEqual(TextPipeline(mode: .verbatim).process(marked).text, "The tests are green. Next, we ship")
        XCTAssertEqual(TextPipeline().process(marked).text, "The tests are green. Next, we ship")
    }

    func testAHesitationRightAfterABreakDoesNotTakeTheBreakWithIt() {
        XCTAssertEqual(
            TextPipeline(mode: .prose).process("First point.\u{2029}Um, second point.").text,
            "First point.\n\nSecond point."
        )
    }

    /// A person who pauses before saying "New line." still gets a line break,
    /// not the words under a blank line.
    func testNewLineSaidAfterALongPauseIsStillALineBreak() {
        XCTAssertEqual(TextPipeline(mode: .prose).process("Dear John.\u{2029}New line.").text, "Dear John.\n")
        XCTAssertEqual(
            TextPipeline(mode: .prose).process("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}.\u{2029}\u{041D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}.").text,
            "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}.\n"
        )
        XCTAssertEqual(TextPipeline(mode: .verbatim).process("Dear John.\u{2029}New line.").text, "Dear John.\n")
    }
}

/// The whole path: a take with a long pause reaches a prose app as two
/// paragraphs and a terminal as one line.
@MainActor
final class ParagraphBreaksDictationTests: XCTestCase {
    private func dictate(into mode: PromptMode) async -> [String] {
        let inserter = FakeInserter()
        let controller = DictationController(
            capture: FakeCapture(),
            transcribe: { _ in
                ASRResult(
                    text: "The tests are green. Next, we ship.",
                    words: [
                        .init(text: "The", start: 0.0, end: 0.2), .init(text: "tests", start: 0.2, end: 0.5),
                        .init(text: "are", start: 0.5, end: 0.8), .init(text: "green.", start: 0.8, end: 2.96),
                        .init(text: "Next,", start: 2.96, end: 3.4), .init(text: "we", start: 3.4, end: 3.6),
                        .init(text: "ship.", start: 3.6, end: 4.0),
                    ],
                    audioDuration: 4,
                    processingDuration: 0.1
                )
            },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds(),
            pipeline: { _ in TextPipeline(mode: mode) }
        )
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        for _ in 0..<12 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        controller.stop()
        for _ in 0..<24 { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
        return await inserter.insertedTexts
    }

    func testAProseAppGetsTwoParagraphs() async {
        let inserted = await dictate(into: .prose)
        XCTAssertEqual(inserted, ["The tests are green.\n\nNext, we ship."])
    }

    func testATerminalGetsOneLine() async {
        let inserted = await dictate(into: .verbatim)
        XCTAssertEqual(inserted, ["The tests are green. Next, we ship."])
    }
}

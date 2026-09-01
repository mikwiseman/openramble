import XCTest
@testable import DictationCore

/// The origin of the dictation reaches the application - and only when inserted.
@MainActor
final class DictationProvenanceTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!
    private var overlay: FakeOverlay!
    private var sounds: FakeSounds!

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
        overlay = FakeOverlay()
        sounds = FakeSounds()
    }

    private func makeController(
        recognized: String,
        replacements: [DictionaryReplacement] = []
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in
                ASRResult(text: recognized, audioDuration: 2, processingDuration: 0.1)
            },
            inserter: inserter,
            overlay: overlay,
            sounds: sounds,
            pipeline: { TextPipeline(replacements: replacements) }
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testProvenanceIsReportedForEverySuccessfulInsertion() async throws {
        let controller = makeController(
            recognized: "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} \u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}",
            replacements: [
                DictionaryReplacement(spoken: "\u{043F}\u{043E}\u{0443}\u{0441}\u{0442} \u{0433}\u{0435}\u{0440}\u{0437}", written: "Postgres", inflects: false)
            ]
        )
        var reported: PipelineProvenance?
        controller.onDictationCompleted = { reported = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        let provenance = try XCTUnwrap(reported)
        XCTAssertEqual(provenance.afterDictionary, "\u{043E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres")
        XCTAssertEqual(provenance.finalText, "\u{041E}\u{0442}\u{043A}\u{0440}\u{043E}\u{0439} Postgres")

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted, [provenance.finalText], "\u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{0435}\u{043D}\u{043E} \u{0440}\u{043E}\u{0432}\u{043D}\u{043E} \u{0442}\u{043E}, \u{0447}\u{0442}\u{043E} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0430}\u{043D}\u{043E} \u{0444}\u{0438}\u{043D}\u{0430}\u{043B}\u{044C}\u{043D}\u{044B}\u{043C}")
    }

    /// Nothing was inserted - there is no origin.
    ///
    /// Otherwise, “copy verbatim” would give away a text that a person would never
    /// I didn’t see it, but he’s waiting for the last inserted dictation.
    func testProvenanceIsNotReportedWhenNothingWasInserted() async throws {
        let controller = makeController(recognized: "   ")
        var reported: PipelineProvenance?
        controller.onDictationCompleted = { reported = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertNil(reported)
    }

    func testProvenanceIsNotReportedWhenInsertionFails() async throws {
        let controller = makeController(recognized: "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043C}\u{0438}\u{0440}")
        await inserter.setError(TextInsertionError.secureInputActive)
        var reported: PipelineProvenance?
        controller.onDictationCompleted = { reported = $0 }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.stop()
        await settle()

        XCTAssertNil(reported, "\u{043D}\u{0435}\u{0443}\u{0434}\u{0430}\u{0447}\u{043D}\u{0430}\u{044F} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043A}\u{0430} \u{043D}\u{0435} \u{0434}\u{0430}\u{0451}\u{0442} \u{043F}\u{0440}\u{043E}\u{0438}\u{0441}\u{0445}\u{043E}\u{0436}\u{0434}\u{0435}\u{043D}\u{0438}\u{044F}")
    }
}

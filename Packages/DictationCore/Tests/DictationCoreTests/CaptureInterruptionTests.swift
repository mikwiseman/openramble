import XCTest
@testable import DictationCore

/// A recording that ended on its own.
///
/// The disc ends in the middle of a phrase, and previously this was only known on
/// stop: the man finished speaking for five minutes to nowhere. Now the dictation is up
/// immediately and says the reason.
@MainActor
final class CaptureInterruptionTests: XCTestCase {
    private func makeController(
        capture: FakeCapture,
        overlay: FakeOverlay = FakeOverlay()
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: FakeInserter(),
            overlay: overlay,
            sounds: FakeSounds()
        )
    }

    private func settle(_ iterations: Int = 15) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testInterruptionStopsTheSessionAndExplainsWhy() async throws {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.interrupt(reason: "\u{041A}\u{043E}\u{043D}\u{0447}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} \u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}\u{0435}.")
        await settle()

        XCTAssertEqual(controller.state, .idle, "\u{0414}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043E}\u{0441}\u{0442}\u{0430}\u{043D}\u{043E}\u{0432}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F} \u{043D}\u{0435}\u{043C}\u{0435}\u{0434}\u{043B}\u{0435}\u{043D}\u{043D}\u{043E}")
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.kind, .failure)
        XCTAssertEqual(notices.first?.message, "\u{041A}\u{043E}\u{043D}\u{0447}\u{0438}\u{043B}\u{043E}\u{0441}\u{044C} \u{043C}\u{0435}\u{0441}\u{0442}\u{043E} \u{043D}\u{0430} \u{0434}\u{0438}\u{0441}\u{043A}\u{0435}.")
    }

    func testInterruptionAbortsRecordingInsteadOfFinishingIt() async throws {
        // There is nowhere to append - the file needs to be dropped, not closed.
        let capture = FakeCapture()
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.interrupt(reason: "\u{0441}\u{0431}\u{043E}\u{0439} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}")
        await settle()

        let aborted = await capture.abortCount
        let stopped = await capture.stopCount
        XCTAssertEqual(aborted, 1, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{0431}\u{0440}\u{043E}\u{0441}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F}")
        XCTAssertEqual(stopped, 0, "\u{0418} \u{043D}\u{0435} \u{0444}\u{0438}\u{043D}\u{0430}\u{043B}\u{0438}\u{0437}\u{0438}\u{0440}\u{0443}\u{0435}\u{0442}\u{0441}\u{044F}")
    }

    func testInterruptionNeverInsertsText() async throws {
        let capture = FakeCapture()
        let inserter = FakeInserter()
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.interrupt(reason: "\u{0441}\u{0431}\u{043E}\u{0439} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}")
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "\u{0418}\u{0437} \u{043E}\u{0431}\u{043E}\u{0440}\u{0432}\u{0430}\u{043D}\u{043D}\u{043E}\u{0439} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438} \u{0432}\u{0441}\u{0442}\u{0430}\u{0432}\u{043B}\u{044F}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E}")
    }

    func testInterruptionIsIgnoredWhenNothingIsRecording() async throws {
        // The failure message may arrive late when dictation is already
        // ended. You cannot show an error retroactively.
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.interrupt(reason: "\u{0441}\u{0431}\u{043E}\u{0439} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}")
        await settle(4)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.isEmpty, "\u{041F}\u{0443}\u{0441}\u{0442}\u{0430}\u{044F} \u{0436}\u{0430}\u{043B}\u{043E}\u{0431}\u{0430} \u{043D}\u{0430} \u{0440}\u{043E}\u{0432}\u{043D}\u{043E}\u{043C} \u{043C}\u{0435}\u{0441}\u{0442}\u{0435} \u{043F}\u{043E}\u{043B}\u{044C}\u{0437}\u{043E}\u{0432}\u{0430}\u{0442}\u{0435}\u{043B}\u{044E} \u{043D}\u{0435} \u{043D}\u{0443}\u{0436}\u{043D}\u{0430}")
    }

    func testSessionCanStartAgainAfterInterruption() async throws {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.interrupt(reason: "\u{0441}\u{0431}\u{043E}\u{0439} \u{0437}\u{0430}\u{043F}\u{0438}\u{0441}\u{0438}")
        await settle()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .listening, "\u{041E}\u{0441}\u{0432}\u{043E}\u{0431}\u{043E}\u{0434}\u{0438}\u{043B}\u{0438} \u{043C}\u{0435}\u{0441}\u{0442}\u{043E} — \u{0434}\u{0438}\u{043A}\u{0442}\u{0443}\u{0435}\u{043C} \u{0434}\u{0430}\u{043B}\u{044C}\u{0448}\u{0435}")
    }
}

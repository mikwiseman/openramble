import XCTest
@testable import DictationCore

/// Mode without holding down a key.
///
/// Previously, it was unattainable: a double click came when the session was already in progress,
/// and the attempt to start a new one did not pass the free state check. B
/// the mode was promised in the settings, but it was impossible to enable it.
@MainActor
final class HandsFreeTests: XCTestCase {
    private var capture: FakeCapture!
    private var inserter: FakeInserter!

    override func setUp() async throws {
        capture = FakeCapture()
        inserter = FakeInserter()
    }

    private func makeController() -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )
    }

    private func settle(_ iterations: Int = 12) async {
        for _ in 0..<iterations {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testDoubleTapDuringSessionSwitchesToHandsFree() async throws {
        let controller = makeController()

        // This is how it actually happens: the first click starts the session, and already
        // a double click comes on top of it.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.promoteToHandsFree()

        XCTAssertTrue(controller.isHandsFreeActive, "\u{0420}\u{0435}\u{0436}\u{0438}\u{043C} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0438}\u{0442}\u{044C}\u{0441}\u{044F}")

        // Now releasing the key means nothing - recording continues.
        controller.stop()
        await settle(4)
        XCTAssertEqual(controller.state, .listening, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043E}\u{0431}\u{044F}\u{0437}\u{0430}\u{043D}\u{0430} \u{043F}\u{0440}\u{043E}\u{0434}\u{043E}\u{043B}\u{0436}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043F}\u{043E}\u{0441}\u{043B}\u{0435} \u{043E}\u{0442}\u{043F}\u{0443}\u{0441}\u{043A}\u{0430}\u{043D}\u{0438}\u{044F}")

        controller.stopHandsFree()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "\u{0412}\u{0442}\u{043E}\u{0440}\u{043E}\u{0435} \u{043D}\u{0430}\u{0436}\u{0430}\u{0442}\u{0438}\u{0435} \u{0437}\u{0430}\u{0432}\u{0435}\u{0440}\u{0448}\u{0430}\u{0435}\u{0442} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0443}")
    }

    func testDoubleTapWhilePreparingAlsoWorks() async throws {
        // A quick double tap comes before the microphone goes up.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        controller.promoteToHandsFree()
        await settle()

        XCTAssertTrue(controller.isHandsFreeActive)
        XCTAssertEqual(controller.state, .listening)
    }

    func testPromotionClearsPendingRelease() async throws {
        // The release was related to the previous gesture: in the new mode, the key and
        // is supposed to be released, so it shouldn't break the record.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        controller.stop()
        controller.promoteToHandsFree()
        await settle()

        XCTAssertEqual(controller.state, .listening, "\u{0417}\u{0430}\u{043F}\u{0438}\u{0441}\u{044C} \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{043D}\u{0430} \u{043E}\u{0431}\u{043E}\u{0440}\u{0432}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F}")
        XCTAssertTrue(controller.isHandsFreeActive)
    }

    func testPromotionIsIgnoredWhenNothingIsRunning() {
        let controller = makeController()

        controller.promoteToHandsFree()

        XCTAssertFalse(controller.isHandsFreeActive, "\u{0411}\u{0435}\u{0437} \u{0441}\u{0435}\u{0441}\u{0441}\u{0438}\u{0438} \u{0432}\u{043A}\u{043B}\u{044E}\u{0447}\u{0430}\u{0442}\u{044C} \u{043D}\u{0435}\u{0447}\u{0435}\u{0433}\u{043E}")
    }

    func testModeResetsAfterSessionEnds() async throws {
        let controller = makeController()
        controller.begin(handsFree: true, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertTrue(controller.isHandsFreeActive)

        controller.stopHandsFree()
        await settle()

        XCTAssertFalse(
            controller.isHandsFreeActive,
            "\u{0421}\u{043B}\u{0435}\u{0434}\u{0443}\u{044E}\u{0449}\u{0430}\u{044F} \u{0434}\u{0438}\u{043A}\u{0442}\u{043E}\u{0432}\u{043A}\u{0430} \u{043D}\u{0430}\u{0447}\u{0438}\u{043D}\u{0430}\u{0435}\u{0442}\u{0441}\u{044F} \u{0432} \u{043E}\u{0431}\u{044B}\u{0447}\u{043D}\u{043E}\u{043C} \u{0440}\u{0435}\u{0436}\u{0438}\u{043C}\u{0435}, \u{0430} \u{043D}\u{0435} \u{0432} \u{0443}\u{043D}\u{0430}\u{0441}\u{043B}\u{0435}\u{0434}\u{043E}\u{0432}\u{0430}\u{043D}\u{043D}\u{043E}\u{043C}"
        )
    }
}

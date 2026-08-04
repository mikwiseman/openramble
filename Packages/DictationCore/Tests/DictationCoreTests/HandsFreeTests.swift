import XCTest
@testable import DictationCore

/// Режим без удержания клавиши.
///
/// Раньше он был недостижим: двойное нажатие приходило, когда сессия уже шла,
/// а попытка начать новую не проходила проверку на свободное состояние. В
/// настройках режим был обещан, а включить его было нельзя.
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
            transcribe: { _ in ASRResult(text: "текст", audioDuration: 2, processingDuration: 0.1) },
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

        // Так это происходит на деле: первое нажатие запускает сессию, и уже
        // поверх неё приходит двойное нажатие.
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        XCTAssertEqual(controller.state, .listening)

        controller.promoteToHandsFree()

        XCTAssertTrue(controller.isHandsFreeActive, "Режим должен включиться")

        // Теперь отпускание клавиши ничего не значит — запись продолжается.
        controller.stop()
        await settle(4)
        XCTAssertEqual(controller.state, .listening, "Запись обязана продолжаться после отпускания")

        controller.stopHandsFree()
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertEqual(inserted.count, 1, "Второе нажатие завершает диктовку")
    }

    func testDoubleTapWhilePreparingAlsoWorks() async throws {
        // Быстрое двойное нажатие приходит раньше, чем поднялся микрофон.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)

        controller.promoteToHandsFree()
        await settle()

        XCTAssertTrue(controller.isHandsFreeActive)
        XCTAssertEqual(controller.state, .listening)
    }

    func testPromotionClearsPendingRelease() async throws {
        // Отпускание относилось к прошлому жесту: в новом режиме клавишу и
        // положено отпускать, поэтому оно не должно оборвать запись.
        let controller = makeController()
        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        controller.stop()
        controller.promoteToHandsFree()
        await settle()

        XCTAssertEqual(controller.state, .listening, "Запись не должна оборваться")
        XCTAssertTrue(controller.isHandsFreeActive)
    }

    func testPromotionIsIgnoredWhenNothingIsRunning() {
        let controller = makeController()

        controller.promoteToHandsFree()

        XCTAssertFalse(controller.isHandsFreeActive, "Без сессии включать нечего")
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
            "Следующая диктовка начинается в обычном режиме, а не в унаследованном"
        )
    }
}

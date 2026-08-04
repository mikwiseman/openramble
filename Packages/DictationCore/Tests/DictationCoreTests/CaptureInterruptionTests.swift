import XCTest
@testable import DictationCore

/// Запись, оборвавшаяся сама по себе.
///
/// Диск заканчивается посреди фразы, и раньше об этом узнавали только на
/// остановке: человек договаривал пять минут в никуда. Теперь диктовка встаёт
/// сразу и говорит причину.
@MainActor
final class CaptureInterruptionTests: XCTestCase {
    private func makeController(
        capture: FakeCapture,
        overlay: FakeOverlay = FakeOverlay()
    ) -> DictationController {
        DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "текст", audioDuration: 2, processingDuration: 0.1) },
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

        controller.interrupt(reason: "Кончилось место на диске.")
        await settle()

        XCTAssertEqual(controller.state, .idle, "Диктовка обязана остановиться немедленно")
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.kind, .failure)
        XCTAssertEqual(notices.first?.message, "Кончилось место на диске.")
    }

    func testInterruptionAbortsRecordingInsteadOfFinishingIt() async throws {
        // Дописывать некуда — файл нужно бросить, а не закрывать.
        let capture = FakeCapture()
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.interrupt(reason: "сбой записи")
        await settle()

        let aborted = await capture.abortCount
        let stopped = await capture.stopCount
        XCTAssertEqual(aborted, 1, "Запись бросается")
        XCTAssertEqual(stopped, 0, "И не финализируется")
    }

    func testInterruptionNeverInsertsText() async throws {
        let capture = FakeCapture()
        let inserter = FakeInserter()
        let controller = DictationController(
            capture: capture,
            transcribe: { _ in ASRResult(text: "текст", audioDuration: 2, processingDuration: 0.1) },
            inserter: inserter,
            overlay: FakeOverlay(),
            sounds: FakeSounds()
        )

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.interrupt(reason: "сбой записи")
        await settle()

        let inserted = await inserter.insertedTexts
        XCTAssertTrue(inserted.isEmpty, "Из оборванной записи вставлять нечего")
    }

    func testInterruptionIsIgnoredWhenNothingIsRecording() async throws {
        // Сообщение о сбое может прийти с опозданием, когда диктовка уже
        // закончилась. Показывать ошибку задним числом нельзя.
        let capture = FakeCapture()
        let controller = makeController(capture: capture)
        var notices: [DictationNotice] = []
        controller.onNotice = { notices.append($0) }

        controller.interrupt(reason: "сбой записи")
        await settle(4)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.isEmpty, "Пустая жалоба на ровном месте пользователю не нужна")
    }

    func testSessionCanStartAgainAfterInterruption() async throws {
        let capture = FakeCapture()
        let controller = makeController(capture: capture)

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()
        controller.interrupt(reason: "сбой записи")
        await settle()

        controller.begin(handsFree: false, isEnabled: true, isModelReady: true)
        await settle()

        XCTAssertEqual(controller.state, .listening, "Освободили место — диктуем дальше")
    }
}

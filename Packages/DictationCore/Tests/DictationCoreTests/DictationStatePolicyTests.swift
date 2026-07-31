import XCTest
@testable import DictationCore

/// Эти правила выглядят мелочью, но именно на них ломаются диктовки в проде:
/// потерянное отпускание клавиши оставляет запись включённой, а лишняя
/// финализация вставляет текст дважды.
final class DictationStatePolicyTests: XCTestCase {

    // MARK: - Отпускание клавиши

    func testReleaseDuringPreparingIsRemembered() {
        // Самый частый жест: короткая фраза, клавишу отпустили раньше,
        // чем поднялся звуковой движок. Отпускание нельзя потерять.
        let decision = DictationStopPolicy.decideStop(state: .preparing, isHandsFree: false)

        XCTAssertEqual(decision, .deferUntilListening)
    }

    func testReleaseWhileListeningStopsImmediately() {
        XCTAssertEqual(
            DictationStopPolicy.decideStop(state: .listening, isHandsFree: false),
            .stopNow
        )
    }

    func testHandsFreeIgnoresRelease() {
        // В режиме громкой связи запись останавливают вторым нажатием.
        // Если реагировать на отпускание, диктовка оборвётся сразу после старта.
        for state in [DictationState.preparing, .listening] {
            XCTAssertEqual(
                DictationStopPolicy.decideStop(state: state, isHandsFree: true),
                .ignore,
                "Состояние \(state)"
            )
        }
    }

    func testReleaseDuringFinalizationIsIgnored() {
        // Иначе финализация запустится второй раз и текст вставится дважды.
        for state in [DictationState.transcribing, .inserting] {
            XCTAssertEqual(
                DictationStopPolicy.decideStop(state: state, isHandsFree: false),
                .ignore,
                "Состояние \(state)"
            )
        }
    }

    func testReleaseWithoutSessionDoesNothing() {
        XCTAssertEqual(
            DictationStopPolicy.decideStop(state: .idle, isHandsFree: false),
            .noSession
        )
    }

    // MARK: - Старт

    func testStartRequiresIdleEnabledAndModel() {
        XCTAssertTrue(DictationStopPolicy.canStart(state: .idle, isEnabled: true, isModelReady: true))

        // Занятая сессия — новую поверх не начинаем.
        XCTAssertFalse(DictationStopPolicy.canStart(state: .listening, isEnabled: true, isModelReady: true))
        // Без модели распознавать нечем: лучше не начинать, чем записать и не суметь.
        XCTAssertFalse(DictationStopPolicy.canStart(state: .idle, isEnabled: true, isModelReady: false))
        XCTAssertFalse(DictationStopPolicy.canStart(state: .idle, isEnabled: false, isModelReady: true))
    }

    // MARK: - Отмена

    func testCancelIsPossibleUntilInsertionStarts() {
        XCTAssertTrue(DictationStopPolicy.canCancel(state: .preparing))
        XCTAssertTrue(DictationStopPolicy.canCancel(state: .listening))
        XCTAssertTrue(DictationStopPolicy.canCancel(state: .transcribing))

        // Вставка уже пошла в чужое приложение — отзывать нечего.
        XCTAssertFalse(DictationStopPolicy.canCancel(state: .inserting))
        XCTAssertFalse(DictationStopPolicy.canCancel(state: .idle))
    }

    // MARK: - Продолжение финализации

    func testFinalizationStopsOnCancellation() {
        XCTAssertFalse(
            DictationFinalizationPolicy.shouldContinue(
                state: .transcribing,
                cancellationRequested: true,
                taskCancelled: false
            ),
            "После запроса отмены доводить до вставки нельзя"
        )
        XCTAssertFalse(
            DictationFinalizationPolicy.shouldContinue(
                state: .transcribing,
                cancellationRequested: false,
                taskCancelled: true
            )
        )
    }

    func testFinalizationContinuesInNormalFlow() {
        XCTAssertTrue(
            DictationFinalizationPolicy.shouldContinue(
                state: .transcribing,
                cancellationRequested: false,
                taskCancelled: false
            )
        )
    }

    func testFinalizationRefusesFromWrongState() {
        // Если состояние уже сброшено в idle, значит сессию свернули —
        // вставлять текст поздно.
        for state in [DictationState.idle, .preparing, .listening] {
            XCTAssertFalse(
                DictationFinalizationPolicy.shouldContinue(
                    state: state,
                    cancellationRequested: false,
                    taskCancelled: false
                ),
                "Состояние \(state)"
            )
        }
    }

    // MARK: - Микрофон

    func testMicrophoneIsOnlyLiveWhileListening() {
        // Обещание «индикатор записи гаснет, когда мы не слушаем» держится
        // именно на этом: во всех прочих состояниях движок выключен.
        XCTAssertTrue(DictationState.listening.isCapturing)
        for state in [DictationState.idle, .preparing, .transcribing, .inserting] {
            XCTAssertFalse(state.isCapturing, "Состояние \(state)")
        }
    }

    // MARK: - Предел длительности

    func testRecordingStopsItselfAtOneHour() {
        XCTAssertEqual(DictationDurationPolicy.action(elapsed: 3599), .keepRecording)
        XCTAssertEqual(DictationDurationPolicy.action(elapsed: 3600), .stopAndTranscribe)
        // Важно, что именно останавливаемся и распознаём, а не выбрасываем запись.
        XCTAssertEqual(DictationDurationPolicy.action(elapsed: 4000), .stopAndTranscribe)
    }
}

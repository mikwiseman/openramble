import XCTest
@testable import DictationCore

/// Добор к основным проверкам политик: состояния, до которых обычный сценарий
/// не доходит, но в которые приложение попадает от быстрых нажатий.
final class DictationStateEdgeCaseTests: XCTestCase {

    // MARK: - Занятость

    func testEverySessionStateCountsAsBusy() {
        // На занятости держится защита от второй сессии поверх первой:
        // достаточно забыть одно состояние, чтобы получить две записи разом
        // и два текста, вставленных вперемешку.
        XCTAssertFalse(DictationState.idle.isBusy)
        for state in [DictationState.preparing, .listening, .transcribing, .inserting] {
            XCTAssertTrue(state.isBusy, "Состояние \(state)")
        }
    }

    // MARK: - Старт

    func testStartIsRefusedFromEveryNonIdleState() {
        // Горячая клавиша нажимается быстрее, чем идёт распознавание. Каждое
        // такое нажатие обязано быть отвергнуто, а не начать вторую запись.
        for state in [DictationState.preparing, .listening, .transcribing, .inserting] {
            XCTAssertFalse(
                DictationStopPolicy.canStart(state: state, isEnabled: true, isModelReady: true),
                "Состояние \(state)"
            )
        }
    }

    func testStartNeedsBothPermissionAndModel() {
        // Обе причины отказа независимы, и ни одна не должна перекрывать другую.
        XCTAssertFalse(DictationStopPolicy.canStart(state: .idle, isEnabled: false, isModelReady: false))
        XCTAssertTrue(DictationStopPolicy.canStart(state: .idle, isEnabled: true, isModelReady: true))
    }

    // MARK: - Громкая связь

    func testHandsFreeIgnoresReleaseEvenWithoutASession() {
        // Признак громкой связи проверяется раньше состояния, поэтому отпускание
        // клавиши в режиме громкой связи не значит ничего вообще — включая
        // случай, когда сессии нет.
        for state in [DictationState.idle, .preparing, .listening, .transcribing, .inserting] {
            XCTAssertEqual(
                DictationStopPolicy.decideStop(state: state, isHandsFree: true),
                .ignore,
                "Состояние \(state)"
            )
        }
    }

    // MARK: - Слишком короткая запись

    func testShortPressBoundaryIsExact() {
        // Граница проходит ровно по объявленному минимуму: чуть короче —
        // человек передумал, ровно столько — уже речь.
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: 0))
        XCTAssertFalse(
            DictationDurationPolicy.isWorthTranscribing(duration: DictationDurationPolicy.minimum - 0.01)
        )
        XCTAssertTrue(
            DictationDurationPolicy.isWorthTranscribing(duration: DictationDurationPolicy.minimum)
        )
    }

    func testNegativeDurationIsNotWorthTranscribing() {
        // Отрицательная длительность приходить не должна, но если придёт из-за
        // перевода часов, распознавать по ней нечего.
        XCTAssertFalse(DictationDurationPolicy.isWorthTranscribing(duration: -1))
    }

    // MARK: - Предел длительности

    func testFreshRecordingKeepsGoing() {
        XCTAssertEqual(DictationDurationPolicy.action(elapsed: 0), .keepRecording)
        XCTAssertEqual(
            DictationDurationPolicy.action(elapsed: DictationDurationPolicy.maximum - 0.5),
            .keepRecording
        )
    }

    // MARK: - Продолжение финализации

    func testFinalizationStopsWhenBothCancellationSignalsFire() {
        XCTAssertFalse(
            DictationFinalizationPolicy.shouldContinue(
                state: .inserting,
                cancellationRequested: true,
                taskCancelled: true
            )
        )
    }

    func testFinalizationContinuesWhileInserting() {
        // Вставка — последнее состояние, из которого доведение до конца ещё
        // осмысленно: текст уже готов и ждёт отправки в чужое приложение.
        XCTAssertTrue(
            DictationFinalizationPolicy.shouldContinue(
                state: .inserting,
                cancellationRequested: false,
                taskCancelled: false
            )
        )
    }
}

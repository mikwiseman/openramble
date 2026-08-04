import LocalASR
import XCTest

/// Онбординг — единственный путь нового человека к работающему продукту.
///
/// Проверяется не «переключился ли шаг», а то, что человек на этом шаге увидит:
/// пустит ли его кнопка дальше и сказано ли ему, чего не хватает.
final class OnboardingStepTests: XCTestCase {
    private let ready = ModelState.ready(directory: URL(fileURLWithPath: "/tmp/model"))

    private func reason(
        _ step: OnboardingStep,
        microphone: Bool = true,
        accessibility: Bool = true,
        model: ModelState? = nil,
        engineReady: Bool = true,
        trialSucceeded: Bool = true
    ) -> String? {
        OnboardingGate.blockReason(
            step: step,
            microphoneGranted: microphone,
            accessibilityGranted: accessibility,
            modelState: model ?? ready,
            engineReady: engineReady,
            trialSucceeded: trialSucceeded
        )
    }

    // MARK: - Шаги

    func testШаговЧетыреИОниИдутПоПорядку() {
        XCTAssertEqual(OnboardingStep.allCases.count, 4)
        XCTAssertEqual(OnboardingStep.welcome.next, .permissions)
        XCTAssertEqual(OnboardingStep.permissions.next, .model)
        XCTAssertEqual(OnboardingStep.model.next, .tryIt)
        XCTAssertNil(OnboardingStep.tryIt.next)
    }

    /// Кнопки «Назад» на первом шаге нет вовсе.
    ///
    /// Погашенная кнопка выглядит как поломка, а нажатие на неё вело бы в никуда.
    func testСПервогоШагаНазадНекуда() {
        XCTAssertFalse(OnboardingStep.welcome.hasPrevious)
        XCTAssertNil(OnboardingStep.welcome.previous)

        XCTAssertTrue(OnboardingStep.permissions.hasPrevious)
        XCTAssertEqual(OnboardingStep.permissions.previous, .welcome)
        XCTAssertEqual(OnboardingStep.tryIt.previous, .model)
    }

    func testПоследнийШагЗакрываетНастройку() {
        XCTAssertEqual(OnboardingStep.welcome.nextButtonTitle, "Дальше")
        XCTAssertEqual(OnboardingStep.model.nextButtonTitle, "Дальше")
        XCTAssertEqual(OnboardingStep.tryIt.nextButtonTitle, "Готово")
    }

    func testСчётчикШаговЧитаетсяСловами() {
        XCTAssertEqual(OnboardingStep.welcome.progressText, "1 из 4")
        XCTAssertEqual(OnboardingStep.tryIt.progressText, "4 из 4")
        // «1 из 4» без слова «шаг» VoiceOver читает как пару чисел ниоткуда.
        XCTAssertEqual(OnboardingStep.welcome.progressAccessibilityLabel, "Шаг 1 из 4")
        XCTAssertEqual(OnboardingStep.tryIt.progressAccessibilityLabel, "Шаг 4 из 4")
    }

    // MARK: - Кто пускает дальше

    func testПриветствиеПускаетДальшеВсегда() {
        XCTAssertNil(reason(.welcome, microphone: false, accessibility: false, model: .notInstalled))
    }

    func testПробаТребуетПервойУспешнойДиктовки() {
        XCTAssertEqual(
            reason(.tryIt, trialSucceeded: false),
            "Сначала попробуйте диктовку или нажмите «Пропустить пробу»."
        )
        XCTAssertNil(reason(.tryIt, trialSucceeded: true))
    }

    // MARK: - Разрешения

    func testБезОбоихРазрешенийСказаноПроОба() {
        let text = reason(.permissions, microphone: false, accessibility: false)
        XCTAssertEqual(text, "Осталось выдать оба разрешения — микрофон и универсальный доступ.")
    }

    func testБезМикрофонаСказаноПроМикрофон() {
        XCTAssertEqual(reason(.permissions, microphone: false, accessibility: true), "Остался микрофон.")
    }

    func testБезУниверсальногоДоступаСказаноПроНего() {
        XCTAssertEqual(
            reason(.permissions, microphone: true, accessibility: false),
            "Остался универсальный доступ."
        )
    }

    func testСОбоимиРазрешениямиШагПускаетДальше() {
        XCTAssertNil(reason(.permissions, microphone: true, accessibility: true))
        XCTAssertTrue(
            OnboardingGate.canAdvance(
                step: .permissions,
                microphoneGranted: true,
                accessibilityGranted: true,
                modelState: .notInstalled
            )
        )
    }

    // MARK: - Модель

    func testКаждоеСостояниеМоделиОбъясняетСебя() {
        XCTAssertEqual(
            reason(.model, model: .notInstalled),
            "Сначала скачайте модель — без неё распознавать нечем."
        )
        XCTAssertEqual(
            reason(.model, model: .downloading(receivedBytes: 1, totalBytes: 2)),
            "Дождитесь конца загрузки."
        )
        XCTAssertEqual(
            reason(.model, model: .verifying(checked: 1, total: 12)),
            "Идёт проверка скачанного."
        )
        XCTAssertEqual(
            reason(.model, model: .failed(.download("нет сети"))),
            "Загрузка не удалась. Попробуйте ещё раз."
        )
        XCTAssertEqual(reason(.model, model: .deleting), "Модель удаляется.")
    }

    func testГотоваяМодельПускаетДальше() {
        XCTAssertNil(reason(.model, model: ready))
    }

    func testГотовыйInventoryНеПускаетДоЗавершенияWarmup() {
        XCTAssertEqual(
            reason(.model, model: ready, engineReady: false),
            "Дождитесь подготовки модели к первому запуску."
        )
    }

    /// Ни на одном шаге погашенная кнопка не остаётся без объяснения.
    ///
    /// Именно это и есть тупик установки: человек видит мёртвую «Дальше» и не
    /// знает, чего от него хотят, — а незрячий не видит и её.
    func testПогашеннаяКнопкаВсегдаОбъясняетПричину() {
        let states: [ModelState] = [
            .notInstalled,
            .downloading(receivedBytes: 0, totalBytes: 1),
            .verifying(checked: 0, total: 1),
            .repairRequired("повреждена"),
            .failed(.cancelled),
            .deleting,
            ready,
        ]

        for step in OnboardingStep.allCases {
            for microphone in [true, false] {
                for accessibility in [true, false] {
                    for model in states {
                        let blocked = !OnboardingGate.canAdvance(
                            step: step,
                            microphoneGranted: microphone,
                            accessibilityGranted: accessibility,
                            modelState: model
                        )
                        let text = OnboardingGate.blockReason(
                            step: step,
                            microphoneGranted: microphone,
                            accessibilityGranted: accessibility,
                            modelState: model
                        )
                        XCTAssertEqual(
                            blocked,
                            text?.isEmpty == false,
                            "шаг \(step) обязан объяснить, почему не пускает"
                        )
                    }
                }
            }
        }
    }
}

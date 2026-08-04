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
        XCTAssertEqual(OnboardingStep.welcome.nextButtonTitle, "Continue")
        XCTAssertEqual(OnboardingStep.model.nextButtonTitle, "Continue")
        XCTAssertEqual(OnboardingStep.tryIt.nextButtonTitle, "Done")
    }

    func testСчётчикШаговЧитаетсяСловами() {
        XCTAssertEqual(OnboardingStep.welcome.progressText, "1 of 4")
        XCTAssertEqual(OnboardingStep.tryIt.progressText, "4 of 4")
        // «1 из 4» без слова «шаг» VoiceOver читает как пару чисел ниоткуда.
        XCTAssertEqual(OnboardingStep.welcome.progressAccessibilityLabel, "Step 1 of 4")
        XCTAssertEqual(OnboardingStep.tryIt.progressAccessibilityLabel, "Step 4 of 4")
    }

    // MARK: - Кто пускает дальше

    func testПриветствиеПускаетДальшеВсегда() {
        XCTAssertNil(reason(.welcome, microphone: false, accessibility: false, model: .notInstalled))
    }

    func testПробаТребуетПервойУспешнойДиктовки() {
        XCTAssertEqual(
            reason(.tryIt, trialSucceeded: false),
            "Try dictation first, or press “Skip the try-out”."
        )
        XCTAssertNil(reason(.tryIt, trialSucceeded: true))
    }

    // MARK: - Разрешения

    func testБезОбоихРазрешенийСказаноПроОба() {
        let text = reason(.permissions, microphone: false, accessibility: false)
        XCTAssertEqual(text, "Two permissions left to grant — Microphone and Accessibility.")
    }

    func testБезМикрофонаСказаноПроМикрофон() {
        XCTAssertEqual(reason(.permissions, microphone: false, accessibility: true), "Microphone is still needed.")
    }

    func testБезУниверсальногоДоступаСказаноПроНего() {
        XCTAssertEqual(
            reason(.permissions, microphone: true, accessibility: false),
            "Accessibility is still needed."
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
            "Download the model first — without it there is nothing to recognize with."
        )
        XCTAssertEqual(
            reason(.model, model: .downloading(receivedBytes: 1, totalBytes: 2)),
            "Wait for the download to finish."
        )
        XCTAssertEqual(
            reason(.model, model: .verifying(checked: 1, total: 12)),
            "The download is being verified."
        )
        XCTAssertEqual(
            reason(.model, model: .failed(.download("no network"))),
            "The download failed. Try again."
        )
        XCTAssertEqual(reason(.model, model: .deleting), "The model is being deleted.")
    }

    func testГотоваяМодельПускаетДальше() {
        XCTAssertNil(reason(.model, model: ready))
    }

    func testГотовыйInventoryНеПускаетДоЗавершенияWarmup() {
        XCTAssertEqual(
            reason(.model, model: ready, engineReady: false),
            "Wait for the model to finish preparing for first use."
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

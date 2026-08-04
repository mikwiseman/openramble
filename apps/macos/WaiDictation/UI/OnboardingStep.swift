import LocalASR

/// Шаги первого запуска и правила перехода между ними.
///
/// Отдельным типом, а не полем внутри вью: здесь решается, дойдёт ли новый
/// пользователь до работающего продукта или упрётся в погашенную кнопку.
/// Проверять это надо таблицей, а не глазами на живом экране — экрана в
/// проверке может не быть вовсе.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case permissions
    case model
    case tryIt

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// Есть ли куда возвращаться.
    ///
    /// На первом шаге кнопки «Назад» нет: она вела бы в никуда, а погашенная
    /// кнопка выглядит как поломка.
    var hasPrevious: Bool { previous != nil }

    var isLast: Bool { next == nil }

    /// Подпись кнопки перехода.
    var nextButtonTitle: String { isLast ? "Done" : "Continue" }

    var progressText: String { "\(rawValue + 1) of \(Self.allCases.count)" }

    /// То же самое словами.
    ///
    /// «1 из 4» без слова «шаг» VoiceOver читает как пару чисел ниоткуда.
    var progressAccessibilityLabel: String {
        "Step \(rawValue + 1) of \(Self.allCases.count)"
    }
}

/// Пускает ли шаг дальше и, если нет, почему.
///
/// Причина — не украшение. Погашенная кнопка без объяснения оставляет человека
/// гадать, чего от него хотят; для незрячего она просто «недоступная кнопка
/// Дальше», и на этом установка заканчивается.
enum OnboardingGate {
    /// `nil` — можно идти дальше.
    static func blockReason(
        step: OnboardingStep,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        modelState: ModelState,
        engineReady: Bool = true,
        trialSucceeded: Bool = true
    ) -> String? {
        switch step {
        case .welcome:
            return nil

        case .tryIt:
            return trialSucceeded
                ? nil
                : "Try dictation first, or press “Skip the try-out”."

        case .permissions:
            // Дальше пускаем только когда оба разрешения выданы: следующий шаг
            // без них ничего не покажет, а человек решит, что всё сломано.
            switch (microphoneGranted, accessibilityGranted) {
            case (true, true): return nil
            case (false, false): return "Two permissions left to grant — Microphone and Accessibility."
            case (false, true): return "Microphone is still needed."
            case (true, false): return "Accessibility is still needed."
            }

        case .model:
            switch modelState {
            case .ready: return engineReady ? nil : "Wait for the model to finish preparing for first use."
            case .notInstalled: return "Download the model first — without it there is nothing to recognize with."
            case .downloading: return "Wait for the download to finish."
            case .verifying: return "The download is being verified."
            case .repairRequired: return "The model is damaged. Redownload it explicitly."
            case .failed: return "The download failed. Try again."
            case .deleting: return "The model is being deleted."
            }
        }
    }

    static func canAdvance(
        step: OnboardingStep,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        modelState: ModelState,
        engineReady: Bool = true,
        trialSucceeded: Bool = true
    ) -> Bool {
        blockReason(
            step: step,
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            modelState: modelState,
            engineReady: engineReady,
            trialSucceeded: trialSucceeded
        ) == nil
    }
}

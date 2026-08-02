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
    var nextButtonTitle: String { isLast ? "Готово" : "Дальше" }

    var progressText: String { "\(rawValue + 1) из \(Self.allCases.count)" }

    /// То же самое словами.
    ///
    /// «1 из 4» без слова «шаг» VoiceOver читает как пару чисел ниоткуда.
    var progressAccessibilityLabel: String {
        "Шаг \(rawValue + 1) из \(Self.allCases.count)"
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
        modelState: ModelState
    ) -> String? {
        switch step {
        case .welcome, .tryIt:
            return nil

        case .permissions:
            // Дальше пускаем только когда оба разрешения выданы: следующий шаг
            // без них ничего не покажет, а человек решит, что всё сломано.
            switch (microphoneGranted, accessibilityGranted) {
            case (true, true): return nil
            case (false, false): return "Осталось выдать оба разрешения — микрофон и универсальный доступ."
            case (false, true): return "Остался микрофон."
            case (true, false): return "Остался универсальный доступ."
            }

        case .model:
            switch modelState {
            case .ready: return nil
            case .notInstalled: return "Сначала скачайте модель — без неё распознавать нечем."
            case .downloading: return "Дождитесь конца загрузки."
            case .verifying: return "Идёт проверка скачанного."
            case .failed: return "Загрузка не удалась. Попробуйте ещё раз."
            case .deleting: return "Модель удаляется."
            }
        }
    }

    static func canAdvance(
        step: OnboardingStep,
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        modelState: ModelState
    ) -> Bool {
        blockReason(
            step: step,
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            modelState: modelState
        ) == nil
    }
}

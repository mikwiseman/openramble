/// Строка разрешения — то же самое в онбординге и в настройках.
///
/// Обе кнопки на экране называются «Выдать», и на слух они неразличимы: без
/// имени разрешения незрячий человек слышит две одинаковые кнопки и не знает,
/// какая из них какая.
struct PermissionStatus: Equatable {
    let title: String
    let detail: String
    let granted: Bool
    private let explicitValue: String?
    private let explicitActionTitle: String?

    init(title: String, detail: String, granted: Bool) {
        self.title = title
        self.detail = detail
        self.granted = granted
        explicitValue = nil
        explicitActionTitle = granted ? nil : "Выдать"
    }

    private init(
        title: String,
        detail: String,
        granted: Bool,
        value: String,
        actionTitle: String?
    ) {
        self.title = title
        self.detail = detail
        self.granted = granted
        explicitValue = value
        explicitActionTitle = actionTitle
    }

    static func accessibility(
        state: AccessibilityPermissionState,
        detail: String
    ) -> PermissionStatus {
        switch state {
        case .denied:
            return .init(
                title: "Универсальный доступ",
                detail: detail,
                granted: false,
                value: "Разрешение не выдано",
                actionTitle: "Выдать"
            )
        case .waitingForSettings:
            return .init(
                title: "Универсальный доступ",
                detail: "Включите Wai Dictation в открытых Системных настройках и вернитесь сюда.",
                granted: false,
                value: "Ожидаем разрешение в Системных настройках",
                actionTitle: "Открыть настройки"
            )
        case .restartRequired:
            return .init(
                title: "Универсальный доступ",
                detail: "Если Wai Dictation уже включён, перезапустите приложение, чтобы macOS применила доступ к новому процессу.",
                granted: false,
                value: "Требуется перезапуск приложения",
                actionTitle: "Перезапустить"
            )
        case .repairRequired:
            return .init(
                title: "Универсальный доступ",
                detail: "macOS хранит старую или дублирующую запись Wai Dictation. Удалите только её и выдайте доступ заново.",
                granted: false,
                value: "Нужно восстановить системную запись разрешения",
                actionTitle: "Исправить"
            )
        case .repairing:
            return .init(
                title: "Универсальный доступ",
                detail: "Удаляем старую запись и перезапускаем Wai Dictation.",
                granted: false,
                value: "Восстанавливаем разрешение",
                actionTitle: nil
            )
        case let .failed(message):
            return .init(
                title: "Универсальный доступ",
                detail: "Восстановление не удалось: \(message)",
                granted: false,
                value: "Ошибка восстановления разрешения",
                actionTitle: "Исправить"
            )
        case .granted:
            return .init(
                title: "Универсальный доступ",
                detail: detail,
                granted: true,
                value: "Разрешение выдано",
                actionTitle: nil
            )
        }
    }

    /// Название и пояснение — про одно и то же, и читаются вместе.
    var accessibilityLabel: String { "\(title). \(detail)" }

    /// Галочка словами: картинка сама по себе VoiceOver ничего не говорит.
    var accessibilityValue: String {
        explicitValue ?? (granted ? "Разрешение выдано" : "Разрешение не выдано")
    }

    /// Кнопка есть только там, где ещё есть что выдавать.
    var actionTitle: String? { explicitActionTitle }

    var actionAccessibilityLabel: String? {
        actionTitle.map { action in
            action == "Выдать" ? "Выдать разрешение: \(title)" : "\(action): \(title)"
        }
    }
}

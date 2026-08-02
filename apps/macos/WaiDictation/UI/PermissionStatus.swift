/// Строка разрешения — то же самое в онбординге и в настройках.
///
/// Обе кнопки на экране называются «Выдать», и на слух они неразличимы: без
/// имени разрешения незрячий человек слышит две одинаковые кнопки и не знает,
/// какая из них какая.
struct PermissionStatus: Equatable {
    let title: String
    let detail: String
    let granted: Bool

    /// Название и пояснение — про одно и то же, и читаются вместе.
    var accessibilityLabel: String { "\(title). \(detail)" }

    /// Галочка словами: картинка сама по себе VoiceOver ничего не говорит.
    var accessibilityValue: String {
        granted ? "Разрешение выдано" : "Разрешение не выдано"
    }

    /// Кнопка есть только там, где ещё есть что выдавать.
    var actionTitle: String? { granted ? nil : "Выдать" }

    var actionAccessibilityLabel: String? {
        granted ? nil : "Выдать разрешение: \(title)"
    }
}

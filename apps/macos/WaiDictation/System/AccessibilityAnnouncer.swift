import AppKit

/// Кто говорит вслух то, что нарисовано на экране.
///
/// За протоколом — потому что настоящее объявление уходит в VoiceOver, а его в
/// проверке нет. Без подмены нельзя проверить ни одного объявления, а именно
/// они и есть весь интерфейс приложения для незрячего человека.
@MainActor
public protocol AccessibilityAnnouncing: AnyObject {
    /// Сказать вслух. `urgent` — перебить то, что читается сейчас.
    func announce(_ message: String, urgent: Bool)
}

@MainActor
public final class SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    public init() {}

    public func announce(_ message: String, urgent: Bool) {
        // Объявление адресуется приложению, а не панели диктовки. Панель
        // намеренно не забирает фокус — иначе сломалась бы вставка текста, —
        // а объявление от элемента вне цепочки фокуса VoiceOver пропускает.
        let priority = urgent
            ? NSAccessibilityPriorityLevel.high
            : NSAccessibilityPriorityLevel.medium

        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }
}

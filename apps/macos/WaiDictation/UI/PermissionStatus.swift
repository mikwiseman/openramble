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
        explicitActionTitle = granted ? nil : "Grant"
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
                title: "Accessibility",
                detail: detail,
                granted: false,
                value: "Permission not granted",
                actionTitle: "Grant"
            )
        case .waitingForSettings:
            return .init(
                title: "Accessibility",
                detail: "Turn on Wai Dictation in the System Settings window that just opened, then come back here.",
                granted: false,
                value: "Waiting for permission in System Settings",
                actionTitle: "Open System Settings"
            )
        case .restartRequired:
            return .init(
                title: "Accessibility",
                detail: "If Wai Dictation is already turned on, relaunch the app so macOS applies the access to the new process.",
                granted: false,
                value: "App relaunch required",
                actionTitle: "Relaunch"
            )
        case .repairRequired:
            return .init(
                title: "Accessibility",
                detail: "macOS keeps an old or duplicate entry for Wai Dictation. Remove just that entry and grant access again.",
                granted: false,
                value: "The system permission entry needs repair",
                actionTitle: "Repair"
            )
        case .repairing:
            return .init(
                title: "Accessibility",
                detail: "Removing the old entry and relaunching Wai Dictation.",
                granted: false,
                value: "Repairing the permission",
                actionTitle: nil
            )
        case let .failed(message):
            return .init(
                title: "Accessibility",
                detail: "Repair failed: \(message)",
                granted: false,
                value: "Permission repair failed",
                actionTitle: "Repair"
            )
        case .granted:
            return .init(
                title: "Accessibility",
                detail: detail,
                granted: true,
                value: "Permission granted",
                actionTitle: nil
            )
        }
    }

    /// Название и пояснение — про одно и то же, и читаются вместе.
    var accessibilityLabel: String { "\(title). \(detail)" }

    /// Галочка словами: картинка сама по себе VoiceOver ничего не говорит.
    var accessibilityValue: String {
        explicitValue ?? (granted ? "Permission granted" : "Permission not granted")
    }

    /// Кнопка есть только там, где ещё есть что выдавать.
    var actionTitle: String? { explicitActionTitle }

    var actionAccessibilityLabel: String? {
        actionTitle.map { action in
            action == "Grant" ? "Grant access: \(title)" : "\(action): \(title)"
        }
    }
}

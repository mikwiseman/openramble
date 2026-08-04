import Foundation

/// Что система делает по нажатию 🌐 (Fn).
///
/// Значение живёт в глобальных настройках macOS под ключом `AppleFnUsageType`
/// («Системные настройки → Клавиатура → Нажатие клавиши 🌐»).
enum FnKeyUsage: Sendable, Equatable {
    /// Ключа нет — человек настройку не трогал, поведение задаёт система.
    case systemDefault
    case doNothing
    case changeInputSource
    case showEmoji
    case startDictation
    case unknown(Int)

    init(rawValue: Int?) {
        switch rawValue {
        case nil: self = .systemDefault
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .showEmoji
        case 3: self = .startDictation
        case let .some(other): self = .unknown(other)
        }
    }

    /// Забирает ли система нажатие себе.
    var isTakenBySystem: Bool {
        switch self {
        case .doNothing: return false
        // Незнакомое значение считаем занятым: помолчать здесь дороже, чем
        // предупредить лишний раз.
        case .systemDefault, .changeInputSource, .showEmoji, .startDictation, .unknown:
            return true
        }
    }

    var systemAction: String? {
        switch self {
        case .doNothing: return nil
        case .systemDefault: return nil
        case .changeInputSource: return "input source switching"
        case .showEmoji: return "the emoji panel"
        case .startDictation: return "Apple's built-in dictation"
        case .unknown: return "a system action"
        }
    }
}

/// Предупреждения о выбранной горячей клавише.
enum HotkeyAdvice {
    /// Что не так с выбором. `nil` — всё в порядке.
    ///
    /// Предупреждение, а не запрет: Fn как горячая клавиша работает, если её
    /// системное действие выключено, и кому-то она удобнее всего. По умолчанию
    /// у нас правый Command, так что сюда попадают только те, кто выбрал Fn сам.
    static func warning(for hotkey: DictationHotkey, fnUsage: FnKeyUsage) -> String? {
        guard hotkey == .fn else { return nil }

        let external = "On an external keyboard without a 🌐 key, dictation won't start at all."

        guard fnUsage.isTakenBySystem else { return external }

        if let action = fnUsage.systemAction {
            return """
                Pressing 🌐 already triggers \(action) — dictation and that \
                action will fire together. To change this: System Settings → \
                Keyboard → “Press 🌐 key”. \(external)
                """
        }

        return """
            Make sure pressing 🌐 is not assigned to anything in the system: \
            System Settings → Keyboard → “Press 🌐 key”. Otherwise dictation \
            will fire together with the system action. \(external)
            """
    }
}

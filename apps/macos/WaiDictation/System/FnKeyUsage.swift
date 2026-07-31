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
        case .changeInputSource: return "сменой раскладки"
        case .showEmoji: return "панелью эмодзи"
        case .startDictation: return "встроенной диктовкой Apple"
        case .unknown: return "своим действием"
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

        let external = "На внешней клавиатуре без клавиши 🌐 диктовка не запустится вовсе."

        guard fnUsage.isTakenBySystem else { return external }

        if let action = fnUsage.systemAction {
            return """
                Нажатие 🌐 занято в системе \(action) — диктовка и это действие \
                будут срабатывать вместе. Поменять: Системные настройки → \
                Клавиатура → Нажатие клавиши 🌐. \(external)
                """
        }

        return """
            Проверьте, что нажатие 🌐 в системе ни на что не назначено: \
            Системные настройки → Клавиатура → Нажатие клавиши 🌐. Иначе \
            диктовка будет срабатывать вместе с системным действием. \(external)
            """
    }
}

import Foundation

/// What the system does when you press 🌐 (Fn).
///
/// The value lives in the macOS global settings under the `AppleFnUsageType` key
/// (“System Settings → Keyboard → Keystroke 🌐”).
enum FnKeyUsage: Sendable, Equatable {
    /// There is no key - the person did not touch the setting, the behavior is set by the system.
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

    /// Whether the system takes the click for itself.
    var isTakenBySystem: Bool {
        switch self {
        case .doNothing: return false
        // We consider the unfamiliar value to be busy: staying silent here is more expensive than
        // warn again.
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

/// Warnings about the selected hotkey.
enum HotkeyAdvice {
    /// What's wrong with the choice. `nil` - everything is fine.
    ///
    /// A warning, not a ban: Fn works as a hotkey if it
    /// system action is turned off, and for some it is most convenient. Default
    /// we have the right Command, so only those who chose Fn themselves get here.
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

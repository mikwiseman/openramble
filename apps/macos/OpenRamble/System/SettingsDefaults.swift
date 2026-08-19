import Foundation

/// What every setting is before anyone touches it.
///
/// One place rather than a literal at each reading site: the revert arrow in
/// Settings and the value the app starts with have to agree, and they can only
/// be relied on to agree if they are the same constant. A default that drifts
/// between "what you get" and "what revert gives you" is worse than none —
/// the arrow would quietly move the setting somewhere the person never chose.
public enum SettingsDefaults {
    public static let hotkey: DictationHotkey = .rightCommand
    public static let copyShortcut: KeyCombination? = nil
    public static let soundsEnabled = true
    public static let copiesToClipboard = false
    public static let appendsTrailingSpace = false
    public static let launchAtLogin = false
    public static let overlayPlacement: DictationOverlayPlacement = .top
    public static let appearance: AppAppearance = .system
}

/// Which look the app takes, regardless of the rest of the system.
///
/// `system` is the default and the honest one — an app that follows the
/// machine needs no setting at all. The other two exist because a person who
/// keeps their Mac light and this window dark is not doing anything strange.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: Self { self }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

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
    public static let presence: AppPresence = .menuBar
    public static let detailedLogging = false
    public static let stopsOnSilence = false
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


/// Where the app lives on screen.
///
/// There is deliberately no "nowhere". An app you cannot see is an app you
/// cannot open to make visible again — the setting would be a door that locks
/// behind you. So this chooses *where* OpenRamble appears, never whether.
public enum AppPresence: String, CaseIterable, Identifiable, Sendable {
    /// The menu bar only, which is what a dictation utility wants.
    case menuBar
    /// The Dock only, for people who keep a clean menu bar.
    case dock
    /// Both.
    case both

    public var id: Self { self }

    public var title: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .both: return "Menu bar and Dock"
        }
    }

    public var showsMenuBarIcon: Bool { self != .dock }
    public var showsDockIcon: Bool { self != .menuBar }
}

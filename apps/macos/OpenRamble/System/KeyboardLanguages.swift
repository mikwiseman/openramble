import Carbon
import Foundation

/// The languages of this Mac's keyboards: the one in use, and every one it
/// can switch to.
///
/// Dictation follows the keyboard, as the Mac's own dictation does, so this is
/// how the app knows a take is in Hebrew; see `HebrewModelRule`. Only the
/// language codes are read, never what is typed.
public struct KeyboardLanguages: Equatable, Sendable {
    /// The language of the keyboard in use, such as "en" or "he".
    public var current: String?
    /// The languages of the keyboards enabled in System Settings.
    public var enabled: [String]

    public init(current: String?, enabled: [String]) {
        self.current = current
        self.enabled = enabled
    }

    /// Posted to the distributed notification center when the person switches
    /// keyboards, and when they add or remove one.
    public static let changes: [Notification.Name] = [
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
    ]

    /// What the Mac says now. Text Input Sources answer on the main thread.
    @MainActor
    public static func system() -> KeyboardLanguages {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        return KeyboardLanguages(
            current: current.flatMap(language),
            enabled: sources.compactMap(language)
        )
    }

    /// A keyboard's first language is the one it is for.
    private static func language(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first
    }
}

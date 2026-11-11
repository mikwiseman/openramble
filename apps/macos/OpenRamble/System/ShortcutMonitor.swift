import AppKit

/// Watches the whole machine for one shortcut.
///
/// The one real implementation is `CarbonShortcutMonitor`, a hot key the
/// window server delivers. An earlier one listened to every key press and
/// compared: it could not hear anything while typing was protected, and the
/// app in front received the chord as well, so ⌃⌘R started a recording and
/// ran the project in Xcode in the same press.
@MainActor
public protocol ShortcutMonitoring: AnyObject {
    var onPress: (() -> Void)? { get set }
    var isRunning: Bool { get }

    /// `nil` takes the shortcut off the keyboard entirely.
    func setShortcut(_ shortcut: KeyCombination?)
    func start()
    func stop()
}

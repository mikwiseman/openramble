import AppKit
import Carbon.HIToolbox
import IOKit

/// Whether typing is protected right now, and by whom.
///
/// macOS calls it secure input: a password field, or a terminal with Secure
/// Keyboard Entry on. It keeps other apps from watching the keyboard. It does
/// not keep them from posting a paste: on macOS 27 a posted ⌘V lands while it
/// is on, so the app always tries, and this is consulted only after a paste
/// nobody read. It is one system-wide state: an app in the background can
/// hold it over the app in front, long after its password was typed.
public struct TypingProtection: Equatable, Sendable {
    public var isOn: Bool
    /// The app that most likely holds it, for "Didn't paste while Terminal
    /// protects typing." A best guess, and `nil` whenever it is not known.
    public var holder: String?

    public init(isOn: Bool, holder: String? = nil) {
        self.isOn = isOn
        self.holder = holder
    }

    public static let off = TypingProtection(isOn: false)

    /// The live reading.
    @MainActor
    public static func current() -> TypingProtection {
        guard IsSecureEventInputEnabled() else { return .off }
        return TypingProtection(isOn: true, holder: holderName())
    }

    /// The window server records the process that enabled secure input in the
    /// console session's entry of the I/O registry. Reading it asks nothing of
    /// any other app and needs no permission.
    @MainActor
    private static func holderName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return nil }

        for user in users {
            guard let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid),
                  // The login window holds it while the screen is locked. Its
                  // name would explain nothing.
                  app.bundleIdentifier != "com.apple.loginwindow",
                  let name = app.localizedName, !name.isEmpty
            else { continue }
            return name
        }
        return nil
    }
}

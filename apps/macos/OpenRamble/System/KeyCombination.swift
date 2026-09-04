import AppKit
import Carbon.HIToolbox

/// A shortcut in the ordinary Mac sense: a key, with modifiers held down.
///
/// Separate from `DictationHotkey`, which is deliberately a *bare* modifier
/// you hold. The two do different jobs and the difference is not cosmetic:
/// hold-to-talk needs a key that can be held for a sentence without typing
/// anything, so it can only be a modifier. Copying is a press, and a press
/// wants a chord — binding it to a bare Control would fire every time the
/// person reached for Control on the way to something else.
public struct KeyCombination: Sendable, Equatable, Hashable {
    public let keyCode: UInt16
    /// Only the four modifiers a shortcut is built from, stored raw so the
    /// value is trivially Codable.
    ///
    /// Deliberately not the event's whole mask: arrow keys and the function
    /// row raise `.function` on their own, Caps Lock raises its bit whenever
    /// it happens to be on, and a shortcut recorded through either would then
    /// never match again.
    public let modifiers: UInt

    /// Everything a shortcut may be built from, and nothing else.
    public static let allowedModifiers: NSEvent.ModifierFlags =
        [.command, .control, .option, .shift]

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers).rawValue
    }

    /// The default recording shortcut: rare enough to ship on, unlike ⌘R.
    public static let shiftCommandR = KeyCombination(
        keyCode: UInt16(kVK_ANSI_R),
        modifiers: [.command, .shift]
    )

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    // MARK: - What may be bound

    /// The function row stands alone; everything else needs a modifier.
    ///
    /// A bare letter would fire in the middle of a word, and Shift with a
    /// letter is just a capital letter — both would make the app type into
    /// someone's document by accident. F13 pressed by itself types nothing,
    /// which is exactly why people reach for it.
    public var isValid: Bool {
        if Self.functionKeyCodes.contains(keyCode) { return true }
        return !modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    /// Whether this combination is what the person just pressed.
    ///
    /// Compares the modifier set exactly rather than "contains": ⌘C must not
    /// answer to ⇧⌘C, which in most applications means something else.
    public func matches(keyCode: UInt16, rawFlags: UInt) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let pressed = NSEvent.ModifierFlags(rawValue: rawFlags)
            .intersection(Self.allowedModifiers)
        return pressed == modifierFlags
    }

    // MARK: - How it reads

    /// The shortcut as a Mac shows it: `⌥⌘C`.
    ///
    /// Modifier order is Apple's own — Control, Option, Shift, Command — so
    /// this reads the same way as every menu on the machine.
    public var displayString: String {
        var text = ""
        if modifierFlags.contains(.control) { text += "⌃" }
        if modifierFlags.contains(.option) { text += "⌥" }
        if modifierFlags.contains(.shift) { text += "⇧" }
        if modifierFlags.contains(.command) { text += "⌘" }
        return text + Self.keyLabel(for: keyCode)
    }

    /// Keys whose names are words or arrows rather than the character they type.
    private static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_ANSI_KeypadEnter): "⌤",
        UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_Help): "?⃝",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static let functionKeyCodes: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
        UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16),
        UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20),
    ]

    /// What is printed on the key the person pressed.
    ///
    /// Asked of the keyboard layout rather than remembered from the moment of
    /// recording: a shortcut recorded on one layout must still name a real key
    /// after switching to another. The ASCII-capable layout is the one used,
    /// which is why a Mac menu shows `⌘Q` while you are typing in Russian —
    /// the shortcut lives on the physical key, not on the letter.
    static func keyLabel(for keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] { return named }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return "Key \(keyCode)"
        }
        let layout = unsafeBitCast(data, to: CFData.self) as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,  // no modifiers: the label is the key's own character
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

// MARK: - Storage

/// Stored as `keyCode:modifiers`, which is enough to rebuild it and short
/// enough to read in a defaults dump.
extension KeyCombination: RawRepresentable {
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":")
        guard parts.count == 2,
              let keyCode = UInt16(parts[0]),
              let modifiers = UInt(parts[1])
        else { return nil }
        self.init(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
    }

    public var rawValue: String { "\(keyCode):\(modifiers)" }
}

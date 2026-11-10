import AppKit
import Carbon.HIToolbox

/// A global shortcut registered as a Carbon hot key.
///
/// The other shortcut monitor listens to key events, and the system stops
/// handing those out while typing is protected. A hot key is delivered by the
/// window server itself, so it still fires then, which is exactly when the
/// paste-last chord is needed. It also takes the chord off the keyboard: the
/// app in front never sees it.
@MainActor
public final class CarbonShortcutMonitor: ShortcutMonitoring {
    public var onPress: (() -> Void)?
    public private(set) var isRunning = false

    private static let signature: OSType = 0x4F52_4D42  // "ORMB"

    private let identifier: UInt32
    private var shortcut: KeyCombination?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// - Parameter identifier: tells this monitor's hot key from any other
    ///   the app registers.
    public init(identifier: UInt32 = 1) {
        self.identifier = identifier
    }

    public func setShortcut(_ shortcut: KeyCombination?) {
        guard shortcut != self.shortcut else { return }
        let wasRunning = isRunning
        stop()
        self.shortcut = shortcut
        if wasRunning { start() }
    }

    public func start() {
        guard !isRunning, let shortcut else { return }
        installHandler()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(shortcut.modifierFlags),
            EventHotKeyID(signature: Self.signature, id: identifier),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        // Another app may own the chord already. Then it simply is not ours,
        // and the menu row still pastes.
        guard status == noErr, let reference else { return }
        hotKey = reference
        isRunning = true
    }

    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        isRunning = false
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                guard status == noErr else { return status }
                let monitor = Unmanaged<CarbonShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
                // Carbon delivers hot keys on the main run loop.
                return MainActor.assumeIsolated {
                    guard pressed.signature == CarbonShortcutMonitor.signature,
                          pressed.id == monitor.identifier
                    else { return OSStatus(eventNotHandledErr) }
                    monitor.onPress?()
                    return noErr
                }
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }
}

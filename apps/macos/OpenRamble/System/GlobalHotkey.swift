import AppKit
import Carbon.HIToolbox
import Foundation

/// The key to start dictation.
///
/// All options are modifiers: they can be held and do not take away from
/// applications regular combinations.
public enum DictationHotkey: String, CaseIterable, Sendable, Codable {
    case fn
    case rightCommand
    case rightOption
    case leftControl

    public var title: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightCommand: return "Right Command"
        case .rightOption: return "Right Option"
        case .leftControl: return "Left Control"
        }
    }

    /// Code of a specific physical key.
    ///
    /// Needed to distinguish the right Command from the left: they have the same flag.
    var keyCode: UInt16 {
        switch self {
        case .fn: return UInt16(kVK_Function)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightOption: return UInt16(kVK_RightOption)
        case .leftControl: return UInt16(kVK_Control)
        }
    }

    /// The bit of this particular physical key in the event modifier mask.
    ///
    /// The general flag (`.command`) is raised while **any** key of this type is held down.
    /// According to it, releasing the right Command is indistinguishable from “the right one was released, but
    /// the left one is still held" - the mask is the same in both cases, and releasing
    /// is lost. This is not a theory: dictation in this case remains turned on
    /// forever, because there is nothing else to stop it.
    ///
    /// The event also carries keyboard side bits, which distinguish the keys.
    /// Values are `NX_DEVICE...KEYMASK` from `IOKit/hidsystem/IOLLEvent.h`.
    var sideMask: UInt {
        switch self {
        // Fn has no side: there is exactly one key, and it also has one flag.
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        case .rightCommand: return 0x0000_0010
        case .rightOption: return 0x0000_0040
        case .leftControl: return 0x0000_0001
        }
    }

    /// Whether this key is held down in this modifier state.
    func isPressed(in rawFlags: UInt) -> Bool {
        rawFlags & sideMask != 0
    }

    /// All common modifier flags based on which shortcuts are built.
    private static let chordMask: UInt =
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.shift.rawValue
        | NSEvent.ModifierFlags.function.rawValue

    /// General flag of the type of this modifier (“some Command is pressed”).
    private var kindMask: UInt {
        switch self {
        case .rightCommand: return NSEvent.ModifierFlags.command.rawValue
        case .rightOption: return NSEvent.ModifierFlags.option.rawValue
        case .leftControl: return NSEvent.ModifierFlags.control.rawValue
        case .fn: return NSEvent.ModifierFlags.function.rawValue
        }
    }

    /// Whether the modifier is pressed ALONE, without satellites.
    ///
    /// “Cmd is already pressed, Ctrl has been added” - this is the path to the shortcut Cmd+Ctrl+..., not
    /// to dictation. To count such a chord as pressing meant to start recording
    /// background on each complex shortcut.
    func isExclusivelyPressed(in rawFlags: UInt) -> Bool {
        guard isPressed(in: rawFlags) else { return false }
        return rawFlags & Self.chordMask & ~kindMask == 0
    }
}

// MARK: - Event

/// Modifier event without `NSEvent`.
///
/// A gesture is a table “what happened + what came → what we are doing”, and you need to check it
/// table. It is impossible to collect `NSEvent` in a test, so parsing the gesture works with
/// this three, and `NSEvent` turns into it at the very edge.
public struct HotkeyEvent: Sendable, Equatable {
    public let keyCode: UInt16
    /// Full mask of modifiers from the event - along with keyboard side bits.
    public let rawFlags: UInt
    public let at: Date

    public init(keyCode: UInt16, rawFlags: UInt, at: Date) {
        self.keyCode = keyCode
        self.rawFlags = rawFlags
        self.at = at
    }
}

// MARK: - Parsing the gesture

/// Hotkey gesture machine.
///
/// Remembers exactly two things: whether the key is pressed and when the last press was made.
/// Everything else is decided on the spot.
struct HotkeyGestureMachine {
    enum Action: Sendable, Equatable {
        case none
        /// The key is pressed - we begin dictation.
        case press
        /// Let go - we finish. A short tap waits for the rest of the window
        /// double click; a long hold ends immediately.
        case release(after: TimeInterval)
        /// Second press in a row—non-hold mode.
        case doubleTap
        /// Pressing during recording without holding - please stop.
        case stopHandsFree
        /// While holding, another key was pressed: this is a shortcut, not
        /// dictation. The recording that has started must be interrupted quietly - without insertion, without
        /// messages and without double-clicking.
        case abortShortcut
    }

    private(set) var hotkey: DictationHotkey

    /// Whether recording occurs without holding.
    ///
    /// The machine must know this in order to distinguish “start a new dictation” from
    /// “stop current”: the gesture in both cases is the same - press.
    var isHandsFreeActive = false

    /// The interval within which the second press is considered a double press.
    let doubleTapWindow: TimeInterval

    private(set) var isHeld = false
    private var lastTapAt: Date?
    private var pressedAt: Date?
    /// The current hold turned out to be a shortcut: releasing it means nothing.
    private var abortedByShortcut = false

    init(hotkey: DictationHotkey, doubleTapWindow: TimeInterval = 0.35) {
        self.hotkey = hotkey
        self.doubleTapWindow = doubleTapWindow
    }

    /// Change the key.
    ///
    /// Returns action because the shift in the middle of a hold must close
    /// started gesture: events of the old key will not come at all after this, and
    /// there will be no way to release dictation - it will remain turned on forever.
    mutating func setHotkey(_ new: DictationHotkey) -> Action {
        let wasHeld = isHeld
        hotkey = new
        isHeld = false
        lastTapAt = nil
        pressedAt = nil
        // In non-holding mode, releasing doesn't mean anything anyway: recording is in progress
        // until the next press, and it will come from a new key.
        return wasHeld && !isHandsFreeActive ? .release(after: 0) : .none
    }

    /// Tracking stopped - the started gesture is interrupted.
    mutating func reset() {
        isHeld = false
        lastTapAt = nil
        pressedAt = nil
        abortedByShortcut = false
    }

    /// While holding, press a regular key - this is a shortcut.
    mutating func handleForeignKeyDown() -> Action {
        guard isHeld, !abortedByShortcut, !isHandsFreeActive else { return .none }
        return abortCurrentHold()
    }

    private mutating func abortCurrentHold() -> Action {
        abortedByShortcut = true
        lastTapAt = nil
        return .abortShortcut
    }

    mutating func handle(_ event: HotkeyEvent) -> Action {
        guard event.keyCode == hotkey.keyCode else {
            // Someone else's modifier. If the flags turn into
            // chord (⌘ added to the pressed Ctrl) - the person reaches for
            // shortcut, and the gesture ends in the same way as with a regular key.
            if isHeld, !abortedByShortcut, !isHandsFreeActive,
               hotkey.isPressed(in: event.rawFlags),
               !hotkey.isExclusivelyPressed(in: event.rawFlags) {
                return abortCurrentHold()
            }
            return .none
        }

        let pressed = hotkey.isPressed(in: event.rawFlags)

        if pressed, !isHeld {
            // Chord from the very beginning (Cmd is already pressed) - does not count as pressing.
            guard hotkey.isExclusivelyPressed(in: event.rawFlags) else { return .none }
            isHeld = true
            abortedByShortcut = false
            pressedAt = event.at

            if isHandsFreeActive {
                lastTapAt = nil
                return .stopHandsFree
            }

            if let lastTapAt, event.at.timeIntervalSince(lastTapAt) < doubleTapWindow {
                self.lastTapAt = nil
                return .doubleTap
            }

            lastTapAt = event.at
            return .press
        }

        if !pressed, isHeld {
            isHeld = false
            if abortedByShortcut {
                // Shortcut has already interrupted the gesture: releasing does not insert and does not
                // opens a double click window.
                abortedByShortcut = false
                pressedAt = nil
                lastTapAt = nil
                return .none
            }
            let heldFor = pressedAt.map { event.at.timeIntervalSince($0) } ?? doubleTapWindow
            pressedAt = nil
            // In non-hold mode, releasing does not mean anything: recording continues
            // until the next click.
            guard !isHandsFreeActive else { return .none }
            let remaining = max(0, doubleTapWindow - heldFor)
            // NSEvent does not promise decimal precision Date. Milliseconds for
            // gestures are more than sufficient and do not introduce floating point errors
            // lengthen or shorten the window between identical gestures.
            return .release(after: (remaining * 1_000).rounded() / 1_000)
        }

        return .none
    }
}

// MARK: - Event source

/// Where does the monitor get keyboard events from.
///
/// Behind the protocol - because the real source requires a person issued
/// access and live keyboard: the test will have neither one nor the other, and without
/// substitutions cannot be checked for any registration line.
@MainActor
public protocol HotkeyEventSource: AnyObject {
    /// Whether universal access has been granted. Without it, the system does not send events at all.
    var isTrusted: Bool { get }
    /// Subscribe to modifier changes. `nil` - the system failed.
    func addFlagsMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any?
    /// Subscribe to regular clicks - for the sake of Escape.
    func addKeyDownMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any?
    func removeMonitor(_ token: Any)
}

/// Real source: System Event Monitor.
///
/// Requires "Universal Access" only - same permission as paste
/// text. A separate “Input Monitoring” is not requested.
///
/// The monitor sees clicks, but does not remember anything and does not transmit: event
/// is compared with the selected key and Escape, everything else is discarded.
@MainActor
public final class SystemHotkeyEventSource: HotkeyEventSource {
    /// Global monitors do not receive events while this app is active. The
    /// onboarding test field is inside OpenRamble, so each logical
    /// subscription owns both a global and a local monitor.
    private final class MonitorPair {
        let global: Any
        let local: Any

        init(global: Any, local: Any) {
            self.global = global
            self.local = local
        }
    }

    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func addFlagsMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        // The handler is called on the main thread, so we enter it
        // directly. Wrapping it in a separate task would not guarantee order:
        // pressing and releasing could come in reverse order, and
        // dictation would remain enabled.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            MainActor.assumeIsolated { handler(HotkeyEvent(event)) }
        }
        guard let global else { return nil }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handler(HotkeyEvent(event))
            return event
        }
        guard let local else {
            NSEvent.removeMonitor(global)
            return nil
        }
        return MonitorPair(global: global, local: local)
    }

    public func addKeyDownMonitor(_ handler: @escaping @MainActor (HotkeyEvent) -> Void) -> Any? {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { handler(HotkeyEvent(event)) }
        }
        guard let global else { return nil }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handler(HotkeyEvent(event))
            // We don't intercept anything: Escape and other keys continue
            // normal path of the active application.
            return event
        }
        guard let local else {
            NSEvent.removeMonitor(global)
            return nil
        }
        return MonitorPair(global: global, local: local)
    }

    public func removeMonitor(_ token: Any) {
        if let pair = token as? MonitorPair {
            NSEvent.removeMonitor(pair.global)
            NSEvent.removeMonitor(pair.local)
        } else {
            NSEvent.removeMonitor(token)
        }
    }
}

extension HotkeyEvent {
    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue, at: Date())
    }
}

// MARK: - Monitor

/// Track the hotkey in all applications.
@MainActor
public protocol HotkeyMonitoring: AnyObject {
    var onPress: (() -> Void)? { get set }
    var onRelease: (() -> Void)? { get set }
    var onDoubleTap: (() -> Void)? { get set }
    /// Single press when recording is in progress without holding - please stop.
    var onSingleTapWhileHandsFree: (() -> Void)? { get set }
    /// The hold turned out to be a shortcut - end the recording quietly.
    var onAbortShortcut: (() -> Void)? { get set }
    var onEscape: (() -> Void)? { get set }

    /// Is recording currently taking place without holding.
    var isHandsFreeActive: Bool { get set }
    var isRunning: Bool { get }

    func setHotkey(_ hotkey: DictationHotkey)
    func start()
    func stop()
}

@MainActor
public final class GlobalHotkeyMonitor: HotkeyMonitoring {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public var onDoubleTap: (() -> Void)?
    public var onSingleTapWhileHandsFree: (() -> Void)?
    public var onAbortShortcut: (() -> Void)?
    public var onEscape: (() -> Void)?

    public var isHandsFreeActive: Bool {
        get { machine.isHandsFreeActive }
        set { machine.isHandsFreeActive = newValue }
    }

    public var hotkey: DictationHotkey { machine.hotkey }
    public private(set) var isRunning = false

    private let source: any HotkeyEventSource
    private var machine: HotkeyGestureMachine
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var pendingRelease: Task<Void, Never>?

    public init(
        source: any HotkeyEventSource = SystemHotkeyEventSource(),
        hotkey: DictationHotkey = .rightCommand
    ) {
        self.source = source
        machine = HotkeyGestureMachine(hotkey: hotkey)
    }

    public func setHotkey(_ hotkey: DictationHotkey) {
        deliver(machine.setHotkey(hotkey))
    }

    /// Start tracking.
    ///
    /// Called again every time permissions are checked: the system issues
    /// monitor the event only after the user has given access, and
    /// You need to register after this. No restart key
    /// would be silent until the application is restarted.
    ///
    /// But if tracking is already in progress, it cannot be restarted. Checking Permissions
    /// ticks on a timer, and a restart would reset the memory of the key pressed -
    /// and the release that occurred after the tick would be lost. Dictation at the same time
    /// would remain on: the microphone is on, recording is in progress, there is nothing to stop it.
    ///
    /// Only `stop()` is supposed to erase this memory - that’s what it uses
    /// waking up the computer, where the key was released without our knowledge.
    public func start() {
        guard !isRunning else { return }
        guard source.isTrusted else { return }

        guard let flags = source.addFlagsMonitor({ [weak self] event in
            self?.handleFlagsChanged(event)
        }) else { return }

        guard let keys = source.addKeyDownMonitor({ [weak self] event in
            self?.handleKeyDown(event)
        }) else {
            // There should be no semi-working tracking. Left without a mate
            // the monitor is not removed by anyone, and `start()` is called at each check
            // permissions - live subscriptions would accumulate, and each one would cancel
            // dictation one at a time Escape.
            source.removeMonitor(flags)
            return
        }

        flagsMonitor = flags
        keyMonitor = keys
        isRunning = true
    }

    public func stop() {
        pendingRelease?.cancel()
        pendingRelease = nil
        if let flagsMonitor { source.removeMonitor(flagsMonitor) }
        if let keyMonitor { source.removeMonitor(keyMonitor) }
        flagsMonitor = nil
        keyMonitor = nil
        isRunning = false
        machine.reset()
    }

    private func handleFlagsChanged(_ event: HotkeyEvent) {
        deliver(machine.handle(event))
    }

    private func handleKeyDown(_ event: HotkeyEvent) {
        // Escape cancels dictation. `AppState` solves this: there is no dictation yet,
        // Escape is a regular key and cannot be touched.
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        // Any other key while holding the modifier is a shortcut
        // (Ctrl+C), not dictation: the started gesture ends quietly.
        deliver(machine.handleForeignKeyDown())
    }

    private func deliver(_ action: HotkeyGestureMachine.Action) {
        switch action {
        case .none: break
        case .press: onPress?()
        case let .release(delay):
            pendingRelease?.cancel()
            pendingRelease = nil
            guard delay > 0 else {
                onRelease?()
                return
            }
            pendingRelease = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.pendingRelease = nil
                self?.onRelease?()
            }
        case .doubleTap:
            // The first quick tap has already started the session, but releasing it
            // waited for the second click. Now this is the same session without the hold:
            // the deferred stop no longer belongs to it.
            pendingRelease?.cancel()
            pendingRelease = nil
            onDoubleTap?()
        case .stopHandsFree: onSingleTapWhileHandsFree?()
        case .abortShortcut: onAbortShortcut?()
        }
    }
}

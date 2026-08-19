import AppKit

/// Watches the whole machine for one shortcut.
@MainActor
public protocol ShortcutMonitoring: AnyObject {
    var onPress: (() -> Void)? { get set }
    var isRunning: Bool { get }

    /// `nil` takes the shortcut off the keyboard entirely.
    func setShortcut(_ shortcut: KeyCombination?)
    func start()
    func stop()
}

/// The real one, on the same event source the dictation key uses.
///
/// Nothing is swallowed: the handler returns the event untouched, so a
/// shortcut that happens to collide with one in the front application still
/// reaches it. Eating other applications' keys from the background is how a
/// small utility becomes the thing that broke someone's editor.
@MainActor
public final class GlobalShortcutMonitor: ShortcutMonitoring {
    public var onPress: (() -> Void)?
    public private(set) var isRunning = false

    private let source: any HotkeyEventSource
    private var shortcut: KeyCombination?
    private var monitor: Any?

    public init(source: any HotkeyEventSource = SystemHotkeyEventSource()) {
        self.source = source
    }

    public func setShortcut(_ shortcut: KeyCombination?) {
        self.shortcut = shortcut
        if shortcut == nil { stop() }
    }

    public func start() {
        // A monitor with nothing to look for is a monitor that only costs.
        guard !isRunning, shortcut != nil, source.isTrusted else { return }
        monitor = source.addKeyDownMonitor { [weak self] event in
            self?.handle(event)
        }
        isRunning = monitor != nil
    }

    public func stop() {
        guard let monitor else {
            isRunning = false
            return
        }
        source.removeMonitor(monitor)
        self.monitor = nil
        isRunning = false
    }

    private func handle(_ event: HotkeyEvent) {
        guard let shortcut,
              shortcut.matches(keyCode: event.keyCode, rawFlags: event.rawFlags)
        else { return }
        onPress?()
    }
}

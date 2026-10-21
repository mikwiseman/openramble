import AppKit
import Carbon.HIToolbox
import XCTest

/// The real event source, handed events through this process's own
/// `sendEvent`. Each is an F19 and goes to no window, so nothing reaches
/// another application and nothing presses a control here.
@MainActor
final class SystemHotkeyEventSourceTests: XCTestCase {
    private let source = SystemHotkeyEventSource()
    private var token: Any?
    private var delivered = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        token = source.addKeyDownMonitor { [weak self] _ in self?.delivered += 1 }
        try XCTSkipIf(token == nil, "this runner may not monitor the keyboard")
    }

    override func tearDown() async throws {
        if let token { source.removeMonitor(token) }
    }

    /// OpenRamble presses ⌘V and "Send it."'s Return the way a keyboard does,
    /// so the system shows them to its own key monitors as well, with this
    /// process as their source: posting stamps an event with its poster, as
    /// creating one does. Taken for the person's shortcut, our Return would
    /// cancel a press held across it, swallow its release, and leave the take
    /// it started listening with the key up.
    func testAKeyFromThisProcessIsNotThePersons() throws {
        let key = try XCTUnwrap(CGEvent(
            keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
            virtualKey: CGKeyCode(kVK_F19),
            keyDown: true
        ))

        NSApp.sendEvent(try XCTUnwrap(NSEvent(cgEvent: key)))

        XCTAssertEqual(delivered, 0)
    }

    /// The person's keys come from the keyboard, not from this process, and
    /// still arrive.
    func testAKeyFromAnotherProcessArrives() throws {
        let key = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_F19),
            keyDown: true
        ))
        key.setIntegerValueField(.eventSourceUnixProcessID, value: 0)

        NSApp.sendEvent(try XCTUnwrap(NSEvent(cgEvent: key)))

        XCTAssertEqual(delivered, 1)
    }
}

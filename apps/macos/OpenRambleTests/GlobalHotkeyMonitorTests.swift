import AppKit
import Carbon.HIToolbox
import XCTest

@MainActor
final class GlobalHotkeyMonitorTests: XCTestCase {
    private var source: FakeHotkeyEventSource!
    private var monitor: GlobalHotkeyMonitor!

    override func setUp() async throws {
        source = FakeHotkeyEventSource()
        monitor = GlobalHotkeyMonitor(source: source, hotkey: .rightCommand)
    }

    private var pressedRightCommand: HotkeyEvent {
        HotkeyEvent(
            keyCode: DictationHotkey.rightCommand.keyCode,
            rawFlags: NSEvent.ModifierFlags.command.rawValue | 0x0000_0010,
            at: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    private var releasedRightCommand: HotkeyEvent {
        HotkeyEvent(
            keyCode: DictationHotkey.rightCommand.keyCode,
            rawFlags: 0,
            at: Date(timeIntervalSince1970: 1_000_001)
        )
    }

    // MARK: - Launch

    /// Ctrl+C over the selected modifier: keyDown must reach the machine
    /// and cut off the gesture - otherwise each shortcut turns into a phantom
    /// dictation, and two in a row enable recording without holding it in the background.
    func testScenario001() {
        let source = FakeHotkeyEventSource()
        let monitor = GlobalHotkeyMonitor(source: source)
        monitor.setHotkey(.leftControl)
        var aborted = 0
        var released = 0
        monitor.onAbortShortcut = { aborted += 1 }
        monitor.onRelease = { released += 1 }
        monitor.start()

        source.sendFlags(HotkeyEvent(
            keyCode: DictationHotkey.leftControl.keyCode,
            rawFlags: NSEvent.ModifierFlags.control.rawValue | 0x0000_0001,
            at: Date()
        ))
        source.sendKeyDown(HotkeyEvent(keyCode: 8, rawFlags: 0, at: Date()))
        source.sendFlags(HotkeyEvent(
            keyCode: DictationHotkey.leftControl.keyCode,
            rawFlags: 0,
            at: Date().addingTimeInterval(0.1)
        ))

        XCTAssertEqual(aborted, 1, "Shortcut must abort the gesture exactly once")
        XCTAssertEqual(released, 0, "After a break, releasing does not insert")
    }

    func testScenario002() {
        source.isTrusted = false

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(source.flagsMonitorCount, 0)
        XCTAssertEqual(source.keyMonitorCount, 0)
    }

    /// Repeated `start()` should not re-register anything.
    ///
    /// The permission check ticks once per second and calls `start()` every time.
    /// A restart would reset the memory of the key held down: the release that happened
    /// after a tick, it would be lost, and dictation would remain enabled.
    func testScenario003() {
        monitor.start()
        monitor.start()
        monitor.start()

        XCTAssertEqual(source.flagsMonitorCount, 1)
        XCTAssertEqual(source.keyMonitorCount, 1)
    }

    func testScenario004() {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        // Permission check tick in the middle of a hold.
        monitor.start()
        source.sendFlags(releasedRightCommand)

        XCTAssertEqual(releases, 1)
    }

    /// The key was released while the Mac was sleeping.
    ///
    /// The system does not send events from a sleeping machine: the monitor remains with
    /// memory of the key pressed, and the first press after waking up does not
    /// is considered a click at all. Only complete memory can be erased
    /// stopping tracking - this is what wake-up processing relies on.
    func testScenario005() {
        var presses = 0
        monitor.onPress = { presses += 1 }
        monitor.start()
        source.sendFlags(pressedRightCommand)
        XCTAssertEqual(presses, 1)

        // We fell asleep with the key pressed, woke up with the key released.
        monitor.stop()
        monitor.start()
        source.sendFlags(pressedRightCommand)

        XCTAssertEqual(presses, 2, "the first press after waking up was lost")
    }

    /// The system gave up one monitor and refused the second.
    ///
    /// A subscription left without a pair is not canceled by anyone, and `start()` is called once
    /// per second - in an hour there would be a thousand live subscriptions, and each one would cancel
    /// dictation with one click of Escape.
    func testScenario006() {
        source.grantsKeyMonitor = false

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(source.flagsMonitorCount, 1)
        XCTAssertEqual(source.removedTokens, ["flags-1"])
        XCTAssertEqual(source.liveMonitorCount, 0)
    }

    func testScenario007() {
        source.grantsKeyMonitor = false

        for _ in 0..<10 { monitor.start() }

        XCTAssertEqual(source.liveMonitorCount, 0)
    }

    func testScenario008() {
        source.grantsFlagsMonitor = false

        monitor.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(source.keyMonitorCount, 0)
    }

    // MARK: - Stop

    func testScenario009() {
        monitor.start()
        monitor.stop()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(Set(source.removedTokens), ["flags-1", "keys-1"])
        XCTAssertEqual(source.liveMonitorCount, 0)
    }

    func testScenario010() {
        monitor.start()
        monitor.stop()
        monitor.start()

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(source.flagsMonitorCount, 2)
        XCTAssertEqual(source.keyMonitorCount, 2)
    }

    func testScenario011() {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()
        source.sendFlags(pressedRightCommand)

        monitor.stop()
        monitor.start()
        // The release event after a restart refers to the dangling gesture.
        source.sendFlags(releasedRightCommand)

        XCTAssertEqual(releases, 0)
    }

    // MARK: - Gesture delivery

    func testScenario012() {
        var log: [String] = []
        monitor.onPress = { log.append("press") }
        monitor.onRelease = { log.append("release") }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        source.sendFlags(releasedRightCommand)

        XCTAssertEqual(log, ["press", "release"])
    }

    func testScenario013() async throws {
        var releases = 0
        let releaseDelivered = expectation(description: "deferred release delivered")
        monitor.onRelease = {
            releases += 1
            releaseDelivered.fulfill()
        }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        source.sendFlags(
            HotkeyEvent(
                keyCode: DictationHotkey.rightCommand.keyCode,
                rawFlags: 0,
                at: Date(timeIntervalSince1970: 1_000_000.05)
            )
        )

        XCTAssertEqual(releases, 0)
        await fulfillment(of: [releaseDelivered], timeout: 2)
        XCTAssertEqual(releases, 1)
    }

    func testScenario014() async throws {
        var releases = 0
        var doubleTaps = 0
        monitor.onRelease = { releases += 1 }
        monitor.onDoubleTap = { doubleTaps += 1 }
        monitor.start()

        source.sendFlags(pressedRightCommand)
        source.sendFlags(
            HotkeyEvent(
                keyCode: DictationHotkey.rightCommand.keyCode,
                rawFlags: 0,
                at: Date(timeIntervalSince1970: 1_000_000.05)
            )
        )
        source.sendFlags(
            HotkeyEvent(
                keyCode: DictationHotkey.rightCommand.keyCode,
                rawFlags: NSEvent.ModifierFlags.command.rawValue | 0x0000_0010,
                at: Date(timeIntervalSince1970: 1_000_000.2)
            )
        )

        XCTAssertEqual(doubleTaps, 1)
        try await Task.sleep(for: .milliseconds(380))
        XCTAssertEqual(releases, 0)
    }

    func testScenario015() {
        var log: [String] = []
        monitor.onPress = { log.append("press") }
        monitor.onSingleTapWhileHandsFree = { log.append("stop") }
        monitor.start()
        monitor.isHandsFreeActive = true

        source.sendFlags(pressedRightCommand)

        XCTAssertEqual(log, ["stop"])
    }

    /// Changing a key mid-hold is required to end the dictation.
    func testScenario016() {
        var releases = 0
        monitor.onRelease = { releases += 1 }
        monitor.start()
        source.sendFlags(pressedRightCommand)

        monitor.setHotkey(.fn)

        XCTAssertEqual(releases, 1)
    }

    // MARK: - Escape

    func testScenario017() {
        var escapes = 0
        monitor.onEscape = { escapes += 1 }
        monitor.start()

        source.sendKeyDown(HotkeyEvent(keyCode: UInt16(kVK_Escape), rawFlags: 0, at: Date()))

        XCTAssertEqual(escapes, 1)
    }

    /// All other keys must pass by.
    ///
    /// The application promises that it does not remember or process other people's clicks.
    func testScenario018() {
        var escapes = 0
        monitor.onEscape = { escapes += 1 }
        monitor.start()

        for code in [kVK_ANSI_A, kVK_Return, kVK_Space, kVK_Tab, kVK_Delete] {
            source.sendKeyDown(HotkeyEvent(keyCode: UInt16(code), rawFlags: 0, at: Date()))
        }

        XCTAssertEqual(escapes, 0)
    }
}

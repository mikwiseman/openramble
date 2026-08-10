import AppKit
import Carbon.HIToolbox
import XCTest

/// Modifier bits in the form in which the system sends them.
///
/// The general flag says “this type of key is pressed”, the side bit - which one.
private enum Bits {
    static let command = NSEvent.ModifierFlags.command.rawValue
    static let control = NSEvent.ModifierFlags.control.rawValue
    static let option = NSEvent.ModifierFlags.option.rawValue
    static let function = NSEvent.ModifierFlags.function.rawValue

    static let leftCommandSide: UInt = 0x0000_0008
    static let rightCommandSide: UInt = 0x0000_0010
    static let leftControlSide: UInt = 0x0000_0001
    static let rightControlSide: UInt = 0x0000_2000
    static let rightOptionSide: UInt = 0x0000_0040
}

private let start = Date(timeIntervalSince1970: 1_000_000)

private func event(
    _ hotkey: DictationHotkey,
    flags: UInt,
    after seconds: TimeInterval = 0
) -> HotkeyEvent {
    HotkeyEvent(keyCode: hotkey.keyCode, rawFlags: flags, at: start.addingTimeInterval(seconds))
}

final class HotkeyGestureMachineTests: XCTestCase {
    // MARK: - Shortcuts are not dictation

    /// Ctrl+C: modifier pressed, then letter. This is a shortcut, not a dictation -
    /// the started gesture ends quietly, without insertion and without messages.
    func testScenario001() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        XCTAssertEqual(
            machine.handle(event(.leftControl, flags: Bits.control | Bits.leftControlSide)),
            .press
        )
        XCTAssertEqual(machine.handleForeignKeyDown(), .abortShortcut)
        // Releasing the modifier after the shortcut does not insert anything.
        XCTAssertEqual(machine.handle(event(.leftControl, flags: 0, after: 0.1)), .none)
    }

    /// Ctrl+C, then Ctrl+V within the double-click window. Previously second
    /// pressing turned on recording without holding it - in the background and forever.
    func testScenario002() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        _ = machine.handle(event(.leftControl, flags: Bits.control | Bits.leftControlSide))
        XCTAssertEqual(machine.handleForeignKeyDown(), .abortShortcut)
        _ = machine.handle(event(.leftControl, flags: 0, after: 0.08))

        // The second shortcut immediately follows: press, but NOT doubleTap.
        XCTAssertEqual(
            machine.handle(
                event(.leftControl, flags: Bits.control | Bits.leftControlSide, after: 0.15)
            ),
            .press
        )
    }

    /// Chord from modifiers (⌘ already held down, Ctrl added) - not pressing:
    /// a person reaches for the Cmd+Ctrl shortcut, and not for dictation.
    func testScenario003() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        XCTAssertEqual(
            machine.handle(
                event(
                    .leftControl,
                    flags: Bits.command | Bits.leftCommandSide | Bits.control | Bits.leftControlSide
                )
            ),
            .none
        )
    }

    /// A second modifier added DURING the hold also terminates the gesture.
    func testScenario004() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        _ = machine.handle(event(.leftControl, flags: Bits.control | Bits.leftControlSide))
        // An alien modifier event has arrived: the flags now contain ⌘ and Ctrl.
        let chord = HotkeyEvent(
            keyCode: 55,
            rawFlags: Bits.command | Bits.leftCommandSide | Bits.control | Bits.leftControlSide,
            at: start.addingTimeInterval(0.05)
        )
        XCTAssertEqual(machine.handle(chord), .abortShortcut)
        XCTAssertEqual(machine.handle(event(.leftControl, flags: 0, after: 0.2)), .none)
    }

    /// Breaking during recording without holding is impossible: the modifier has been there for a long time
    /// is released, and the person's shortcuts do not apply to the gesture.
    func testScenario005() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)
        machine.isHandsFreeActive = true

        XCTAssertEqual(machine.handleForeignKeyDown(), .none)
    }

    // MARK: - Hold

    func testScenario006() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)

        XCTAssertEqual(
            machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide)),
            .press
        )
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 1)), .release(after: 0))
    }

    func testScenario007() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        // Auto-repeat and other unnecessary events: the gesture has already been started, there is no second start.
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.1)), .none)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.2)), .none)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.3)), .release(after: 0.05))
    }

    func testScenario008() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        let alien = HotkeyEvent(
            keyCode: UInt16(kVK_Shift),
            rawFlags: NSEvent.ModifierFlags.shift.rawValue,
            at: start
        )

        XCTAssertEqual(machine.handle(alien), .none)
        XCTAssertFalse(machine.isHeld)
    }

    /// The Fn flag is raised not only by the 🌐 key itself.
    ///
    /// The system marks with it a whole category of keys - arrows, F1–F12, Home and
    /// others - and it comes along with other people's events. No selection by code
    /// dictation keys would start by pressing the arrow.
    func testScenario009() {
        var machine = HotkeyGestureMachine(hotkey: .fn)
        let alien = HotkeyEvent(
            keyCode: UInt16(kVK_Shift),
            rawFlags: Bits.function | NSEvent.ModifierFlags.shift.rawValue,
            at: start
        )

        XCTAssertEqual(machine.handle(alien), .none)
        XCTAssertFalse(machine.isHeld)

        // And 🌐 herself begins.
        XCTAssertEqual(machine.handle(event(.fn, flags: Bits.function, after: 0.1)), .press)
    }

    /// Releasing the right key while holding the left one should succeed.
    ///
    /// The general flag `.command` is raised while ANY Command is held. Analysis on it
    /// does not see the release of the right one - and dictation remains turned on forever:
    /// the microphone is on, recording is in progress, there is nothing to stop it.
    func testScenario010() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)

        // Left Command is already held: its events are filtered out by key code.
        XCTAssertEqual(
            machine.handle(
                HotkeyEvent(
                    keyCode: UInt16(kVK_Command),
                    rawFlags: Bits.command | Bits.leftCommandSide,
                    at: start
                )
            ),
            .none
        )

        XCTAssertEqual(
            machine.handle(
                event(
                    .rightCommand,
                    flags: Bits.command | Bits.leftCommandSide | Bits.rightCommandSide,
                    after: 0.1
                )
            ),
            .press
        )

        // The right one is released, the left one is still clamped - the common flag remains raised.
        XCTAssertEqual(
            machine.handle(
                event(.rightCommand, flags: Bits.command | Bits.leftCommandSide, after: 0.5)
            ),
            .release(after: 0)
        )
    }

    func testScenario011() {
        var machine = HotkeyGestureMachine(hotkey: .leftControl)

        XCTAssertEqual(
            machine.handle(
                event(
                    .leftControl,
                    flags: Bits.control | Bits.rightControlSide | Bits.leftControlSide
                )
            ),
            .press
        )
        XCTAssertEqual(
            machine.handle(
                event(.leftControl, flags: Bits.control | Bits.rightControlSide, after: 0.4)
            ),
            .release(after: 0)
        )
    }

    func testScenario012() {
        var machine = HotkeyGestureMachine(hotkey: .rightOption)

        // The general Option flag is raised, but the right side bit is not: hold the left one.
        XCTAssertEqual(machine.handle(event(.rightOption, flags: Bits.option)), .none)
        XCTAssertFalse(machine.isHeld)

        XCTAssertEqual(
            machine.handle(event(.rightOption, flags: Bits.option | Bits.rightOptionSide, after: 0.1)),
            .press
        )
    }

    func testScenario013() {
        var machine = HotkeyGestureMachine(hotkey: .fn)

        XCTAssertEqual(machine.handle(event(.fn, flags: Bits.function)), .press)
        XCTAssertEqual(machine.handle(event(.fn, flags: 0, after: 0.6)), .release(after: 0))
    }

    // MARK: - Double click

    func testScenario014() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand, doubleTapWindow: 0.35)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.05)), .release(after: 0.3))
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.2)), .doubleTap)
    }

    func testScenario015() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand, doubleTapWindow: 0.35)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.05)), .release(after: 0.3))
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.5)), .press)
    }

    func testScenario016() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand, doubleTapWindow: 0.35)
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .press)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.05)), .release(after: 0.3))
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.1)), .doubleTap)
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.15)), .release(after: 0.3))
        // Three clicks in a row does not mean "double twice".
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held, after: 0.2)), .press)
    }

    // MARK: - No hold mode

    func testScenario017() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        machine.isHandsFreeActive = true
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .stopHandsFree)
        //Releasing doesn't mean anything here: recording continues until the next press.
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.1)), .none)
    }

    func testScenario018() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        machine.isHandsFreeActive = true
        let held = Bits.command | Bits.rightCommandSide

        XCTAssertEqual(machine.handle(event(.rightCommand, flags: held)), .stopHandsFree)
        machine.isHandsFreeActive = false
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.1)), .release(after: 0.25))
    }

    // MARK: - Change key

    /// The key was changed while it was being held.
    ///
    /// Events of the old key will not come at all after this: the monitor compares
    /// code from the new one. Without an explicit closing gesture, releasing dictation becomes
    /// nothing, and it remains turned on forever.
    func testScenario019() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)

        XCTAssertEqual(
            machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide)),
            .press
        )
        XCTAssertEqual(machine.setHotkey(.fn), .release(after: 0))
        XCTAssertFalse(machine.isHeld)
    }

    func testScenario020() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        XCTAssertEqual(machine.setHotkey(.fn), .none)
    }

    func testScenario021() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        machine.isHandsFreeActive = true
        _ = machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide))

        // In this mode, recording is stopped by pressing rather than releasing.
        XCTAssertEqual(machine.setHotkey(.fn), .none)
    }

    func testScenario022() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        _ = machine.setHotkey(.leftControl)

        XCTAssertEqual(
            machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide)),
            .none
        )
        XCTAssertEqual(
            machine.handle(
                event(.leftControl, flags: Bits.control | Bits.leftControlSide, after: 0.1)
            ),
            .press
        )
    }

    func testScenario023() {
        var machine = HotkeyGestureMachine(hotkey: .rightCommand)
        _ = machine.handle(event(.rightCommand, flags: Bits.command | Bits.rightCommandSide))

        machine.reset()

        XCTAssertFalse(machine.isHeld)
        // Releasing an already broken gesture does not issue a second stop.
        XCTAssertEqual(machine.handle(event(.rightCommand, flags: 0, after: 0.1)), .none)
    }

    // MARK: - Key layout

    func testScenario024() {
        // Codes must be different: they are used to filter out other people's events.
        let codes = DictationHotkey.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)

        XCTAssertEqual(DictationHotkey.rightCommand.sideMask, Bits.rightCommandSide)
        XCTAssertEqual(DictationHotkey.rightOption.sideMask, Bits.rightOptionSide)
        XCTAssertEqual(DictationHotkey.leftControl.sideMask, Bits.leftControlSide)
        XCTAssertEqual(DictationHotkey.fn.sideMask, Bits.function)

        // The side bit must not match the common flag: otherwise distinguish
        // there would be nothing for the keys.
        XCTAssertNotEqual(DictationHotkey.rightCommand.sideMask, Bits.command)
        XCTAssertNotEqual(DictationHotkey.leftControl.sideMask, Bits.control)
        XCTAssertNotEqual(DictationHotkey.rightOption.sideMask, Bits.option)
    }
}

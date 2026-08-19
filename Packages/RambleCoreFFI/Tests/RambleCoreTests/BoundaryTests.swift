import RambleCore
import XCTest

/// Does Swift actually reach the shared core, and does it get the same answers?
///
/// The conformance fixtures already prove the Rust pipeline reproduces the Swift
/// one. This proves the *boundary* — that the same logic survives being called
/// across a language edge, with the strings and offsets intact. Those are
/// different claims, and the second is where a migration goes wrong.
final class BoundaryTests: XCTestCase {
    func testTheTextPipelineAnswersThroughTheBoundary() {
        let result = processText(
            recognized: "  привет ,  мир  ",
            replacements: [],
            allowPressReturnCommand: false,
            phoneticMatching: true
        )
        XCTAssertEqual(result.text, "Привет, мир")
        XCTAssertNil(result.command)
    }

    /// Offsets cross as characters, not bytes. A Cyrillic prefix is where that
    /// distinction stops being academic.
    func testSpanOffsetsAreCharactersNotBytes() {
        let result = processText(
            recognized: "смотри TextPipeline.Output",
            replacements: [],
            allowPressReturnCommand: false,
            phoneticMatching: true
        )
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans[0].kind, .identifier)
        // Seven characters of Cyrillic and a space — not the fourteen bytes
        // they occupy.
        XCTAssertEqual(result.spans[0].start, 7)
        XCTAssertEqual(result.spans[0].text, "TextPipeline.Output")
    }

    func testADictionaryReplacementCrosses() {
        let entry = FfiReplacement(
            id: "1",
            spoken: "сентри",
            written: "Sentry",
            inflects: true,
            noAcousticBoost: true,
            allowsPhoneticMatching: false
        )
        let result = processText(
            recognized: "ошибка в сентри",
            replacements: [entry],
            allowPressReturnCommand: false,
            phoneticMatching: true
        )
        XCTAssertEqual(result.text, "Ошибка в Sentry")
    }

    func testSessionPoliciesAnswerThroughTheBoundary() {
        XCTAssertTrue(stateIsCapturing(state: .listening))
        XCTAssertFalse(stateIsCapturing(state: .preparing))
        XCTAssertEqual(decideStop(state: .preparing, isHandsFree: false), .deferUntilListening)
        XCTAssertFalse(canCancel(state: .inserting))
    }

    /// The deadline is a number the Mac already depends on; it must not change
    /// meaning by crossing the boundary.
    func testTheDeadlineIsTheSameNumberOnBothSides() {
        XCTAssertEqual(deadlineForAudio(audio: .seconds(30)), .seconds(120))
        XCTAssertEqual(deadlineForAudio(audio: .seconds(90)), .seconds(180))
    }

    func testTheGestureMachineKeepsItsStateAcrossCalls() {
        let machine = FfiGestureMachine(doubleTapWindow: .milliseconds(350))
        XCTAssertEqual(
            machine.handle(isHotkeyKey: true, isHotkeyDown: true, isExclusive: true, at: .zero),
            .press
        )
        XCTAssertEqual(
            machine.handle(
                isHotkeyKey: true, isHotkeyDown: false, isExclusive: false,
                at: .milliseconds(50)
            ),
            .release(after: .milliseconds(300))
        )
        XCTAssertFalse(machine.isHeld())
    }
}

private extension TimeInterval {
    static func seconds(_ value: Double) -> TimeInterval { value }
    static func milliseconds(_ value: Double) -> TimeInterval { value / 1000 }
    static var zero: TimeInterval { 0 }
}

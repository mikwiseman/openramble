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

/// The two stores the Mac would migrate onto next, checked against the trees the
/// Swift app actually wrote on this machine.
///
/// Skipped where there is nothing installed: an absent model is not a defect in
/// this code, and a test that fails on a clean checkout teaches people to ignore
/// failures.
final class StoreBoundaryTests: XCTestCase {
    private var supportRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Application Support/OpenRamble", directoryHint: .isDirectory)
    }

    private var manifestJSON: String? {
        let path = "Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json"
        for base in [FileManager.default.currentDirectoryPath, "../..", "../../.."] {
            let url = URL(fileURLWithPath: base).appending(path: path)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }

    func testTheStoreRecognisesTheInstallSwiftWrote() throws {
        guard let manifest = manifestJSON else {
            throw XCTSkip("the shipping manifest is not reachable from here")
        }
        let models = supportRoot.appending(path: "Models", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: models.path) else {
            throw XCTSkip("no models directory on this machine")
        }

        let report = try inspectModel(manifestJson: manifest, root: models.path)
        guard report.state == .ready else {
            throw XCTSkip("no complete install here: \(report.state)")
        }
        // The whole point of matching the layout: an existing install is adopted
        // rather than downloaded again.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: report.engineDirectory),
            "the recogniser directory does not exist: \(report.engineDirectory)"
        )
        XCTAssertEqual(report.totalByteCount, 739_508_576)
    }

    func testHistoryWrittenBySwiftReadsThroughTheBoundary() throws {
        let history = supportRoot.appending(path: "History", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: history.appending(path: "history.json").path)
        else {
            throw XCTSkip("no history on this machine")
        }

        let entries = loadHistory(directory: history.path)
        guard let newest = entries.first else {
            throw XCTSkip("history is empty")
        }
        XCTAssertFalse(newest.text.isEmpty)
        // Foundation's reference date, read back as Foundation reads it. A date
        // that came through as the Unix epoch would land in 1970 and be decades
        // off without ever failing to parse.
        let when = Date(timeIntervalSinceReferenceDate: newest.date)
        XCTAssertGreaterThan(when, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertLessThan(when, Date().addingTimeInterval(60))
    }
}

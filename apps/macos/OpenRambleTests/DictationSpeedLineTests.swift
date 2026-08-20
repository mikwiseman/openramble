import DictationCore
import XCTest

/// One line shape, and a stage that did not run must never read as zero.
final class DictationSpeedLineTests: XCTestCase {
    /// `absent` rather than `0.00`, because the two mean opposite things and
    /// confusing them is what hid the real cause of slow dictations for weeks.
    func testAStageThatDidNotRunSaysSoRatherThanReadingZero() {
        let report = DictationSpeedReport(
            toRecognizedText: .seconds(8),
            toPasteDispatched: nil,
            phases: DictationPhaseBreakdown(
                captureFreeze: .milliseconds(30),
                enginePreparation: nil,
                recognition: .seconds(7),
                engineProcessing: .milliseconds(200),
                engineQueueing: nil,
                audioDecoding: nil,
                recordingReadable: nil,
                audioDuration: .seconds(11)
            )
        )

        let line = DictationSpeedLine.text(for: report)

        XCTAssertTrue(line.contains("prepare=absent"), line)
        XCTAssertTrue(line.contains("queued=absent"), line)
        XCTAssertFalse(line.contains("=0.00s\tprepare"), line)
        XCTAssertTrue(line.contains("total=8.00s"), line)
        XCTAssertTrue(line.contains("engine=0.20s"), line)
    }

    /// The branch is named, so a number can never again be silently about code
    /// that did not run.
    func testItNamesTheBranchTheTakeTook() {
        let inMemory = DictationSpeedReport(
            toRecognizedText: .seconds(1),
            toPasteDispatched: nil,
            phases: DictationPhaseBreakdown(
                captureFreeze: .milliseconds(30),
                enginePreparation: nil,
                recognition: .seconds(1),
                engineProcessing: .milliseconds(200),
                engineQueueing: nil,
                audioDecoding: nil,
                recordingReadable: nil,
                audioDuration: .seconds(3)
            )
        )
        XCTAssertTrue(DictationSpeedLine.text(for: inMemory).contains("path=memory"))

        let fromFile = DictationSpeedReport(
            toRecognizedText: .seconds(1),
            toPasteDispatched: nil,
            phases: DictationPhaseBreakdown(
                captureFreeze: .milliseconds(30),
                enginePreparation: nil,
                recognition: .seconds(1),
                engineProcessing: .milliseconds(200),
                engineQueueing: nil,
                audioDecoding: nil,
                recordingReadable: .milliseconds(40),
                audioDuration: .seconds(3)
            )
        )
        XCTAssertTrue(DictationSpeedLine.text(for: fromFile).contains("path=file"))
    }
}

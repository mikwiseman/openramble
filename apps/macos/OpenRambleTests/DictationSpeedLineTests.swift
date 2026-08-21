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
        XCTAssertTrue(line.contains("poolreturn=absent"), line)
        XCTAssertTrue(line.contains("mainreturn=absent"), line)
        XCTAssertTrue(line.contains("enginedispatch=absent"), line)
        XCTAssertTrue(line.contains("frame=absent"), line)
        XCTAssertFalse(line.contains("=0.00s\tprepare"), line)
        XCTAssertTrue(line.contains("total=8.00s"), line)
        XCTAssertTrue(line.contains("engine=0.20s"), line)
    }

    func testItNamesBothReturnSpansAndTheirExecutorWitness() {
        let report = DictationSpeedReport(
            toRecognizedText: .seconds(1),
            toPasteDispatched: nil,
            phases: DictationPhaseBreakdown(
                captureFreeze: .milliseconds(20),
                enginePreparation: nil,
                recognition: .milliseconds(980),
                engineProcessing: .milliseconds(200),
                executorHandover: .milliseconds(10),
                poolReturn: .milliseconds(30),
                mainActorReturn: .milliseconds(740),
                engineDispatch: .milliseconds(40),
                returnFrameWasMainThread: false,
                engineTransport: .milliseconds(780),
                audioDuration: .seconds(3)
            )
        )

        let line = DictationSpeedLine.text(for: report)

        XCTAssertTrue(line.contains("poolreturn=0.03s"), line)
        XCTAssertTrue(line.contains("mainreturn=0.74s"), line)
        XCTAssertTrue(line.contains("enginedispatch=0.04s"), line)
        XCTAssertTrue(line.contains("frame=pool"), line)
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

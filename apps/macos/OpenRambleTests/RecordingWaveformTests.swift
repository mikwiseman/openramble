import XCTest

final class RecordingWaveformTests: XCTestCase {
    func testSilenceStaysVisibleAsAThinCenterLine() {
        XCTAssertEqual(
            RecordingWaveformLayout.barHeight(sample: 0, maximum: 28),
            1,
            accuracy: 0.001
        )
    }

    func testVoiceUsesTheAvailableHeightWithoutEscapingIt() {
        XCTAssertEqual(
            RecordingWaveformLayout.barHeight(sample: 0.25, maximum: 28),
            14.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecordingWaveformLayout.barHeight(sample: 1, maximum: 28),
            28,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RecordingWaveformLayout.barHeight(sample: 4, maximum: 28),
            28,
            accuracy: 0.001
        )
    }
}

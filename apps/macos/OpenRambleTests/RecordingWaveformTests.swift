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

    /// The rolling signal fades toward the past: newest bar fully opaque,
    /// oldest still readable, strictly increasing in between.
    func testBarOpacityRampsFromFadedPastToOpaquePresent() {
        let count = 24
        XCTAssertEqual(
            RecordingWaveformLayout.barOpacity(index: count - 1, count: count),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RecordingWaveformLayout.barOpacity(index: 0, count: count),
            0.35 + 0.65 / Double(count),
            accuracy: 0.0001
        )
        for index in 1..<count {
            XCTAssertGreaterThan(
                RecordingWaveformLayout.barOpacity(index: index, count: count),
                RecordingWaveformLayout.barOpacity(index: index - 1, count: count)
            )
        }
        XCTAssertEqual(RecordingWaveformLayout.barOpacity(index: 0, count: 1), 1.0)
    }
}

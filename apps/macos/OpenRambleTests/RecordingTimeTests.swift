import XCTest

final class RecordingTimeTests: XCTestCase {
    func testClockUnderAnHourIsMinutesAndSeconds() {
        XCTAssertEqual(RecordingTime.clock(0), "0:00")
        XCTAssertEqual(RecordingTime.clock(7.9), "0:07")
        XCTAssertEqual(RecordingTime.clock(65), "1:05")
        XCTAssertEqual(RecordingTime.clock(2_892), "48:12")
    }

    func testClockPastAnHourAddsTheHour() {
        XCTAssertEqual(RecordingTime.clock(3_600), "1:00:00")
        XCTAssertEqual(RecordingTime.clock(5_025), "1:23:45")
    }

    func testNegativeReadsAsZero() {
        XCTAssertEqual(RecordingTime.clock(-3), "0:00")
        XCTAssertEqual(RecordingTime.spoken(-3), "0 seconds")
    }

    func testSpokenFormAgreesWithTheClockAndUsesWords() {
        XCTAssertEqual(RecordingTime.spoken(0), "0 seconds")
        XCTAssertEqual(RecordingTime.spoken(1), "1 second")
        XCTAssertEqual(RecordingTime.spoken(65), "1 minute 5 seconds")
        XCTAssertEqual(RecordingTime.spoken(2_892), "48 minutes 12 seconds")
        XCTAssertEqual(RecordingTime.spoken(3_600), "1 hour")
        XCTAssertEqual(RecordingTime.spoken(5_025), "1 hour 23 minutes 45 seconds")
    }

    func testBriefFormFloorsLikeTheClockSoTheTwoAgree() {
        XCTAssertEqual(RecordingTime.brief(6.5), "6 s")
        XCTAssertEqual(RecordingTime.clock(6.5), "0:06")
        XCTAssertEqual(RecordingTime.brief(42), "42 s")
        XCTAssertEqual(RecordingTime.brief(60), "1 min")
        XCTAssertEqual(RecordingTime.brief(2_892), "48 min")
        XCTAssertEqual(RecordingTime.brief(3_600), "1 h")
        XCTAssertEqual(RecordingTime.brief(5_025), "1 h 23 min")
    }
}

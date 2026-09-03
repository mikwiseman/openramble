import XCTest
@testable import DictationCore

/// Where a block goes: the sample count within a threshold, host time past it.
///
/// The property that matters is the last test — real drift over a real
/// meeting stays bounded. Everything before it is the mechanism that makes
/// that true.
final class ChannelClockTests: XCTestCase {
    func testTheFirstBlockWithoutAClockStartsAtZeroAndTheRestFollowContiguously() {
        var clock = ChannelClock()
        XCTAssertEqual(clock.place(hostFrame: nil, sampleCount: 1024), .contiguous(startFrame: 0))
        XCTAssertEqual(clock.place(hostFrame: nil, sampleCount: 1024), .contiguous(startFrame: 1024))
        XCTAssertEqual(clock.place(hostFrame: nil, sampleCount: 100), .contiguous(startFrame: 2048))
    }

    func testTheFirstBlockWithAClockStartsWhereTheClockSays() {
        var clock = ChannelClock()
        XCTAssertEqual(clock.place(hostFrame: 320, sampleCount: 1024), .contiguous(startFrame: 320))
        XCTAssertEqual(clock.place(hostFrame: 1344, sampleCount: 1024), .contiguous(startFrame: 1344))
    }

    func testJitterWithinTheThresholdIsIgnoredInFavourOfContiguity() {
        var clock = ChannelClock(resyncThresholdFrames: 800)
        _ = clock.place(hostFrame: 0, sampleCount: 1024)
        // The host clock says 1300, the count says 1024: converter jitter,
        // and a seam here would be a 276-frame click for nothing.
        XCTAssertEqual(clock.place(hostFrame: 1300, sampleCount: 1024), .contiguous(startFrame: 1024))
        XCTAssertEqual(clock.place(hostFrame: 1900, sampleCount: 1024), .contiguous(startFrame: 2048))
    }

    func testDriftPastTheThresholdResynchronizesAndReportsTheSkew() {
        var clock = ChannelClock(resyncThresholdFrames: 800)
        _ = clock.place(hostFrame: 0, sampleCount: 1024)
        XCTAssertEqual(
            clock.place(hostFrame: 2000, sampleCount: 1024),
            .resynchronized(startFrame: 2000, skewFrames: 976)
        )
        // And the run continues from the new anchor.
        XCTAssertEqual(clock.place(hostFrame: 3024, sampleCount: 1024), .contiguous(startFrame: 3024))
    }

    func testABlockBeforeTheStartIsClampedToZero() {
        var clock = ChannelClock()
        XCTAssertEqual(clock.place(hostFrame: -500, sampleCount: 1024), .contiguous(startFrame: 0))
    }

    func testResetForgetsTheRunSoAPauseCanReanchor() {
        var clock = ChannelClock()
        _ = clock.place(hostFrame: 0, sampleCount: 1024)
        clock.reset()
        XCTAssertEqual(clock.place(hostFrame: 5000, sampleCount: 1024), .contiguous(startFrame: 5000))
    }

    /// Ninety minutes on a device whose clock runs 100 ppm fast — an ordinary
    /// consumer figure — and then again at ten times that. The placed position
    /// never wanders more than one threshold from the host clock, and the
    /// number of seams stays a handful per hour, not a click per block.
    func testRealisticDriftOverAWholeMeetingStaysBoundedWithFewSeams() {
        for (ppm, maximumSeams) in [(100.0, 30), (1_000.0, 200)] {
            var clock = ChannelClock(resyncThresholdFrames: 800)
            let block = 1024
            let blocks = 90 * 60 * 16_000 / block
            var seams = 0
            var maximumWander = 0
            for i in 0..<blocks {
                // The device delivers `block` samples per block but the host
                // clock advances slightly less: the device is fast.
                let host = Int((Double(i * block) * (1 - ppm / 1_000_000)).rounded())
                let placement = clock.place(hostFrame: host, sampleCount: block)
                if case .resynchronized = placement { seams += 1 }
                maximumWander = max(maximumWander, abs(placement.startFrame - host))
            }
            XCTAssertLessThanOrEqual(maximumWander, 800 + block, "at \(ppm) ppm")
            XCTAssertLessThanOrEqual(seams, maximumSeams, "at \(ppm) ppm")
            XCTAssertGreaterThan(seams, 0, "at \(ppm) ppm the drift has to be corrected at all")
        }
    }
}

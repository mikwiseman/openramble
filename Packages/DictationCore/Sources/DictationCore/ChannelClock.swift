import Foundation

/// Where a block of audio belongs on the recording's timeline.
///
/// Two devices deliver audio with two clocks, and neither is the wall clock.
/// Counting samples is exact within one device and drifts against the other;
/// host time is shared by both and jitters by a few milliseconds per block
/// because converters buffer internally. So this uses both: the host time is
/// the *coarse* anchor, the running sample count is the *fine* position, and
/// the count wins as long as it stays within `resyncThresholdFrames` of the
/// anchor. Past that the block is re-anchored to host time and the skew is
/// reported, so drift becomes an occasional bounded seam rather than an error
/// that grows for ninety minutes.
///
/// Pure: frames in, a placement out. The conversion from host nanoseconds to a
/// frame index happens outside, where the recording's start instant lives.
public struct ChannelClock: Sendable, Equatable {
    public enum Placement: Sendable, Equatable {
        /// Butted against the previous block.
        case contiguous(startFrame: Int)
        /// Moved to where the host clock says it is; `skewFrames` is how far
        /// the sample count had wandered (positive: the device ran slow).
        case resynchronized(startFrame: Int, skewFrames: Int)

        public var startFrame: Int {
            switch self {
            case let .contiguous(startFrame), let .resynchronized(startFrame, _):
                return startFrame
            }
        }
    }

    /// 50 ms at 16 kHz. Below this, converter jitter looks like drift and
    /// every block would be a seam; above it, a resync is a gap a person
    /// could hear. Consumer audio clocks sit near 100 ppm, which reaches this
    /// threshold about every eight minutes.
    public static let defaultResyncThresholdFrames = 800

    public let resyncThresholdFrames: Int
    private var expectedNext: Int?

    public init(resyncThresholdFrames: Int = ChannelClock.defaultResyncThresholdFrames) {
        self.resyncThresholdFrames = resyncThresholdFrames
    }

    /// Place a block. `hostFrame` is where the host clock says it starts, or
    /// `nil` when the source had no valid timestamp.
    public mutating func place(hostFrame: Int?, sampleCount: Int) -> Placement {
        let placement: Placement
        switch (hostFrame, expectedNext) {
        case (nil, nil):
            placement = .contiguous(startFrame: 0)
        case (nil, let expected?):
            placement = .contiguous(startFrame: expected)
        case (let host?, nil):
            placement = .contiguous(startFrame: max(0, host))
        case (let host?, let expected?):
            let skew = host - expected
            if abs(skew) > resyncThresholdFrames {
                placement = .resynchronized(startFrame: max(0, host), skewFrames: skew)
            } else {
                placement = .contiguous(startFrame: expected)
            }
        }
        expectedNext = placement.startFrame + sampleCount
        return placement
    }

    /// Forget the running position — after a pause, the next block starts a
    /// new run against a re-anchored clock.
    public mutating func reset() {
        expectedNext = nil
    }
}

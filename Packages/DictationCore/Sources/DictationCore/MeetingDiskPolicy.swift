import Foundation

/// When a recording may start, and when it must stop, for want of disk.
///
/// Stereo 16 kHz 16-bit is 64 kB/s: 230 MB an hour. The floor to start is
/// enough for two hours; the floor to stop leaves the rest of the Mac room
/// to keep working, and a recording that stops cleanly at 41:12 with a
/// sentence saying so is worth more than one that dies at 41:13 with a
/// truncated file.
public enum MeetingDiskPolicy {
    public static let bytesPerSecond = 64_000
    public static let minimumFreeBytesToStart: Int64 = 500 * 1_024 * 1_024
    public static let warnBelowFreeBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let stopBelowFreeBytes: Int64 = 200 * 1_024 * 1_024
    /// How often, in recorded frames, to look at the disk while recording.
    public static let checkEveryFrames = 60 * 16_000

    public enum Verdict: Sendable, Equatable {
        case ok
        case low(minutesLeft: Int)
        case tooLowToStart
    }

    public static func verdictToStart(freeBytes: Int64) -> Verdict {
        if freeBytes < minimumFreeBytesToStart { return .tooLowToStart }
        if freeBytes < warnBelowFreeBytes {
            return .low(minutesLeft: Int(freeBytes / Int64(bytesPerSecond) / 60))
        }
        return .ok
    }

    public static func mustStop(freeBytes: Int64) -> Bool {
        freeBytes < stopBelowFreeBytes
    }
}

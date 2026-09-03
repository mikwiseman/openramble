import Foundation

/// Two independently timed streams, made into one stereo timeline.
///
/// The output is strictly monotonic and append-only: frame N of the microphone
/// and frame N of the system side are the same instant, and nothing written is
/// ever rewritten. That is what lets the file be a WAV that grows on disk and
/// lets a transcript refer to a frame range and mean it.
///
/// Rules, each of which a test pins:
/// - A block that lands before the write cursor is truncated there and the
///   dropped frames are counted. Late audio does not move the past.
/// - A channel with nothing pending for a stretch is filled with silence on
///   that channel only, and the gap is counted — the other channel is not
///   held up. **One dead channel never blocks the file.**
/// - Emission lags the newest frame seen by `jitterFrames`, so a slightly
///   late block from the other channel still lands in place.
/// - A channel that is not active (a voice note has no system side) is
///   written as silence without being counted as a gap: it is not missing,
///   it was never asked for.
///
/// Pure. The clock that turns host time into frames is `ChannelClock`.
public struct DualChannelAligner: Sendable {
    public struct Emission: Sendable, Equatable {
        public let startFrame: Int
        public let microphone: [Float]
        public let system: [Float]

        public var frameCount: Int { microphone.count }
    }

    /// 320 ms at 16 kHz: 41 kB of buffer, and more than the scheduling
    /// jitter of either source on a busy Mac.
    public static let defaultJitterFrames = 5_120

    public let jitterFrames: Int
    public let activeChannels: Set<MeetingChannel>

    private struct Block: Sendable {
        var start: Int
        var samples: [Float]
        var end: Int { start + samples.count }
    }

    private var pending: [MeetingChannel: [Block]] = [:]
    /// The write cursor: the next frame to emit.
    public private(set) var emittedFrames = 0
    private var newestFrameSeen = 0
    /// Frames filled with silence because an active channel had nothing.
    public private(set) var gapFrames: [MeetingChannel: Int] = [:]
    /// Frames thrown away because they arrived behind the cursor.
    public private(set) var droppedLateFrames: [MeetingChannel: Int] = [:]

    public init(
        activeChannels: Set<MeetingChannel> = Set(MeetingChannel.allCases),
        jitterFrames: Int = DualChannelAligner.defaultJitterFrames
    ) {
        self.activeChannels = activeChannels
        self.jitterFrames = jitterFrames
    }

    public mutating func ingest(channel: MeetingChannel, startFrame: Int, samples: [Float]) {
        var block = Block(start: startFrame, samples: samples)
        if block.start < emittedFrames {
            let late = min(block.samples.count, emittedFrames - block.start)
            droppedLateFrames[channel, default: 0] += late
            block.samples.removeFirst(late)
            block.start = emittedFrames
        }
        guard !block.samples.isEmpty else { return }

        var blocks = pending[channel] ?? []
        // Sources deliver in order, so this is an append; the search keeps it
        // correct if one ever does not.
        let index = blocks.firstIndex { $0.start > block.start } ?? blocks.endIndex
        blocks.insert(block, at: index)
        pending[channel] = blocks
        newestFrameSeen = max(newestFrameSeen, block.end)
    }

    /// Everything that is old enough to be certain about.
    public mutating func drain() -> Emission? {
        emit(upTo: newestFrameSeen - jitterFrames)
    }

    /// Everything, jitter or not — the recording is ending.
    public mutating func flush() -> Emission? {
        emit(upTo: newestFrameSeen)
    }

    private mutating func emit(upTo target: Int) -> Emission? {
        guard target > emittedFrames else { return nil }
        let count = target - emittedFrames
        let microphone = take(.microphone, from: emittedFrames, count: count)
        let system = take(.system, from: emittedFrames, count: count)
        let emission = Emission(startFrame: emittedFrames, microphone: microphone, system: system)
        emittedFrames = target
        return emission
    }

    private mutating func take(_ channel: MeetingChannel, from base: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard activeChannels.contains(channel) else { return out }

        var covered = 0
        var remaining: [Block] = []
        for block in pending[channel] ?? [] {
            if block.end <= base { continue }
            if block.start >= base + count {
                remaining.append(block)
                continue
            }
            let from = max(block.start, base)
            let to = min(block.end, base + count)
            let length = to - from
            let sourceOffset = from - block.start
            let destinationOffset = from - base
            for i in 0..<length {
                out[destinationOffset + i] = block.samples[sourceOffset + i]
            }
            covered += length
            if block.end > base + count {
                let keepFrom = base + count - block.start
                remaining.append(Block(start: base + count, samples: Array(block.samples[keepFrom...])))
            }
        }
        pending[channel] = remaining
        gapFrames[channel, default: 0] += max(0, count - covered)
        return out
    }
}

import DictationCore
import Foundation

/// Reads one channel of one stretch of `audio.wav`, straight from the bytes.
///
/// Deliberately not `AVAudioFile`. While a recording runs, the WAV header
/// still says zero bytes of audio and `AVAudioFile` believes it; the frames
/// after the header are there regardless, and reading them at a computed
/// offset is coherent through the buffer cache without an `fsync`.
/// `WAVWriter`'s lock is advisory and this takes none, so there is nothing
/// to contend with.
///
/// Frame `F` of a 44-byte-header stereo 16-bit WAV lives at byte `44 + 4F`.
public struct MeetingPCMWindowReader: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case cannotOpen(String)
        case shortRead(expectedBytes: Int, gotBytes: Int)
        case unknownChannel
    }

    public static let headerBytes = 44

    public let url: URL
    public let channelLayout: [MeetingChannel]

    public init(url: URL, channelLayout: [MeetingChannel] = [.microphone, .system]) {
        self.url = url
        self.channelLayout = channelLayout
    }

    public func read(_ segment: MeetingSegmentRef) throws -> [Float] {
        try read(channel: segment.channel, startFrame: segment.startFrame, frameCount: segment.frameCount)
    }

    public func read(channel: MeetingChannel, startFrame: Int, frameCount: Int) throws -> [Float] {
        guard let index = channelLayout.firstIndex(of: channel) else { throw Failure.unknownChannel }
        guard frameCount > 0 else { return [] }
        let channels = channelLayout.count
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.cannotOpen(url.path) }
        defer { Darwin.close(descriptor) }

        let bytes = frameCount * channels * MemoryLayout<Int16>.size
        var interleaved = [Int16](repeating: 0, count: frameCount * channels)
        let got = interleaved.withUnsafeMutableBytes { buffer in
            Darwin.pread(
                descriptor,
                buffer.baseAddress,
                bytes,
                off_t(Self.headerBytes + startFrame * channels * MemoryLayout<Int16>.size)
            )
        }
        guard got == bytes else { throw Failure.shortRead(expectedBytes: bytes, gotBytes: max(0, got)) }

        var samples = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            samples[frame] = Float(Int16(littleEndian: interleaved[frame * channels + index])) / 32_768
        }
        return samples
    }
}

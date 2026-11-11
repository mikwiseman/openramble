import Foundation

/// Where a whole file is cut for the engine, fed as the file is read.
///
/// The same cuts `FileTranscriber` decodes by: silence left out, each piece
/// at most `seconds` long, and a file of thirty seconds or less in one piece.
/// A caller that keeps the audio somewhere of its own, as the Library does
/// with an imported file, pushes the samples it stores and asks for the
/// pieces at the end, so the file is read once.
public struct FilePiecePlanner: Sendable {
    public static let sampleRate = 16_000
    /// The longest piece, in seconds: what the Linux server sends its engine.
    public static let defaultSeconds = 20
    /// A file this short goes to the engine whole.
    static let wholeSeconds = 30.0

    private var envelope = LoudnessEnvelope()
    private var total = 0
    private let seconds: Int

    public init(seconds: Int = FilePiecePlanner.defaultSeconds) {
        precondition((15...60).contains(seconds))
        self.seconds = seconds
    }

    /// Mono samples at 16 kHz, in order.
    public mutating func push(_ samples: [Float]) {
        for sample in samples { envelope.push(sample) }
        total += samples.count
    }

    /// The pieces, as sample ranges: in order, never overlapping.
    public mutating func finish() -> [Range<Int>] {
        guard total > 0 else { return [] }
        if Double(total) / Double(Self.sampleRate) <= Self.wholeSeconds { return [0..<total] }
        return PiecePlan.pieces(envelope.finish(), samples: total, cap: Float(seconds))
    }
}

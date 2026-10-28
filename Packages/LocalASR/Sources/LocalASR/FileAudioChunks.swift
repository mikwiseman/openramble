import DictationCore
import Foundation

struct FileAudioChunk: Sendable {
    let samples: [Float]
    let startFrame: Int
    let endFrame: Int
}

/// An imported file in the pieces the Linux server would send its engine
/// (`apps/cli/src/plan.rs`): silence left out, every piece at most
/// `seconds` long, no overlap. A plan needs the whole file's loudness, so a
/// file is read twice, never held whole.
///
/// The rule replaced a pause policy with a fixed speech level and 2 s of
/// shared context at each seam. Imported files have no known gain, so that
/// level read quiet speech as a pause and cut inside clauses, which Parakeet
/// Ultra then dropped; and the shared context pulled a mixed-language piece
/// toward its neighbour's language. On the hour test files the planner lost
/// no English or Russian words and half as many on the mixed files (H16f in
/// `research/model-upgrade-2026-10`).
actor FileAudioChunks {
    nonisolated let duration: Double
    private let url: URL?
    private var stream: AudioFileStream?
    private let samples: [Float]?
    private(set) var readSeconds = 0.0
    private let whole: Bool
    private let seconds: Int
    private var pieces: [Range<Int>]?
    private var pending: [Float] = []
    private var pendingStart = 0
    private var ended = false

    /// The server's piece length. Pieces this short also never reach the
    /// long-form segmenter Parakeet Ultra runs past 30 s.
    static let defaultSeconds = 20

    init(url: URL, seconds: Int = defaultSeconds) async throws {
        let stream = try await AudioFileStream(url: url)
        self.url = url
        self.stream = stream
        samples = nil
        duration = stream.duration
        whole = duration <= 30
        self.seconds = seconds
    }

    init(samples: [Float], seconds: Int = defaultSeconds) {
        url = nil
        stream = nil
        self.samples = samples
        duration = Double(samples.count) / 16_000
        whole = duration <= 30
        self.seconds = seconds
    }

    private func read(from stream: AudioFileStream, frames: Int = 16_384) async throws -> [Float] {
        let start = ContinuousClock.now
        defer {
            let duration = start.duration(to: .now)
            readSeconds += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        return try await stream.read(frames: frames)
    }

    func next() async throws -> FileAudioChunk? {
        try Task.checkCancellation()
        if whole {
            guard !ended else { return nil }
            ended = true
            var all = samples ?? []
            if let stream {
                while true {
                    let part = try await read(from: stream)
                    if part.isEmpty { break }
                    all.append(contentsOf: part)
                }
            }
            return FileAudioChunk(samples: all, startFrame: 0, endFrame: all.count)
        }
        if pieces == nil { pieces = try await plan() }
        guard let piece = pieces?.first else { return nil }
        pieces?.removeFirst()
        if let samples {
            return FileAudioChunk(samples: Array(samples[piece]), startFrame: piece.lowerBound, endFrame: piece.upperBound)
        }
        while pendingStart + pending.count < piece.upperBound, !ended, let stream {
            let part = try await read(from: stream, frames: 16_000)
            if part.isEmpty { ended = true } else { pending.append(contentsOf: part) }
        }
        // Gaps between pieces are the silence the plan leaves out.
        let skip = min(pending.count, max(0, piece.lowerBound - pendingStart))
        pending.removeFirst(skip)
        pendingStart += skip
        let take = min(pending.count, piece.upperBound - pendingStart)
        let chunk = Array(pending[..<take])
        pending.removeFirst(take)
        pendingStart += take
        return FileAudioChunk(samples: chunk, startFrame: piece.lowerBound, endFrame: piece.lowerBound + take)
    }

    /// The first pass: the loudness of the whole file, then a fresh stream
    /// for the second.
    private func plan() async throws -> [Range<Int>] {
        var envelope = LoudnessEnvelope()
        var total = 0
        if let samples {
            for sample in samples { envelope.push(sample) }
            total = samples.count
        } else if let stream, let url {
            while true {
                try Task.checkCancellation()
                let part = try await read(from: stream)
                if part.isEmpty { break }
                for sample in part { envelope.push(sample) }
                total += part.count
            }
            self.stream = try await AudioFileStream(url: url)
        }
        return PiecePlan.pieces(envelope.finish(), samples: total, cap: Float(seconds))
    }
}

/// The server's loudness envelope (`apps/cli/src/decode.rs`): the RMS of
/// each 20 ms after a second-order Butterworth high-pass at 100 Hz, so rumble,
/// hum and the swell of pink noise do not count as loudness.
struct LoudnessEnvelope {
    private var frames: [Float] = []
    private var sum: Float = 0
    private var count = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func push(_ sample: Float) {
        let high: Float = 0.972_613_9 * (sample - 2 * x1 + x2) + 1.944_477_7 * y1 - 0.945_978 * y2
        x2 = x1
        x1 = sample
        y2 = y1
        y1 = high
        sum += high * high
        count += 1
        if count == PiecePlan.frame { close() }
    }

    private mutating func close() {
        frames.append((sum / Float(count)).squareRoot())
        sum = 0
        count = 0
    }

    /// The frames, the last one possibly shorter than 20 ms.
    mutating func finish() -> [Float] {
        if count > 0 { close() }
        return frames
    }
}

/// `apps/cli/src/plan.rs`, kept in step with it: both test suites pin the
/// same cut positions. Pure, on 20 ms frames.
///
/// 1. Skip silence. The floor of each second is the 10th-percentile frame of
///    the minute around it (never below -80 dBFS), and a frame 6 dB above it
///    is voiced. Voiced frames under 2 s apart form an island, an island with
///    under 0.1 s of voiced frames is a click, and each kept island gets 1 s
///    of audio on either side. A quiet speaker counts as long as they stand
///    clear of their own floor.
/// 2. Cut at pauses. A longer region becomes `ceil(d / (0.8 × cap))` nearly
///    equal pieces, and each cut moves to the quietest 200 ms within
///    `min(2.5 s, (cap - d/n) / 2)` of the even split, so no piece is longer
///    than the cap.
enum PiecePlan {
    static let frame = 320
    static let framesPerSecond = 50
    private static let margin: Float = 2
    private static let near = 60 * framesPerSecond
    private static let lowestFloor: Float = 1e-4
    private static let pad = framesPerSecond
    private static let mergeGap = 2 * framesPerSecond
    private static let minVoiced = framesPerSecond / 10
    private static let smooth = 5
    private static let maxShift = framesPerSecond * 5 / 2
    private static let target = 0.8

    /// The pieces of a whole file, in samples.
    static func pieces(_ envelope: [Float], samples: Int, cap: Float) -> [Range<Int>] {
        let frames = 0..<((samples + frame - 1) / frame)
        return plan(envelope, span: frames, cap: cap, gate: true).compactMap { piece in
            let end = min(piece.upperBound * frame, samples)
            return piece.lowerBound * frame < end ? piece.lowerBound * frame..<end : nil
        }
    }

    /// The pieces of `span`, in frames of `envelope`, in order and never
    /// overlapping, each at most `cap` seconds. Without the gate the whole
    /// span is covered.
    static func plan(_ envelope: [Float], span: Range<Int>, cap: Float, gate: Bool) -> [Range<Int>] {
        let span = min(span.lowerBound, envelope.count)..<min(span.upperBound, envelope.count)
        if span.isEmpty { return [] }
        let regions = gate ? voicedRegions(envelope, span) : [span]
        let capFrames = max(Int(cap * Float(framesPerSecond)), 1)
        return regions.flatMap { cut(envelope, $0, capFrames) }
    }

    private static func threshold(_ envelope: [Float], second: Int) -> Float {
        let centre = second * framesPerSecond + framesPerSecond / 2
        let sorted = envelope[max(0, centre - near / 2)..<min(centre + near / 2, envelope.count)].sorted()
        return max(sorted[sorted.count / 10], lowestFloor) * margin
    }

    private static func voicedRegions(_ envelope: [Float], _ span: Range<Int>) -> [Range<Int>] {
        var threshold: Float = 0
        var islands: [(start: Int, end: Int, voiced: Int)] = []
        for frame in span {
            if frame == span.lowerBound || frame % framesPerSecond == 0 {
                threshold = Self.threshold(envelope, second: frame / framesPerSecond)
            }
            if envelope[frame] <= threshold { continue }
            if let last = islands.last, frame - last.end < mergeGap {
                islands[islands.count - 1] = (last.start, frame + 1, last.voiced + 1)
            } else {
                islands.append((frame, frame + 1, 1))
            }
        }
        var regions: [Range<Int>] = []
        for island in islands where island.voiced >= minVoiced {
            let padded = max(island.start - pad, span.lowerBound)..<min(island.end + pad, span.upperBound)
            if let last = regions.last, padded.lowerBound <= last.upperBound {
                regions[regions.count - 1] = last.lowerBound..<max(last.upperBound, padded.upperBound)
            } else {
                regions.append(padded)
            }
        }
        return regions
    }

    private static func cut(_ envelope: [Float], _ region: Range<Int>, _ cap: Int) -> [Range<Int>] {
        let length = region.count
        if length <= cap { return [region] }
        let n = Int((Double(length) / (target * Double(cap))).rounded(.up))
        let longestEven = (length + n - 1) / n
        let reach = min(maxShift, max(0, cap - longestEven) / 2)
        func loudness(_ frame: Int) -> Float {
            envelope[max(frame - smooth, region.lowerBound)..<min(frame + smooth + 1, region.upperBound)].reduce(0, +)
        }
        var pieces: [Range<Int>] = []
        var start = region.lowerBound
        for k in 1..<n {
            let even = region.lowerBound + k * length / n
            let from = max(even - reach, start + 1)
            let to = min(even + reach, region.upperBound - 1)
            // The quietest frame, then the one nearest the even split, then the earlier.
            let at = from <= to ? (from...to).min {
                (loudness($0), abs($0 - even), $0) < (loudness($1), abs($1 - even), $1)
            } ?? even : even
            pieces.append(start..<at)
            start = at
        }
        pieces.append(start..<region.upperBound)
        return pieces
    }
}

/// Pieces never overlap, so joining is appending: every word moves by its
/// piece's start in the file.
struct TimedTranscriptJoiner {
    private(set) var words: [ASRResult.Word] = []

    mutating func append(_ result: ASRResult, chunk: FileAudioChunk, duration: Double) throws {
        guard result.text.isEmpty || !result.words.isEmpty else {
            throw ASREngineError.inferenceFailed("the engine returned text without requested word timings")
        }
        let offset = Double(chunk.startFrame) / 16_000
        // Alignment jitter must not produce reversed intervals at a join.
        var previous = words.last?.start ?? 0
        for word in result.words {
            let start = max(previous, min(duration, offset + word.start))
            words.append(ASRResult.Word(text: word.text, start: start,
                                        end: max(start, min(duration, offset + word.end)), confidence: word.confidence))
            previous = start
        }
    }
}

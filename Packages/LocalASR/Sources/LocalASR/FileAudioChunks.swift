import DictationCore
import Foundation

struct FileAudioChunk: Sendable {
    let samples: [Float]
    let startFrame: Int
    let boundaryFrame: Int
    let endFrame: Int
}

/// Reuses the recording pause policy, with context on both sides of a seam.
/// Keeps at most one segment plus overlap and one second of read-ahead.
actor FileAudioChunks {
    nonisolated let duration: Double
    private let stream: AudioFileStream
    private var policy: MeetingSegmentPolicy
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var observed = 0
    private var ready: [MeetingSegmentRef] = []
    private var ended = false
    private let whole: Bool
    private let overlap = 2 * 16_000

    init(url: URL, seconds: Int = 30) async throws {
        stream = try await AudioFileStream(url: url)
        duration = stream.duration
        whole = duration <= 30
        policy = MeetingSegmentPolicy(channel: .microphone, parameters: .init(
            speech: .init(minimumSegment: .seconds(15), relaxAfter: .seconds(seconds)),
            hardCap: .seconds(seconds), forcedCutWindow: .seconds(1), preserveQuietAudio: true
        ))
    }

    func next() async throws -> FileAudioChunk? {
        if whole {
            guard !ended else { return nil }
            while true {
                let part = try await stream.read()
                if part.isEmpty { break }
                buffer.append(contentsOf: part)
            }
            ended = true
            return FileAudioChunk(samples: buffer, startFrame: 0, boundaryFrame: 0, endFrame: buffer.count)
        }
        while true {
            // Keep a just-cut segment until its right context is available.
            // At EOF this also lets a <2 s tail merge into that segment.
            if let first = ready.first, ended || observed >= first.endFrame + overlap {
                ready.removeFirst()
                let start = max(bufferStart, first.startFrame - overlap)
                let end = min(observed, first.endFrame + overlap)
                let chunk = FileAudioChunk(samples: Array(buffer[(start - bufferStart)..<(end - bufferStart)]),
                    startFrame: start, boundaryFrame: first.startFrame, endFrame: first.endFrame)
                trim()
                // Skip digital silence only, never quiet speech.
                if chunk.samples.allSatisfy({ $0 == 0 }) { continue }
                return chunk
            }
            if ended { return nil }
            let part = try await stream.read(frames: 16_000)
            if part.isEmpty {
                ended = true
                if let tail = policy.flush() {
                    if tail.frameCount < overlap, let previous = ready.last {
                        ready[ready.count - 1] = MeetingSegmentRef(channel: .microphone,
                            startFrame: previous.startFrame, frameCount: tail.endFrame - previous.startFrame)
                    } else {
                        ready.append(tail)
                    }
                }
            } else {
                buffer.append(contentsOf: part)
                for offset in stride(from: 0, to: part.count, by: 320) {
                    let frame = part[offset..<min(part.count, offset + 320)]
                    observed += frame.count
                    if let ref = policy.observe(peak: frame.reduce(0) { max($0, abs($1)) }, count: frame.count) {
                        ready.append(ref)
                    }
                }
                trim()
            }
        }
    }

    private func trim() {
        let nextStart = ready.first?.startFrame ?? (observed - policy.pendingFrames)
        let keepFrom = max(bufferStart, nextStart - overlap)
        let count = min(buffer.count, keepFrom - bufferStart)
        if count > 0 {
            buffer.removeFirst(count)
            bufferStart += count
        }
    }
}

/// Match words only inside the shared audio interval. Repeated words elsewhere
/// in a conversation are never deduplicated. Without a confident match, the
/// pause/quiet-frame boundary decides ownership by each word's midpoint.
struct TimedTranscriptJoiner {
    private(set) var words: [ASRResult.Word] = []

    mutating func append(_ result: ASRResult, chunk: FileAudioChunk, duration: Double) throws {
        guard result.text.isEmpty || !result.words.isEmpty else {
            throw ASREngineError.inferenceFailed("the engine returned text without requested word timings")
        }
        let offset = Double(chunk.startFrame) / 16_000
        let boundary = Double(chunk.boundaryFrame) / 16_000
        let incoming = result.words.map {
            ASRResult.Word(text: $0.text, start: min(duration, offset + $0.start),
                           end: min(duration, offset + $0.end), confidence: $0.confidence)
        }
        if words.isEmpty { words = incoming; return }
        let previousStart = words.firstIndex { $0.end >= offset } ?? words.count
        var match: (old: Int, new: Int, distance: Double)?
        if incoming.count >= 2, words.count >= 2 {
            for old in previousStart..<max(previousStart, words.count - 1) {
                for new in 0..<(incoming.count - 1) {
                    guard incoming[new].start <= boundary + 2,
                          abs(words[old].start - incoming[new].start) < 0.6,
                          Self.key(words[old].text) == Self.key(incoming[new].text),
                          !Self.key(words[old].text).isEmpty,
                          Self.key(words[old + 1].text) == Self.key(incoming[new + 1].text) else { continue }
                    let distance = abs(incoming[new].start - boundary)
                    if match == nil || distance < match!.distance { match = (old, new, distance) }
                }
            }
        }
        if let match {
            words = Array(words.prefix(match.old + 1)) + incoming.dropFirst(match.new + 1)
        } else {
            words = words.filter { ($0.start + $0.end) / 2 < boundary }
                + incoming.filter { ($0.start + $0.end) / 2 >= boundary }
        }
        // Alignment jitter must not produce reversed intervals at the splice.
        var previous = 0.0
        words = words.map { word in
            let start = max(previous, word.start)
            previous = start
            return ASRResult.Word(text: word.text, start: start, end: max(start, word.end), confidence: word.confidence)
        }
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

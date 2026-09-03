import Foundation

/// Where a long recording may be cut for the engine — `SpeechSegmenter` with
/// a ceiling.
///
/// The segmenter's one rule stands: a cut lands inside silence, never through
/// speech. For a dictation that is the whole story; a person who does not
/// pause simply produces one long take. A meeting cannot afford that ending.
/// Decode cost on this model is quadratic in segment length — measured, 60 s
/// costs 1.53 s and 140 s costs 5.64 s — and the segment is what every
/// dictation would have to wait behind. So past `hardCap` a cut is forced
/// anyway, at the quietest frame in the last second, which is the least bad
/// place inside continuous speech: between words far more often than inside
/// one.
///
/// Positions are absolute frames in the file, so what comes out is a
/// `MeetingSegmentRef` that reads straight from the WAV. Pure.
public struct MeetingSegmentPolicy: Sendable {
    public struct Parameters: Sendable, Equatable {
        public var speech: SpeechSegmenter.Parameters
        /// The longest segment ever handed to the engine.
        public var hardCap: Duration
        /// How far back to look for the quietest frame when forcing a cut.
        public var forcedCutWindow: Duration

        /// Shorter segments than dictation's, deliberately. Text appears
        /// sooner, and the worst wait a dictation can inherit from a decode
        /// already running — 20 s at RTF 0.11 — stays near two seconds.
        public static let meeting = Parameters(
            speech: SpeechSegmenter.Parameters(minimumSegment: .seconds(10)),
            hardCap: .seconds(20),
            forcedCutWindow: .seconds(1)
        )

        public init(
            speech: SpeechSegmenter.Parameters = SpeechSegmenter.Parameters(),
            hardCap: Duration = .seconds(20),
            forcedCutWindow: Duration = .seconds(1)
        ) {
            self.speech = speech
            self.hardCap = hardCap
            self.forcedCutWindow = forcedCutWindow
        }
    }

    private struct Frame: Sendable {
        let peak: Float
        let count: Int
    }

    public let channel: MeetingChannel
    public let parameters: Parameters
    private let sampleRate: Int
    private var segmenter: SpeechSegmenter
    private var segmentStart: Int
    private var end: Int
    private var heardSpeech = false
    private var recent: [Frame] = []
    private var recentFrames = 0

    public init(
        channel: MeetingChannel,
        parameters: Parameters = .meeting,
        sampleRate: Int = 16_000,
        startFrame: Int = 0
    ) {
        self.channel = channel
        self.parameters = parameters
        self.sampleRate = sampleRate
        segmenter = SpeechSegmenter(parameters: parameters.speech, sampleRate: sampleRate)
        segmentStart = startFrame
        end = startFrame
    }

    private func frames(_ duration: Duration) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return Int(seconds * Double(sampleRate))
    }

    /// Audio waiting since the last cut.
    public var pendingFrames: Int { end - segmentStart }

    /// How much silence a segment may begin with. Enough to spare the decode
    /// a hard edge against the first word; not an hour of the other side
    /// saying nothing, which would otherwise be the first thing decoded when
    /// they finally spoke.
    static let leadingSilence: Duration = .seconds(1)

    /// Feed one frame of written audio. Returns the segment it completed, if
    /// this frame completed one.
    public mutating func observe(peak: Float, count: Int) -> MeetingSegmentRef? {
        end += count
        if peak >= parameters.speech.speechPeak { heardSpeech = true }
        remember(Frame(peak: peak, count: count))

        // Silence before the first word is not part of any segment. Let the
        // start slide forward so a quiet channel never accumulates.
        if !heardSpeech, pendingFrames > frames(Self.leadingSilence) {
            segmentStart = end - frames(Self.leadingSilence)
            segmenter.reset()
            return nil
        }

        if let cut = segmenter.observe(peak: peak, count: count) {
            let segment = MeetingSegmentRef(channel: channel, startFrame: segmentStart, frameCount: cut)
            segmentStart += cut
            // What remains is the second half of the pause that earned the
            // cut: silence, and not yet a segment.
            heardSpeech = false
            recent = []
            recentFrames = 0
            return segment
        }

        guard heardSpeech, pendingFrames >= frames(parameters.hardCap), !recent.isEmpty else { return nil }
        return forceCut()
    }

    /// The tail, at the end of a recording or before a pause — if anyone said
    /// anything in it. Silence alone is not worth a decode.
    public mutating func flush() -> MeetingSegmentRef? {
        defer {
            segmentStart = end
            segmenter.reset()
            heardSpeech = false
            recent = []
            recentFrames = 0
        }
        guard heardSpeech, end > segmentStart else { return nil }
        return MeetingSegmentRef(channel: channel, startFrame: segmentStart, frameCount: end - segmentStart)
    }

    private mutating func remember(_ frame: Frame) {
        recent.append(frame)
        recentFrames += frame.count
        let window = frames(parameters.forcedCutWindow)
        while recent.count > 1, recentFrames - recent[0].count >= window {
            recentFrames -= recent.removeFirst().count
        }
    }

    /// Cut at the end of the quietest recent frame, then feed the frames after
    /// it back to a fresh segmenter so the remainder is accounted for exactly.
    private mutating func forceCut() -> MeetingSegmentRef {
        // Ties go to the newest frame: with nothing to choose between, cut as
        // close to the cap as possible and keep the segment long.
        var quietest = 0
        for index in recent.indices where recent[index].peak <= recent[quietest].peak {
            quietest = index
        }
        let after = Array(recent[(quietest + 1)...])
        let remainder = after.reduce(0) { $0 + $1.count }
        let cutFrame = end - remainder
        let segment = MeetingSegmentRef(channel: channel, startFrame: segmentStart, frameCount: cutFrame - segmentStart)

        segmentStart = cutFrame
        segmenter.reset()
        heardSpeech = false
        recent = []
        recentFrames = 0
        for frame in after {
            _ = segmenter.observe(peak: frame.peak, count: frame.count)
            if frame.peak >= parameters.speech.speechPeak { heardSpeech = true }
            remember(frame)
        }
        return segment
    }
}

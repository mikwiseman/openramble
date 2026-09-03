import Foundation

/// Keeps the other side's words out of the person's own paragraphs.
///
/// Without headphones, what the Mac plays reaches the microphone — measured
/// on a laptop at high volume: at roughly half the tapped level, about 30 ms
/// later. That is loud enough to clear the segmenter's speech floor, so a
/// remote sentence would be decoded twice and once attributed to You.
///
/// Loudness alone cannot tell the two apart: the ratio hovered around two
/// and dipped below it within the same sentence. Shape can. Microphone audio
/// that is a delayed copy of the system audio correlates with it — 0.4 to
/// 0.6 at the right lag against nothing at the others, in the same
/// measurement — while the person's own voice does not.
///
/// Two things about the segmenter shape the rest. It never sees samples,
/// only a peak per block, and blocks are whatever the sources deliver —
/// often a few milliseconds, far too short for a stable estimate. And a
/// single block that slips through becomes a segment whose audio is read
/// back from the file, so the whole sentence returns. Decisions are
/// therefore made over a rolling window, and a positive decision outlasts
/// its evidence long enough to cover the gaps between words and the room's
/// tail. Nothing is removed from the file.
///
/// The person talking *over* the other side on speakers is the one case
/// this cannot resolve: their own voice plus the echo may still correlate,
/// and those words go unattributed. Headphones fix that; the UI says so.
public struct CrossTalkGate: Sendable, Equatable {
    public struct Parameters: Sendable, Equatable {
        /// Below this the system side is ambient noise, not a source of echo.
        public var activationRMS: Float
        /// Normalised correlation at or above which the window is an echo.
        public var echoCorrelation: Float
        /// The longest delay searched, in frames. 100 ms at 16 kHz covers the
        /// acoustic path plus both audio pipelines with room to spare.
        public var maximumLagFrames: Int
        /// Lag resolution. 2 ms: finer buys nothing, coarser can miss the peak.
        public var lagStepFrames: Int
        /// How much recent audio a decision looks at. 320 ms is long enough
        /// for a stable estimate and short enough to notice the person
        /// starting to talk.
        public var windowFrames: Int
        /// How often a fresh decision is made. The correlation is the
        /// expensive part, and echo does not come and go faster than this.
        public var decisionFrames: Int
        /// How long a decision outlasts its evidence, on top of the window's
        /// own memory: about 600 ms after the other side stops, which covers
        /// the gaps between words and the room's tail. The person's first
        /// words inside it are not lost — a segment carries up to a second of
        /// what precedes its first speech.
        public var holdFrames: Int

        public init(
            activationRMS: Float = 0.005,
            echoCorrelation: Float = 0.25,
            maximumLagFrames: Int = 1_600,
            lagStepFrames: Int = 32,
            windowFrames: Int = 5_120,
            decisionFrames: Int = 1_600,
            holdFrames: Int = 4_800
        ) {
            self.activationRMS = activationRMS
            self.echoCorrelation = echoCorrelation
            self.maximumLagFrames = maximumLagFrames
            self.lagStepFrames = lagStepFrames
            self.windowFrames = windowFrames
            self.decisionFrames = decisionFrames
            self.holdFrames = holdFrames
        }
    }

    public struct Verdict: Sendable, Equatable {
        public let isEcho: Bool
        /// The delay at which the last decision found its match, when it did.
        public let lagFrames: Int?
        public let correlation: Float
    }

    public let parameters: Parameters
    private var microphoneWindow: [Float] = []
    /// Longer than the microphone window by the lag room, so an echo of
    /// audio that played just before the window can still be matched.
    private var systemWindow: [Float] = []
    private var framesSinceDecision: Int?
    private var lastMatch: (lag: Int?, correlation: Float) = (nil, 0)
    private var holdRemaining = 0

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    public static func == (lhs: CrossTalkGate, rhs: CrossTalkGate) -> Bool {
        lhs.parameters == rhs.parameters
            && lhs.microphoneWindow == rhs.microphoneWindow
            && lhs.systemWindow == rhs.systemWindow
            && lhs.holdRemaining == rhs.holdRemaining
    }

    /// Whether this microphone block is the speakers rather than the person.
    /// Blocks must arrive in file order; the recent past is remembered.
    public mutating func classify(microphone: [Float], system: [Float]) -> Verdict {
        guard !microphone.isEmpty, microphone.count == system.count else {
            return Verdict(isEcho: false, lagFrames: nil, correlation: 0)
        }
        microphoneWindow = Array((microphoneWindow + microphone).suffix(parameters.windowFrames))
        systemWindow = Array((systemWindow + system).suffix(parameters.windowFrames + parameters.maximumLagFrames))
        holdRemaining = max(0, holdRemaining - microphone.count)

        let systemRMS = Self.rms(systemWindow.suffix(microphoneWindow.count))
        let systemIsActive = systemRMS >= parameters.activationRMS

        // Until a decision's worth of context exists, an active system side
        // is taken as echo. The cost is at most that long of leading silence
        // on a segment; the alternative is a stray paragraph.
        guard microphoneWindow.count >= parameters.decisionFrames else {
            return Verdict(isEcho: systemIsActive, lagFrames: nil, correlation: 0)
        }

        if let since = framesSinceDecision, since + microphone.count < parameters.decisionFrames {
            framesSinceDecision = since + microphone.count
        } else {
            framesSinceDecision = 0
            lastMatch = systemIsActive ? bestMatch() : (nil, 0)
            if lastMatch.lag != nil, lastMatch.correlation >= parameters.echoCorrelation {
                holdRemaining = parameters.holdFrames
            }
        }
        return Verdict(isEcho: holdRemaining > 0, lagFrames: lastMatch.lag, correlation: lastMatch.correlation)
    }

    /// Forget the recent past — after a pause, or a route change.
    public mutating func reset() {
        microphoneWindow = []
        systemWindow = []
        framesSinceDecision = nil
        lastMatch = (nil, 0)
        holdRemaining = 0
    }

    /// The lag at which the microphone window best matches the system side,
    /// and how well. Samples that would need reference from before the
    /// remembered past are left out, not the lag.
    private func bestMatch() -> (lag: Int?, correlation: Float) {
        let count = microphoneWindow.count
        let offset = systemWindow.count - count
        var best: (lag: Int?, correlation: Float) = (nil, -1)
        var lag = 0
        while lag <= parameters.maximumLagFrames {
            let first = max(0, lag - offset)
            if first < count {
                var dot: Float = 0
                var referenceEnergy: Float = 0
                var microphoneEnergy: Float = 0
                for i in first..<count {
                    let r = systemWindow[offset + i - lag]
                    let m = microphoneWindow[i]
                    dot += m * r
                    referenceEnergy += r * r
                    microphoneEnergy += m * m
                }
                let denominator = (referenceEnergy * microphoneEnergy).squareRoot()
                let correlation = denominator > 0 ? dot / denominator : 0
                if correlation > best.correlation { best = (lag, correlation) }
            }
            lag += parameters.lagStepFrames
        }
        return best
    }

    public static func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var count = 0
        for sample in samples {
            sum += sample * sample
            count += 1
        }
        guard count > 0 else { return 0 }
        return (sum / Float(count)).squareRoot()
    }
}

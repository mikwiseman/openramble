import Foundation

/// Where a take may be cut so the engine can start work before the person stops
/// talking.
///
/// Pure, like `SilencePolicy`: frame levels and sample counts go in, cut offsets
/// come out. Nothing here reads a device, a clock or a setting, so the whole
/// rule is testable without a microphone.
///
/// **The one rule that makes this safe: a cut is only ever placed inside
/// silence.** Never through speech, whatever it costs in latency. A previous
/// attempt in this project chunked on length alone, cut phrases in half, and
/// lost three times more words than the engine did on its own; that failure is
/// excluded here by construction rather than by tuning. When someone talks
/// without pausing, no cut is offered and the segment simply grows — the take
/// then behaves exactly as it does today, which is the worst case rather than a
/// new one.
///
/// Why cut at all, beyond latency: the engine decides one language for a whole
/// decode and imposes it on everything inside, so a long take is also a large
/// blast radius for that decision. And its cost is superlinear — measured on
/// this model, 60 s costs 1.53 s but 140 s costs 5.64 s, against a linear
/// prediction of 2.02 s. Smaller decodes are cheaper per second, not just
/// earlier.
public struct SpeechSegmenter: Sendable, Equatable {
    /// The knobs, with the values this project measured rather than guessed.
    public struct Parameters: Sendable, Equatable {
        /// Silence at least this long may carry a cut.
        ///
        /// Below roughly 300 ms a pause stops being a pause: stop closures
        /// inside ordinary words run to 150 ms, and cutting there puts a seam
        /// inside a word. Measured on five real takes, 350 ms cut a hesitation
        /// inside a spoken number and split "2024" across two decodes, while
        /// 700 ms did not; fidelity against a whole-file decode went 95.7% →
        /// 97.0% across that range. The default is the fidelity end.
        public var minimumPause: Duration
        /// How much audio must be pending before a pause is worth spending.
        ///
        /// Every cut costs a decode that restarts the engine's prediction state,
        /// so cutting at every breath buys latency and pays accuracy.
        public var minimumSegment: Duration
        /// Never hand the engine less than this.
        ///
        /// Measured, and the reason this parameter exists: below about two
        /// seconds the decoder is not merely worse, it is *non-monotonic*. The
        /// same start offset returned "Yeah." at 0.8 s, nothing at 1.0 s,
        /// "Whoa." at 1.2 s and nothing at 1.6 s. Adding audio removed output.
        /// A segment shorter than this is not shipped on its own; it stays with
        /// the audio that follows it.
        public var minimumSubmission: Duration
        /// Once the pending audio passes this, accept shorter pauses.
        ///
        /// A person mid-argument may not offer a 700 ms pause for a minute, and
        /// the superlinear decode cost means waiting is not free. Past this
        /// point the threshold relaxes to `relaxedPause` — still a real pause,
        /// never a cut through speech.
        public var relaxAfter: Duration
        /// The shortest pause accepted once `relaxAfter` has passed.
        public var relaxedPause: Duration
        /// A frame at or above this peak counts as speech.
        ///
        /// The same constant the application's `SilencePolicy` uses for
        /// hands-free, repeated rather than shared because that type lives in
        /// the application layer and this package must not depend on it. The
        /// reasoning is the same: a room's noise floor sits low and steady
        /// while speech has sharp transients even when quiet. A fixed threshold
        /// fails safe — in a room too noisy for it, no pause is ever detected,
        /// no cut is offered, and the take behaves as it does today.
        public static let defaultSpeechPeak: Float = 0.02
        public var speechPeak: Float

        public init(
            minimumPause: Duration = .milliseconds(700),
            minimumSegment: Duration = .seconds(4),
            minimumSubmission: Duration = .seconds(2),
            relaxAfter: Duration = .seconds(20),
            relaxedPause: Duration = .milliseconds(350),
            speechPeak: Float = Parameters.defaultSpeechPeak
        ) {
            self.minimumPause = minimumPause
            self.minimumSegment = minimumSegment
            self.minimumSubmission = minimumSubmission
            self.relaxAfter = relaxAfter
            self.relaxedPause = relaxedPause
            self.speechPeak = speechPeak
        }
    }

    public let parameters: Parameters
    private let sampleRate: Int

    /// Samples seen since the last cut. The pending segment's length.
    private var pendingSamples = 0
    /// Length of the silence currently running, in samples, or nil while the
    /// person is speaking.
    private var quietSamples: Int?
    /// Whether any speech has been heard in the pending segment.
    ///
    /// A segment of pure silence is not worth a decode, and a take that begins
    /// with someone finding their words must not be cut before the first one.
    private var heardSpeech = false

    public init(parameters: Parameters = Parameters(), sampleRate: Int = 16_000) {
        self.parameters = parameters
        self.sampleRate = sampleRate
    }

    private func samples(_ duration: Duration) -> Int {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return Int(seconds * Double(sampleRate))
    }

    /// The pause length required right now, given how much is pending.
    ///
    /// Exposed for the tests that pin the relaxation, and because a rule worth
    /// having is a rule worth reading.
    var requiredPauseSamples: Int {
        pendingSamples >= samples(parameters.relaxAfter)
            ? samples(parameters.relaxedPause)
            : samples(parameters.minimumPause)
    }

    /// Feed one frame of committed audio.
    ///
    /// `peak` is the frame's peak magnitude and `count` its sample count. The
    /// return value is the offset **within the pending segment** at which to
    /// cut, or `nil` for "keep going". The offset is measured from the start of
    /// the pending segment, so the caller never has to track absolute positions.
    ///
    /// The cut lands in the middle of the silence that earned it, which leaves
    /// quiet on both sides of the seam: the segment that closes ends in silence
    /// and the one that opens begins in it. Recordings padded with silence at
    /// either edge decode exactly as they do without it, so this costs nothing
    /// and spares both decodes a hard edge against speech.
    public mutating func observe(peak: Float, count: Int) -> Int? {
        precondition(count >= 0, "a frame cannot have a negative sample count")
        pendingSamples += count

        guard peak < parameters.speechPeak else {
            heardSpeech = true
            quietSamples = nil
            return nil
        }

        // Silence before the first word is not a pause between words. Without
        // this, a take that starts with a breath would be cut before it began.
        guard heardSpeech else { return nil }

        let quiet = (quietSamples ?? 0) + count
        quietSamples = quiet

        guard quiet >= requiredPauseSamples else { return nil }
        guard pendingSamples >= samples(parameters.minimumSegment) else { return nil }

        // The midpoint of the silence observed so far. `pendingSamples` already
        // includes this frame, so the silence occupies the last `quiet` samples.
        let cut = pendingSamples - quiet / 2

        // Never ship less than the engine can be trusted with. A segment this
        // short waits for the audio after it instead.
        guard cut >= samples(parameters.minimumSubmission) else { return nil }

        pendingSamples -= cut
        quietSamples = quiet - quiet / 2
        heardSpeech = false
        return cut
    }

    /// Forget the pending segment. For a new take.
    public mutating func reset() {
        pendingSamples = 0
        quietSamples = nil
        heardSpeech = false
    }

    /// Whether the pending audio is worth handing to the engine on its own.
    ///
    /// The tail at key-release goes through this: a tail shorter than
    /// `minimumSubmission` must be merged with what came before rather than
    /// decoded alone, because on its own it may decode to nothing at all.
    public var pendingIsSubmittable: Bool {
        pendingSamples >= samples(parameters.minimumSubmission)
    }

    /// How much audio is waiting, for the caller's own accounting.
    public var pendingSampleCount: Int { pendingSamples }
}

import Foundation

/// When a hands-free dictation has heard enough silence to stop itself.
///
/// Pure, so the rule can be tested without a microphone: peaks and a clock go
/// in, a decision comes out. Nothing here reads a device or a setting.
///
/// Only for hands-free. While the key is held, the person is holding it — they
/// are saying, with their hand, that they have not finished, and a pause for
/// thought is not an ending. Stopping under a held key would take the sentence
/// away mid-thought, which is the failure mode that makes voice input feel
/// hostile.
struct SilencePolicy: Equatable {
    /// Below this a frame counts as silence.
    ///
    /// Peak rather than average: a room's noise floor sits low and steady,
    /// while speech has sharp transients even at conversational volume, so a
    /// peak separates the two where an average blurs them.
    static let threshold: Float = 0.02

    /// How long the quiet must last.
    ///
    /// Long enough to survive the pause between sentences, which is where a
    /// shorter window cuts people off mid-paragraph, and short enough that a
    /// person who has finished does not sit waiting for the app to notice.
    static let requiredSilence: Duration = .seconds(2)

    /// Speech must have been heard before silence can end anything.
    ///
    /// Otherwise starting hands-free in a quiet room would stop the recording
    /// before a word was said, and the person would be left holding a feature
    /// that appears broken.
    private(set) var hasHeardSpeech = false
    private(set) var quietSince: ContinuousClock.Instant?

    /// Feed one frame's peak. Returns `true` when the take should finish.
    mutating func observe(peak: Float, at now: ContinuousClock.Instant) -> Bool {
        guard peak < Self.threshold else {
            hasHeardSpeech = true
            quietSince = nil
            return false
        }
        guard hasHeardSpeech else { return false }
        guard let quietSince else {
            self.quietSince = now
            return false
        }
        return quietSince.duration(to: now) >= Self.requiredSilence
    }

    /// A new take starts hearing nothing, from nobody.
    mutating func reset() {
        hasHeardSpeech = false
        quietSince = nil
    }
}

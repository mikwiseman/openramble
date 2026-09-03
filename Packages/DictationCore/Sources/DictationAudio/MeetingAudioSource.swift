import Foundation

/// One block of audio from one side of the conversation.
///
/// Always 16 kHz mono Float32 — the source owns the conversion from whatever
/// the device speaks — with the host clock reading at its first frame, so two
/// sources with two device clocks can be placed on one timeline.
public struct MeetingAudioBlock: Sendable {
    /// `nil` when the source had no valid timestamp for this block.
    public let hostNanoseconds: UInt64?
    public let samples: [Float]

    public init(hostNanoseconds: UInt64?, samples: [Float]) {
        self.hostNanoseconds = hostNanoseconds
        self.samples = samples
    }
}

public enum MeetingSourceFailure: Error, Sendable, Equatable {
    case unavailable(String)
    case startFailed(String)
    /// The device changed under the engine — unplugged, or the default moved.
    /// The engine has stopped; the source can be started again.
    case configurationChanged
    case conversionFailed(String)
}

/// A microphone, a system-audio tap, or a test script — anything that can
/// deliver timed 16 kHz mono blocks.
///
/// This is the seam that lets the whole capture layer be tested with no
/// microphone and no tap, the way `AudioCapturing` does it for dictation.
/// Health is not part of the protocol on purpose: "is audio arriving?" is an
/// inference from a clock and a peak, and the consumer that has both is the
/// right place to draw it.
public protocol MeetingAudioSource: Sendable {
    /// A short name for the device, for `meta.json`. Not user content.
    var deviceName: String? { get }

    /// Begin delivering blocks. Throws rather than delivering nothing.
    func start(
        onBlock: @escaping @Sendable (MeetingAudioBlock) -> Void,
        onFailure: @escaping @Sendable (MeetingSourceFailure) -> Void
    ) throws

    /// Stop delivering. Safe to call twice; safe to `start` again after.
    func stop()
}

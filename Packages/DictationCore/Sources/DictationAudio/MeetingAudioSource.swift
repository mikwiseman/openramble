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

/// Receives the same aligned PCM that has just been appended to the meeting
/// WAV. `startFrame` is the first frame in that file stretch, so another
/// writer (for example an AAC track in a screen recording) can share exactly
/// the recording clock without touching either source's device timestamps.
public protocol MeetingAudioBlockSink: Sendable {
    func receive(microphone: [Float], system: [Float], startFrame: Int)
    func anchor(hostNanoseconds: UInt64, frame: Int)
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

    /// Drop a pinned device and any other start-time choice that might have
    /// produced silence, so the next `start` uses whatever is default now.
    ///
    /// Called when the microphone has been delivering nothing we can hear
    /// while the other side of a call is clearly arriving — the usual cause
    /// is a preferred input that is not the one the meeting app is using.
    func prepareForRecovery()
}

public extension MeetingAudioSource {
    func prepareForRecovery() {}
}

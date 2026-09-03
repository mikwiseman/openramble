import DictationAudio
import DictationCore
import Foundation

/// Whether the other side of the call is actually being recorded.
///
/// A type and not a boolean, because a Core Audio process tap fails by
/// succeeding. Deny the permission, or send the output to AirPods, and the
/// tap is created without error and delivers silence for as long as anyone
/// cares to record. There is no error, no callback, and no way to ask. The
/// only evidence is sound arriving — so "are we capturing?" is an inference
/// from a clock and a peak, and an inference belongs in a table with tests,
/// not in a view.
///
/// The recorder plays a quarter second of an inaudible tone the moment the
/// tap starts (`SystemAudioProbe`). A tap that can hear anything hears that,
/// so the first three seconds decide the permission question; after that,
/// silence is just silence, and it has to be allowed to age before it means
/// anything: "no sound yet" and "no sound for two minutes" are the same
/// measurement and opposite meanings.
enum CaptureHealth: Equatable {
    /// Below macOS 14.2; the microphone is all there is.
    case unsupported
    /// A voice note. Not asked for, not a failure.
    case notRequested
    /// The tap just started and the probe has not had its three seconds.
    case verifying
    /// The probe was heard, or a voice was. Sound was arriving `secondsSinceSound` ago.
    case capturing(secondsSinceSound: TimeInterval)
    /// Not even the probe arrived: the permission was not granted, was granted
    /// to a process that has since to be relaunched, or the output route is
    /// one the tap cannot reach.
    case unheard(elapsed: TimeInterval)
    /// Sound arrived, then stopped for longer than a pause.
    case wentSilent(secondsSinceSound: TimeInterval)
    /// The tap could not be started at all.
    case unavailable(reason: String)

    static let probeGraceSeconds: TimeInterval = 3
    static let worrySeconds: TimeInterval = 60

    /// - Parameters:
    ///   - elapsed: seconds since the tap started.
    ///   - health: what the recorder has received on the system channel.
    static func make(
        isSupported: Bool,
        requested: Bool,
        startFailure: String?,
        elapsed: TimeInterval,
        health: MeetingCapture.ChannelHealth,
        now: ContinuousClock.Instant
    ) -> CaptureHealth {
        guard isSupported else { return .unsupported }
        guard requested else { return .notRequested }
        if let startFailure { return .unavailable(reason: startFailure) }
        if let lastAudible = health.lastAudibleAt {
            let since = seconds(from: lastAudible, to: now)
            return since >= worrySeconds ? .wentSilent(secondsSinceSound: since) : .capturing(secondsSinceSound: since)
        }
        return elapsed < probeGraceSeconds ? .verifying : .unheard(elapsed: elapsed)
    }

    private static func seconds(from instant: ContinuousClock.Instant, to now: ContinuousClock.Instant) -> TimeInterval {
        let duration = instant.duration(to: now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Never `.recording`: red is the microphone.
    var role: StatusColorRole? {
        switch self {
        case .unsupported, .notRequested: return nil
        case .verifying, .capturing: return .processing
        case .unheard, .wentSilent, .unavailable: return .attention
        }
    }

    /// Does the finished recording carry this mark forever?
    var marksRecordingDegraded: Bool {
        switch self {
        case .unheard, .unavailable, .wentSilent: return true
        case .unsupported, .notRequested, .verifying, .capturing: return false
        }
    }

    /// Nothing to say, or the one line worth saying.
    var title: String? {
        switch self {
        case .unsupported: return "This Mac can't record other apps' audio"
        case .notRequested, .verifying, .capturing: return nil
        case .unheard: return "Only your microphone is being recorded"
        case let .wentSilent(seconds): return "The other side went quiet \(RecordingTime.brief(seconds)) ago"
        case .unavailable: return "Only your microphone is being recorded"
        }
    }

    var detail: String? {
        switch self {
        case .unsupported:
            return "Recording what you hear needs macOS 14.2 or later. Everything else works."
        case .notRequested, .verifying, .capturing:
            return nil
        case .unheard:
            return "Nothing is arriving from what this Mac plays. Either System Audio Recording isn't allowed for OpenRamble, or this output is one macOS can't record — Bluetooth and AirPlay are. If you've just allowed it, relaunch OpenRamble."
        case .wentSilent:
            return "Sound was arriving earlier. Your audio output may have changed."
        case let .unavailable(reason):
            return reason
        }
    }

    /// What VoiceOver says when this state is first reached, if anything.
    var announcement: String? {
        switch self {
        case .unheard: return "The other side is not being captured."
        case .wentSilent: return "The other side went quiet."
        case .capturing: return "The other side is being captured."
        case .unsupported, .notRequested, .verifying, .unavailable: return nil
        }
    }
}

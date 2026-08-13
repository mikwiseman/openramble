import Foundation

/// State of the dictation session.
///
/// The order is strict: `idle → preparing → listening → transcribing → inserting → idle`.
/// Cancellation is possible from any state before `inserting` - starting from it the text is already
/// goes into someone else's application, and there is nothing to rewind.
public enum DictationState: Sendable, Equatable {
    /// Nothing happens, the microphone is turned off, the recording indicator is off.
    case idle
    /// The key is pressed, raise the sound engine. Takes tens of milliseconds.
    case preparing
    /// Recording in progress.
    case listening
    /// The key is released, we recognize what was written.
    case transcribing
    /// Insert the finished text into the active application.
    case inserting

    /// Is the session busy? You cannot start a new one at this time.
    public var isBusy: Bool { self != .idle }

    /// Is the microphone listening right now.
    ///
    /// The integrity of the “light goes off when we don’t listen” promise depends on this:
    /// The sound engine must be turned off in all other states.
    public var isCapturing: Bool { self == .listening }
}

/// What to do with a key release that came before the session had time to start.
///
/// The user presses and releases faster than the sound engine rises -
/// this is the norm for a short phrase. Letting go cannot be lost, otherwise dictation
/// “sticks” in recording mode.
public enum DeferredStopDecision: Sendable, Equatable {
    /// Normal stop: recording is already in progress.
    case stopNow
    /// Remember and stop as soon as recording starts.
    case deferUntilListening
    /// Ignore: In hands-free mode, releasing the key does nothing.
    case ignore
    /// There is no session - there is nothing to react to.
    case noSession
}

public enum DictationStopPolicy {
    /// Decide what to do with releasing the hotkey.
    public static func decideStop(
        state: DictationState,
        isHandsFree: Bool
    ) -> DeferredStopDecision {
        // In hands-free mode, recording stops with a second press,
        // and not by releasing it - otherwise it would break off immediately after the start.
        if isHandsFree { return .ignore }

        switch state {
        case .idle:
            return .noSession
        case .preparing:
            // The main case for which all this exists: the key was pressed
            // release while the engine is rising.
            return .deferUntilListening
        case .listening:
            return .stopNow
        case .transcribing, .inserting:
            // Finalization is already underway - it cannot be run a second time.
            return .ignore
        }
    }

    /// Is it possible to start a new session.
    public static func canStart(state: DictationState, isEnabled: Bool, isModelReady: Bool) -> Bool {
        isEnabled && isModelReady && state == .idle
    }

    /// Is it still possible to cancel what is happening.
    ///
    /// Once the insertion has started, there is nothing to cancel: the keyboard event has already been sent
    /// to another application and does not respond.
    public static func canCancel(state: DictationState) -> Bool {
        switch state {
        case .idle, .inserting:
            return false
        case .preparing, .listening, .transcribing:
            return true
        }
    }
}

/// Whether to continue bringing the session to insertion.
///
/// Checked after each wait in the completion chain: the user could
/// press cancel while recognition was in progress.
public enum DictationFinalizationPolicy {
    public static func shouldContinue(
        state: DictationState,
        cancellationRequested: Bool,
        taskCancelled: Bool
    ) -> Bool {
        guard !cancellationRequested, !taskCancelled else { return false }
        switch state {
        case .transcribing, .inserting:
            return true
        case .idle, .preparing, .listening:
            return false
        }
    }
}

/// Limit the duration of one dictation.
public enum DictationDurationPolicy {
    /// In short, there is nothing to recognize.
    ///
    /// The engine refuses to work with records less than 300 ms, but this is not only the case
    /// in it: a person who pressed and immediately released a key simply changed his mind.
    /// Showing him a recognition error means frightening him out of the blue.
    public static let minimum: TimeInterval = 0.35

    /// Is there anything to recognize.
    public static func isWorthTranscribing(duration: TimeInterval) -> Bool {
        duration >= minimum
    }

    /// What to do with a recording that is too short to recognize.
    public enum ShortRecordingOutcome: Sendable, Equatable {
        /// Keep silent: the key was touched, the person changed his mind.
        case dropSilently
        /// Tell: the key was held down, and the microphone did not record anything.
        case reportSilentInput
    }

    /// How long a hold must last before an empty recording stops being a change
    /// of mind and becomes a broken microphone.
    ///
    /// The recording starts counting after the engine has risen, so only the wait
    /// for the first frame - tens of milliseconds - falls into the gap between the
    /// hold and the recorded audio. One and a half seconds is four times the
    /// `minimum`: no latency can eat that much, only an input that gives nothing -
    /// muted, dead or taken by another application.
    public static let minimumHoldForSilentInput: TimeInterval = 1.5

    /// The recording did not reach the `minimum`. Was that the person or the device?
    ///
    /// Only the hold decides. Duration is not asked about here: a recording that
    /// did not reach the minimum after a long hold is a faulty input, whether
    /// there are zero frames in it or a third of a second.
    public static func outcomeForShortRecording(held: TimeInterval) -> ShortRecordingOutcome {
        held >= minimumHoldForSilentInput ? .reportSilentInput : .dropSilently
    }

    // A one-hour session cap lived here once, "for safety". It was the
    // product deciding for the person when their dictation is long enough —
    // removed, along with the repeating timer that policed it. WAV streams
    // to disk; the transcription deadline scales with the recording; there
    // is no engineering reason left to interrupt anyone mid-sentence.
}

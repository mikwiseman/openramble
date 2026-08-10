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

    /// An hour is the limit of one session.
    ///
    /// Engineering limitation: WAV is written stream to disk, but recognition
    /// An hour-long recording takes up significant time and engine memory. By
    /// When the limit is reached, the recording stops itself and is recognized - said
    /// is not lost.
    public static let maximum: TimeInterval = 3600

    public enum Action: Sendable, Equatable {
        case keepRecording
        case stopAndTranscribe
    }

    public static func action(elapsed: TimeInterval) -> Action {
        elapsed >= maximum ? .stopAndTranscribe : .keepRecording
    }
}

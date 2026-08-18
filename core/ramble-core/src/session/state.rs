//! The dictation state machine's vocabulary and its decision policies.
//!
//! Ported from `Packages/DictationCore/Sources/DictationCore/DictationState.swift`,
//! which is the shipping macOS behaviour. Every rule here came from a real
//! field bug, so the reasons are carried over with the code: a future platform
//! that finds one of these surprising should read why it exists before
//! "simplifying" it away.

use serde::{Deserialize, Serialize};

/// State of the dictation session.
///
/// The order is strict: `Idle → Preparing → Listening → Transcribing →
/// Inserting → Idle`. Cancellation is possible from any state before
/// `Inserting` — from there the text is already on its way into someone else's
/// application, and there is nothing to rewind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DictationState {
    /// Nothing is happening; the microphone is off and the recording light is out.
    Idle,
    /// The key is down and the audio engine is coming up. Tens of milliseconds.
    Preparing,
    /// Recording is in progress.
    Listening,
    /// The key is released; recognizing what was said.
    Transcribing,
    /// Putting the finished text into the active application.
    Inserting,
}

impl DictationState {
    /// Is a session busy? A new one may not start while it is.
    pub fn is_busy(self) -> bool {
        self != DictationState::Idle
    }

    /// Is the microphone listening right now?
    ///
    /// The "the light goes out when we are not listening" promise depends on
    /// this: the audio engine must be down in every other state.
    pub fn is_capturing(self) -> bool {
        self == DictationState::Listening
    }
}

/// What to do with a key release that arrived before the session was ready.
///
/// Pressing and releasing faster than the audio engine comes up is normal for
/// a short phrase. The release must not be lost, or dictation sticks in
/// recording mode forever.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeferredStopDecision {
    /// Ordinary stop: recording is already running.
    StopNow,
    /// Remember it, and stop the moment recording starts.
    DeferUntilListening,
    /// Ignore: in hands-free mode a release means nothing.
    Ignore,
    /// There is no session, so there is nothing to react to.
    NoSession,
}

/// Decide what a hotkey release means.
pub fn decide_stop(state: DictationState, is_hands_free: bool) -> DeferredStopDecision {
    // In hands-free mode recording stops on a second press, not on release —
    // otherwise it would end immediately after it began.
    if is_hands_free {
        return DeferredStopDecision::Ignore;
    }
    match state {
        DictationState::Idle => DeferredStopDecision::NoSession,
        // The case this whole mechanism exists for: pressed and released while
        // the engine was still coming up.
        DictationState::Preparing => DeferredStopDecision::DeferUntilListening,
        DictationState::Listening => DeferredStopDecision::StopNow,
        // Finalization is already under way and must not run twice.
        DictationState::Transcribing | DictationState::Inserting => DeferredStopDecision::Ignore,
    }
}

/// May a new session start?
pub fn can_start(state: DictationState, is_enabled: bool, is_model_ready: bool) -> bool {
    is_enabled && is_model_ready && state == DictationState::Idle
}

/// Can what is happening still be cancelled?
///
/// Once insertion has begun there is nothing to cancel: the keyboard event has
/// already gone to another application and does not answer.
pub fn can_cancel(state: DictationState) -> bool {
    match state {
        DictationState::Idle | DictationState::Inserting => false,
        DictationState::Preparing | DictationState::Listening | DictationState::Transcribing => {
            true
        }
    }
}

/// Should the session keep going toward insertion?
///
/// Checked after every wait in the finalization chain: the person may have
/// pressed cancel while recognition was running.
pub fn should_continue(
    state: DictationState,
    cancellation_requested: bool,
    task_cancelled: bool,
) -> bool {
    if cancellation_requested || task_cancelled {
        return false;
    }
    matches!(
        state,
        DictationState::Transcribing | DictationState::Inserting
    )
}

/// What to do with a recording too short to be worth recognizing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ShortRecordingOutcome {
    /// Say nothing: the key was brushed and the person changed their mind.
    DropSilently,
    /// Say something: the key was held, and the microphone recorded nothing.
    ReportSilentInput,
}

/// Limits on a single dictation.
pub struct DurationPolicy;

impl DurationPolicy {
    /// Below this there is nothing to recognize.
    ///
    /// The engine refuses recordings under 300 ms, but that is not the only
    /// reason: someone who pressed and instantly released simply changed their
    /// mind, and showing them a recognition error would frighten them for no
    /// reason.
    pub const MINIMUM_SECONDS: f64 = 0.35;

    /// How long a hold must last before an empty recording stops being a change
    /// of mind and becomes a broken microphone.
    ///
    /// Recording starts counting after the engine is up, so only the wait for
    /// the first frame — tens of milliseconds — falls between the hold and the
    /// recorded audio. A second and a half is four times `MINIMUM_SECONDS`: no
    /// latency eats that much, only an input that gives nothing at all — muted,
    /// dead, or held by another application.
    pub const MINIMUM_HOLD_FOR_SILENT_INPUT_SECONDS: f64 = 1.5;

    /// Is there anything worth recognizing?
    pub fn is_worth_transcribing(duration_seconds: f64) -> bool {
        duration_seconds >= Self::MINIMUM_SECONDS
    }

    /// The recording fell short of the minimum. Was that the person or the device?
    ///
    /// Only the hold decides. The duration is not consulted: a recording that
    /// fell short after a long hold is a faulty input whether it holds zero
    /// frames or a third of a second.
    pub fn outcome_for_short_recording(held_seconds: f64) -> ShortRecordingOutcome {
        if held_seconds >= Self::MINIMUM_HOLD_FOR_SILENT_INPUT_SECONDS {
            ShortRecordingOutcome::ReportSilentInput
        } else {
            ShortRecordingOutcome::DropSilently
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_listening_holds_the_microphone_open() {
        // The recording light is driven by this. Any other state reporting
        // "capturing" would mean a lit indicator over a dead microphone, or
        // worse, a live microphone with the light out.
        assert!(DictationState::Listening.is_capturing());
        for state in [
            DictationState::Idle,
            DictationState::Preparing,
            DictationState::Transcribing,
            DictationState::Inserting,
        ] {
            assert!(!state.is_capturing(), "{state:?} must not capture");
        }
    }

    #[test]
    fn every_state_but_idle_is_busy() {
        assert!(!DictationState::Idle.is_busy());
        for state in [
            DictationState::Preparing,
            DictationState::Listening,
            DictationState::Transcribing,
            DictationState::Inserting,
        ] {
            assert!(state.is_busy(), "{state:?} must be busy");
        }
    }

    #[test]
    fn a_release_during_preparing_is_remembered_not_dropped() {
        // Losing this release is what strands dictation in recording mode.
        assert_eq!(
            decide_stop(DictationState::Preparing, false),
            DeferredStopDecision::DeferUntilListening
        );
        assert_eq!(
            decide_stop(DictationState::Listening, false),
            DeferredStopDecision::StopNow
        );
        assert_eq!(
            decide_stop(DictationState::Idle, false),
            DeferredStopDecision::NoSession
        );
    }

    #[test]
    fn finalization_never_runs_twice() {
        for state in [DictationState::Transcribing, DictationState::Inserting] {
            assert_eq!(decide_stop(state, false), DeferredStopDecision::Ignore);
        }
    }

    #[test]
    fn hands_free_ignores_the_release_from_every_state() {
        for state in [
            DictationState::Idle,
            DictationState::Preparing,
            DictationState::Listening,
            DictationState::Transcribing,
            DictationState::Inserting,
        ] {
            assert_eq!(decide_stop(state, true), DeferredStopDecision::Ignore);
        }
    }

    #[test]
    fn starting_needs_an_idle_session_a_ready_model_and_permission() {
        assert!(can_start(DictationState::Idle, true, true));
        assert!(!can_start(DictationState::Idle, false, true));
        assert!(!can_start(DictationState::Idle, true, false));
        assert!(!can_start(DictationState::Listening, true, true));
    }

    #[test]
    fn cancelling_stops_being_possible_once_the_text_is_leaving() {
        assert!(can_cancel(DictationState::Preparing));
        assert!(can_cancel(DictationState::Listening));
        assert!(can_cancel(DictationState::Transcribing));
        // The keystroke is already in another application; there is nothing to rewind.
        assert!(!can_cancel(DictationState::Inserting));
        assert!(!can_cancel(DictationState::Idle));
    }

    #[test]
    fn a_cancelled_session_does_not_reach_insertion() {
        assert!(should_continue(DictationState::Transcribing, false, false));
        assert!(!should_continue(DictationState::Transcribing, true, false));
        assert!(!should_continue(DictationState::Transcribing, false, true));
        assert!(!should_continue(DictationState::Listening, false, false));
    }

    #[test]
    fn a_brushed_key_is_dropped_in_silence_but_a_held_one_is_explained() {
        // The difference is the hold, never the recorded duration: a long hold
        // that produced nothing is a broken input and the person deserves to
        // hear so.
        assert_eq!(
            DurationPolicy::outcome_for_short_recording(0.2),
            ShortRecordingOutcome::DropSilently
        );
        assert_eq!(
            DurationPolicy::outcome_for_short_recording(1.5),
            ShortRecordingOutcome::ReportSilentInput
        );
        assert_eq!(
            DurationPolicy::outcome_for_short_recording(4.0),
            ShortRecordingOutcome::ReportSilentInput
        );
    }

    #[test]
    fn the_minimum_worth_recognizing_matches_the_shipping_macos_value() {
        assert!(!DurationPolicy::is_worth_transcribing(0.34));
        assert!(DurationPolicy::is_worth_transcribing(0.35));
        assert!(DurationPolicy::is_worth_transcribing(30.0));
    }
}

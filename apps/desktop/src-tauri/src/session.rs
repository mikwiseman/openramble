//! One dictation, from the key going down to the text landing.
//!
//! The order of the steps and the decisions between them belong to `ramble-core`
//! and `ramble-text`; this is the part that calls a microphone and a keyboard.
//! Keeping the sequence here readable matters more than keeping it short — this
//! is where a person's words can be dropped.

use ramble_core::session::{DictationState, DurationPolicy};
use std::time::Duration;

/// What a finished dictation produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The text was inserted.
    ///
    /// Carries nothing. No consumer needs the transcript, and a payload that
    /// exists is a payload something will eventually log — which is the one
    /// thing this product must never do with what a person said.
    Inserted,
    /// The key was brushed and nothing was said. Nothing is shown: the person
    /// changed their mind, and an error would only alarm them.
    DroppedSilently,
    /// The key was held but the microphone gave nothing. Worth saying — the
    /// input is muted, dead, or held by another application.
    SilentInput,
    /// The text was inserted, but the recording had hit the ceiling and was cut
    /// short. Worth saying, because the person's last words are missing.
    Truncated,
    /// Something failed, in words a person can act on.
    Failed(String),
}

/// Decide what a finished recording amounts to, before any engine is involved.
///
/// Separated from the machinery so the rules — which are shared with macOS —
/// stay testable without a microphone, a model, or a keyboard.
pub fn outcome_for_recording(recorded: Duration, held: Duration) -> Option<Outcome> {
    if !DurationPolicy::is_worth_transcribing(recorded.as_secs_f64()) {
        return Some(
            match DurationPolicy::outcome_for_short_recording(held.as_secs_f64()) {
                ramble_core::session::ShortRecordingOutcome::DropSilently => {
                    Outcome::DroppedSilently
                }
                ramble_core::session::ShortRecordingOutcome::ReportSilentInput => {
                    Outcome::SilentInput
                }
            },
        );
    }
    // Long enough to recognize.
    None
}

/// Is the session in a state where a new dictation may begin?
pub fn may_start(state: DictationState, model_ready: bool) -> bool {
    ramble_core::session::can_start(state, true, model_ready)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_brushed_key_produces_nothing_and_says_nothing() {
        let outcome = outcome_for_recording(Duration::from_millis(100), Duration::from_millis(150));
        assert_eq!(outcome, Some(Outcome::DroppedSilently));
    }

    /// Held for two seconds and the microphone gave nothing back. That is a
    /// broken input, and the person deserves to hear so.
    #[test]
    fn a_long_hold_that_recorded_nothing_is_reported() {
        let outcome = outcome_for_recording(Duration::from_millis(10), Duration::from_secs(2));
        assert_eq!(outcome, Some(Outcome::SilentInput));
    }

    #[test]
    fn a_real_recording_goes_on_to_the_engine() {
        let outcome = outcome_for_recording(Duration::from_secs(3), Duration::from_secs(3));
        assert_eq!(outcome, None, "a real take must not be short-circuited");
    }

    /// The boundary is the shared one, not a number invented here.
    #[test]
    fn the_threshold_is_the_shared_one() {
        assert!(outcome_for_recording(
            Duration::from_secs_f64(DurationPolicy::MINIMUM_SECONDS),
            Duration::from_secs(1)
        )
        .is_none());
        assert!(outcome_for_recording(
            Duration::from_secs_f64(DurationPolicy::MINIMUM_SECONDS - 0.01),
            Duration::from_secs(1)
        )
        .is_some());
    }

    #[test]
    fn nothing_starts_until_a_model_is_ready() {
        assert!(may_start(DictationState::Idle, true));
        assert!(!may_start(DictationState::Idle, false));
        assert!(!may_start(DictationState::Listening, true));
    }
}

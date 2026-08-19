//! The dictation session as a machine: events in, effects out.
//!
//! Ported from the orchestration in `DictationController.swift`. That controller
//! interleaves the decisions with the doing — starting an audio engine, awaiting
//! a recogniser, writing a file — which is why its behaviour can only be checked
//! by running a Mac. Here the two are separated: this type decides, and returns
//! what should happen as values. Somebody else does it.
//!
//! The point is not elegance. It is that every rule below can be exercised
//! without a microphone, a model, or a window, on any platform, in microseconds —
//! and that the same rules therefore cannot drift between the platforms that
//! share them.

use crate::session::state::{
    can_cancel, can_start, decide_stop, DeferredStopDecision, DictationState, DurationPolicy,
    ShortRecordingOutcome,
};
use std::time::Duration;

/// Something that happened.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// The dictation key went down.
    Pressed,
    /// The dictation key came up, after being held this long.
    Released { held: Duration },
    /// The microphone is open and delivering.
    CaptureStarted,
    /// The microphone could not be opened.
    CaptureFailed,
    /// Recording stopped; this much audio was collected.
    CaptureFinished { recorded: Duration, truncated: bool },
    /// Recognition produced text.
    Transcribed { is_empty: bool },
    /// Recognition failed.
    TranscriptionFailed,
    /// The text reached the other application.
    Inserted,
    /// It did not.
    InsertionFailed,
    /// The person pressed Escape.
    CancelRequested,
}

/// Something that should happen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Effect {
    StartCapture,
    StopCapture,
    /// Throw the take away without producing anything.
    DiscardCapture,
    Transcribe,
    InsertText,
    /// Say nothing at all: the key was brushed and the person changed their mind.
    FinishSilently,
    /// Tell them the microphone gave nothing.
    ReportSilentInput,
    /// Tell them the recording hit the ceiling.
    ReportTruncated,
    /// Tell them it failed.
    ReportFailure,
}

/// The session.
#[derive(Debug, Clone)]
pub struct SessionMachine {
    state: DictationState,
    /// A release that arrived before recording began.
    ///
    /// Pressing and releasing faster than the audio engine opens is ordinary for
    /// a short phrase. Losing that release strands dictation in recording mode
    /// with the microphone live, which is the worst failure this product has.
    deferred_stop: bool,
    /// How long the key was held, remembered from the release that ended it.
    held: Duration,
    is_hands_free: bool,
    cancelled: bool,
}

impl Default for SessionMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionMachine {
    pub fn new() -> Self {
        SessionMachine {
            state: DictationState::Idle,
            deferred_stop: false,
            held: Duration::ZERO,
            is_hands_free: false,
            cancelled: false,
        }
    }

    pub fn state(&self) -> DictationState {
        self.state
    }

    pub fn is_capturing(&self) -> bool {
        self.state.is_capturing()
    }

    /// Feed an event; get back what to do.
    pub fn handle(&mut self, event: Event, model_ready: bool) -> Vec<Effect> {
        match event {
            Event::Pressed => self.press(model_ready),
            Event::Released { held } => self.release(held),
            Event::CaptureStarted => self.capture_started(),
            Event::CaptureFailed => {
                // The microphone never opened, so the session must not be left
                // in Preparing with no way back to Idle.
                self.state = DictationState::Idle;
                vec![Effect::ReportFailure]
            }
            Event::CaptureFinished {
                recorded,
                truncated,
            } => self.capture_finished(recorded, truncated),
            Event::Transcribed { is_empty } => self.transcribed(is_empty),
            Event::TranscriptionFailed => self.finish(vec![Effect::ReportFailure]),
            Event::Inserted => self.finish(Vec::new()),
            Event::InsertionFailed => self.finish(vec![Effect::ReportFailure]),
            Event::CancelRequested => self.cancel(),
        }
    }

    fn press(&mut self, model_ready: bool) -> Vec<Effect> {
        if !can_start(self.state, true, model_ready) {
            return Vec::new();
        }
        self.state = DictationState::Preparing;
        self.deferred_stop = false;
        self.cancelled = false;
        vec![Effect::StartCapture]
    }

    fn release(&mut self, held: Duration) -> Vec<Effect> {
        self.held = held;
        match decide_stop(self.state, self.is_hands_free) {
            DeferredStopDecision::StopNow => vec![Effect::StopCapture],
            DeferredStopDecision::DeferUntilListening => {
                self.deferred_stop = true;
                Vec::new()
            }
            DeferredStopDecision::Ignore | DeferredStopDecision::NoSession => Vec::new(),
        }
    }

    fn capture_started(&mut self) -> Vec<Effect> {
        if self.state != DictationState::Preparing {
            return Vec::new();
        }
        self.state = DictationState::Listening;
        // The release that arrived too early is honoured the moment it can be.
        if std::mem::take(&mut self.deferred_stop) {
            return vec![Effect::StopCapture];
        }
        if self.cancelled {
            return self.cancel();
        }
        Vec::new()
    }

    fn capture_finished(&mut self, recorded: Duration, truncated: bool) -> Vec<Effect> {
        if self.cancelled {
            return self.finish(vec![Effect::DiscardCapture]);
        }
        if !DurationPolicy::is_worth_transcribing(recorded.as_secs_f64()) {
            let effect = match DurationPolicy::outcome_for_short_recording(self.held.as_secs_f64())
            {
                ShortRecordingOutcome::DropSilently => Effect::FinishSilently,
                ShortRecordingOutcome::ReportSilentInput => Effect::ReportSilentInput,
            };
            return self.finish(vec![effect]);
        }
        self.state = DictationState::Transcribing;
        let mut effects = vec![Effect::Transcribe];
        if truncated {
            // Said alongside the text, not instead of it: the first ten minutes
            // are still what the person said.
            effects.push(Effect::ReportTruncated);
        }
        effects
    }

    fn transcribed(&mut self, is_empty: bool) -> Vec<Effect> {
        if self.cancelled || self.state != DictationState::Transcribing {
            return self.finish(Vec::new());
        }
        if is_empty {
            // Nothing was said. Silence is the honest answer; an error would
            // suggest a fault that is not there.
            return self.finish(vec![Effect::FinishSilently]);
        }
        self.state = DictationState::Inserting;
        vec![Effect::InsertText]
    }

    fn cancel(&mut self) -> Vec<Effect> {
        if !can_cancel(self.state) {
            // Insertion has begun; the keystroke is already in another
            // application and does not answer.
            return Vec::new();
        }
        self.cancelled = true;
        let was_capturing = self.state.is_capturing();
        self.state = DictationState::Idle;
        if was_capturing {
            vec![Effect::StopCapture, Effect::DiscardCapture]
        } else {
            vec![Effect::DiscardCapture]
        }
    }

    fn finish(&mut self, effects: Vec<Effect>) -> Vec<Effect> {
        self.state = DictationState::Idle;
        self.deferred_stop = false;
        self.cancelled = false;
        self.held = Duration::ZERO;
        effects
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seconds(value: f64) -> Duration {
        Duration::from_secs_f64(value)
    }

    /// Press, speak, release, text lands.
    #[test]
    fn the_ordinary_dictation_runs_end_to_end() {
        let mut machine = SessionMachine::new();
        assert_eq!(
            machine.handle(Event::Pressed, true),
            vec![Effect::StartCapture]
        );
        assert_eq!(machine.handle(Event::CaptureStarted, true), vec![]);
        assert!(machine.is_capturing());

        assert_eq!(
            machine.handle(Event::Released { held: seconds(3.0) }, true),
            vec![Effect::StopCapture]
        );
        assert_eq!(
            machine.handle(
                Event::CaptureFinished {
                    recorded: seconds(3.0),
                    truncated: false
                },
                true
            ),
            vec![Effect::Transcribe]
        );
        assert_eq!(
            machine.handle(Event::Transcribed { is_empty: false }, true),
            vec![Effect::InsertText]
        );
        assert_eq!(machine.handle(Event::Inserted, true), vec![]);
        assert_eq!(machine.state(), DictationState::Idle);
    }

    /// The failure this whole mechanism exists for: released before the
    /// microphone opened. Losing it leaves dictation recording forever.
    #[test]
    fn a_release_that_beats_the_microphone_is_honoured_when_it_can_be() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        assert_eq!(
            machine.handle(Event::Released { held: seconds(0.2) }, true),
            vec![]
        );
        // The moment recording actually starts, the release takes effect.
        assert_eq!(
            machine.handle(Event::CaptureStarted, true),
            vec![Effect::StopCapture]
        );
    }

    #[test]
    fn a_brushed_key_says_nothing_and_a_held_one_explains_itself() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        machine.handle(Event::CaptureStarted, true);
        machine.handle(Event::Released { held: seconds(0.2) }, true);
        assert_eq!(
            machine.handle(
                Event::CaptureFinished {
                    recorded: seconds(0.1),
                    truncated: false
                },
                true
            ),
            vec![Effect::FinishSilently]
        );

        let mut held = SessionMachine::new();
        held.handle(Event::Pressed, true);
        held.handle(Event::CaptureStarted, true);
        held.handle(Event::Released { held: seconds(2.0) }, true);
        assert_eq!(
            held.handle(
                Event::CaptureFinished {
                    recorded: seconds(0.01),
                    truncated: false
                },
                true
            ),
            vec![Effect::ReportSilentInput]
        );
    }

    #[test]
    fn nothing_starts_without_a_model() {
        let mut machine = SessionMachine::new();
        assert_eq!(machine.handle(Event::Pressed, false), vec![]);
        assert_eq!(machine.state(), DictationState::Idle);
    }

    #[test]
    fn a_microphone_that_will_not_open_returns_the_session_to_idle() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        assert_eq!(
            machine.handle(Event::CaptureFailed, true),
            vec![Effect::ReportFailure]
        );
        assert_eq!(machine.state(), DictationState::Idle);
        // And the next dictation can still start.
        assert_eq!(
            machine.handle(Event::Pressed, true),
            vec![Effect::StartCapture]
        );
    }

    #[test]
    fn cancelling_while_recording_stops_and_discards() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        machine.handle(Event::CaptureStarted, true);
        assert_eq!(
            machine.handle(Event::CancelRequested, true),
            vec![Effect::StopCapture, Effect::DiscardCapture]
        );
        assert_eq!(machine.state(), DictationState::Idle);
    }

    /// Once the text is on its way into another application there is nothing to
    /// cancel: the keystroke has already gone and does not answer.
    #[test]
    fn cancelling_during_insertion_does_nothing() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        machine.handle(Event::CaptureStarted, true);
        machine.handle(Event::Released { held: seconds(3.0) }, true);
        machine.handle(
            Event::CaptureFinished {
                recorded: seconds(3.0),
                truncated: false,
            },
            true,
        );
        machine.handle(Event::Transcribed { is_empty: false }, true);
        assert_eq!(machine.state(), DictationState::Inserting);
        assert_eq!(machine.handle(Event::CancelRequested, true), vec![]);
        assert_eq!(machine.state(), DictationState::Inserting);
    }

    #[test]
    fn an_empty_transcript_ends_in_silence_rather_than_an_error() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        machine.handle(Event::CaptureStarted, true);
        machine.handle(Event::Released { held: seconds(3.0) }, true);
        machine.handle(
            Event::CaptureFinished {
                recorded: seconds(3.0),
                truncated: false,
            },
            true,
        );
        assert_eq!(
            machine.handle(Event::Transcribed { is_empty: true }, true),
            vec![Effect::FinishSilently]
        );
        assert_eq!(machine.state(), DictationState::Idle);
    }

    #[test]
    fn a_truncated_take_is_still_transcribed_and_also_reported() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        machine.handle(Event::CaptureStarted, true);
        machine.handle(
            Event::Released {
                held: seconds(600.0),
            },
            true,
        );
        assert_eq!(
            machine.handle(
                Event::CaptureFinished {
                    recorded: seconds(600.0),
                    truncated: true
                },
                true
            ),
            vec![Effect::Transcribe, Effect::ReportTruncated]
        );
    }

    #[test]
    fn a_second_press_while_busy_is_ignored() {
        let mut machine = SessionMachine::new();
        machine.handle(Event::Pressed, true);
        machine.handle(Event::CaptureStarted, true);
        assert_eq!(machine.handle(Event::Pressed, true), vec![]);
    }

    /// Whatever happens, the session returns to idle. A machine that can strand
    /// itself is a microphone that stays on.
    #[test]
    fn every_ending_returns_to_idle() {
        for ending in [
            Event::TranscriptionFailed,
            Event::InsertionFailed,
            Event::Inserted,
        ] {
            let mut machine = SessionMachine::new();
            machine.handle(Event::Pressed, true);
            machine.handle(Event::CaptureStarted, true);
            machine.handle(Event::Released { held: seconds(3.0) }, true);
            machine.handle(
                Event::CaptureFinished {
                    recorded: seconds(3.0),
                    truncated: false,
                },
                true,
            );
            machine.handle(Event::Transcribed { is_empty: false }, true);
            machine.handle(ending, true);
            assert_eq!(machine.state(), DictationState::Idle, "{ending:?}");
            assert!(!machine.is_capturing(), "{ending:?}");
        }
    }
}

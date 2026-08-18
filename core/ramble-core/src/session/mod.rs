//! The dictation session: its states, the policies that govern transitions,
//! and the bound on recognition.

pub mod deadline;
pub mod state;

pub use deadline::{deadline_for_audio, TranscriptionTimeout};
pub use state::{
    can_cancel, can_start, decide_stop, should_continue, DeferredStopDecision, DictationState,
    DurationPolicy, ShortRecordingOutcome,
};

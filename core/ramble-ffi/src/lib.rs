//! The boundary the Swift app will call across.
//!
//! Nothing consumes this yet. It exists now because the cost of discovering that
//! a core API cannot cross an FFI boundary is proportional to how much has been
//! built on top of it — finding out during the macOS migration would mean
//! reshaping types that three platforms already depend on. Compiling this from
//! day one turns that into a build error on the commit that causes it.
//!
//! The types here deliberately mirror the core's rather than re-exporting them.
//! That is not duplication for its own sake: it keeps the published surface an
//! explicit, reviewable decision, so an internal refactor cannot silently change
//! what Swift sees.

// UniFFI's generated scaffolding is `unsafe` by nature — it hands raw pointers
// across a language boundary. The workspace denies unsafe code, and this crate
// is the single, deliberate exception. No hand-written `unsafe` belongs here:
// everything below is safe Rust delegating to the core.
#![allow(unsafe_code)]

use std::sync::Mutex;
use std::time::Duration;

use ramble_core::session;
use ramble_text::dictionary::DictionaryReplacement;
use ramble_text::pipeline::{TextPipeline, TrailingCommand};
use ramble_text::span::SpanKind;

uniffi::setup_scaffolding!();

// MARK: - Session state

/// State of the dictation session. Mirrors [`session::DictationState`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiDictationState {
    Idle,
    Preparing,
    Listening,
    Transcribing,
    Inserting,
}

impl From<FfiDictationState> for session::DictationState {
    fn from(value: FfiDictationState) -> Self {
        match value {
            FfiDictationState::Idle => session::DictationState::Idle,
            FfiDictationState::Preparing => session::DictationState::Preparing,
            FfiDictationState::Listening => session::DictationState::Listening,
            FfiDictationState::Transcribing => session::DictationState::Transcribing,
            FfiDictationState::Inserting => session::DictationState::Inserting,
        }
    }
}

/// What a hotkey release means. Mirrors [`session::DeferredStopDecision`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiStopDecision {
    StopNow,
    DeferUntilListening,
    Ignore,
    NoSession,
}

/// What to do with a recording too short to recognize.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiShortRecordingOutcome {
    DropSilently,
    ReportSilentInput,
}

#[uniffi::export]
pub fn state_is_busy(state: FfiDictationState) -> bool {
    session::DictationState::from(state).is_busy()
}

#[uniffi::export]
pub fn state_is_capturing(state: FfiDictationState) -> bool {
    session::DictationState::from(state).is_capturing()
}

#[uniffi::export]
pub fn decide_stop(state: FfiDictationState, is_hands_free: bool) -> FfiStopDecision {
    match session::decide_stop(state.into(), is_hands_free) {
        session::DeferredStopDecision::StopNow => FfiStopDecision::StopNow,
        session::DeferredStopDecision::DeferUntilListening => FfiStopDecision::DeferUntilListening,
        session::DeferredStopDecision::Ignore => FfiStopDecision::Ignore,
        session::DeferredStopDecision::NoSession => FfiStopDecision::NoSession,
    }
}

#[uniffi::export]
pub fn can_start(state: FfiDictationState, is_enabled: bool, is_model_ready: bool) -> bool {
    session::can_start(state.into(), is_enabled, is_model_ready)
}

#[uniffi::export]
pub fn can_cancel(state: FfiDictationState) -> bool {
    session::can_cancel(state.into())
}

#[uniffi::export]
pub fn should_continue(
    state: FfiDictationState,
    cancellation_requested: bool,
    task_cancelled: bool,
) -> bool {
    session::should_continue(state.into(), cancellation_requested, task_cancelled)
}

#[uniffi::export]
pub fn is_worth_transcribing(duration: Duration) -> bool {
    session::DurationPolicy::is_worth_transcribing(duration.as_secs_f64())
}

#[uniffi::export]
pub fn outcome_for_short_recording(held: Duration) -> FfiShortRecordingOutcome {
    match session::DurationPolicy::outcome_for_short_recording(held.as_secs_f64()) {
        session::ShortRecordingOutcome::DropSilently => FfiShortRecordingOutcome::DropSilently,
        session::ShortRecordingOutcome::ReportSilentInput => {
            FfiShortRecordingOutcome::ReportSilentInput
        }
    }
}

/// How long recognition may run before the engine is presumed wedged.
#[uniffi::export]
pub fn deadline_for_audio(audio: Duration) -> Duration {
    session::deadline_for_audio(audio)
}

// MARK: - The hold-to-talk gesture

/// What the gesture means. Mirrors [`ramble_core::hotkey::Action`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiGestureAction {
    None,
    Press,
    Release { after: Duration },
    DoubleTap,
    StopHandsFree,
    AbortShortcut,
}

impl From<ramble_core::hotkey::Action> for FfiGestureAction {
    fn from(value: ramble_core::hotkey::Action) -> Self {
        use ramble_core::hotkey::Action;
        match value {
            Action::None => FfiGestureAction::None,
            Action::Press => FfiGestureAction::Press,
            Action::Release { after } => FfiGestureAction::Release { after },
            Action::DoubleTap => FfiGestureAction::DoubleTap,
            Action::StopHandsFree => FfiGestureAction::StopHandsFree,
            Action::AbortShortcut => FfiGestureAction::AbortShortcut,
        }
    }
}

/// The gesture machine.
///
/// Behind a mutex because a UniFFI object is shared and must be `Sync`, while the
/// machine itself is a plain state machine that mutates on every event. The lock
/// is uncontended in practice: keyboard events arrive on one thread.
#[derive(uniffi::Object)]
pub struct FfiGestureMachine {
    inner: Mutex<ramble_core::hotkey::GestureMachine>,
}

#[uniffi::export]
impl FfiGestureMachine {
    #[uniffi::constructor]
    pub fn new(double_tap_window: Duration) -> Self {
        Self {
            inner: Mutex::new(ramble_core::hotkey::GestureMachine::new(double_tap_window)),
        }
    }

    /// Feed a modifier change.
    ///
    /// The adapter must have resolved which physical key this is — see
    /// `ModifierEvent` in ramble-core for why the category flag is never enough.
    pub fn handle(
        &self,
        is_hotkey_key: bool,
        is_hotkey_down: bool,
        is_exclusive: bool,
        at: Duration,
    ) -> FfiGestureAction {
        let event = if is_hotkey_key {
            ramble_core::hotkey::ModifierEvent::hotkey(is_hotkey_down, is_exclusive, at)
        } else {
            ramble_core::hotkey::ModifierEvent::foreign(is_hotkey_down, is_exclusive, at)
        };
        self.locked().handle(event).into()
    }

    pub fn handle_foreign_key_down(&self) -> FfiGestureAction {
        self.locked().handle_foreign_key_down().into()
    }

    pub fn rebind(&self) -> FfiGestureAction {
        self.locked().rebind().into()
    }

    pub fn reset(&self) {
        self.locked().reset();
    }

    pub fn is_held(&self) -> bool {
        self.locked().is_held()
    }

    pub fn set_hands_free_active(&self, active: bool) {
        self.locked().is_hands_free_active = active;
    }
}

impl FfiGestureMachine {
    /// A poisoned lock would mean a panic inside the machine, which holds no
    /// invariant worth protecting — recovering keeps a keyboard working rather
    /// than taking the app down with it.
    fn locked(&self) -> std::sync::MutexGuard<'_, ramble_core::hotkey::GestureMachine> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

// MARK: - Installed model

/// What the store knows about the install.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum FfiModelState {
    NotInstalled,
    Ready,
    /// Present but unusable, with the reason a person can act on.
    NeedsRepair {
        reason: String,
    },
}

/// Where an install lives and whether it is usable.
///
/// The layout is a contract with the shipping Mac: it must adopt a tree Swift
/// already wrote rather than downloading 739 MB again.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiModelReport {
    pub state: FfiModelState,
    /// The directory to hand the recognizer. Meaningful only when ready.
    pub engine_directory: String,
    pub total_byte_count: i64,
}

#[uniffi::export]
pub fn inspect_model(manifest_json: String, root: String) -> Result<FfiModelReport, FfiError> {
    let manifest = ramble_model::Manifest::parse(&manifest_json)
        .map_err(|error| FfiError::Manifest(error.to_string()))?;
    let store = ramble_model::ModelStore::new(manifest, &root);
    // Anything an interrupted install left behind is settled before a state is
    // reported, so nobody is shown "not installed" for a tree that is merely
    // mid-promotion.
    let _ = store.recover_interrupted_promotion();

    Ok(FfiModelReport {
        state: match store.state() {
            ramble_model::ModelState::NotInstalled => FfiModelState::NotInstalled,
            ramble_model::ModelState::Ready => FfiModelState::Ready,
            ramble_model::ModelState::NeedsRepair(reason) => FfiModelState::NeedsRepair { reason },
        },
        engine_directory: store.engine_directory().to_string_lossy().into_owned(),
        total_byte_count: store.manifest.total_byte_count(),
    })
}

// MARK: - The recogniser

/// A loaded recogniser.
///
/// Held by Swift as an object with a lifetime, because the model is 976 MB and
/// loading it per take is what made the Mac unpredictable in the first place.
#[derive(uniffi::Object)]
pub struct FfiEngine {
    inner: std::sync::Mutex<Option<ramble_engine::Engine>>,
}

#[uniffi::export]
impl FfiEngine {
    /// Load the model in a directory.
    #[uniffi::constructor]
    pub fn load(model_directory: String) -> Result<std::sync::Arc<Self>, FfiError> {
        let engine = ramble_engine::Engine::load(std::path::Path::new(&model_directory))
            .map_err(|error| FfiError::Engine(error.to_string()))?;
        Ok(std::sync::Arc::new(FfiEngine {
            inner: std::sync::Mutex::new(Some(engine)),
        }))
    }

    /// Recognise 16 kHz mono audio.
    pub fn transcribe(&self, samples: Vec<f32>) -> Result<String, FfiError> {
        let guard = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let engine = guard
            .as_ref()
            .ok_or_else(|| FfiError::Engine("the recogniser has been shut down".into()))?;
        engine
            .transcribe(&samples)
            .map_err(|error| FfiError::Engine(error.to_string()))
    }

    /// What it is running on, when that is worth saying.
    pub fn fallback_notice(&self) -> Option<String> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_ref()
            .and_then(|engine| engine.report().notice())
    }

    /// Drop the model before the process exits.
    ///
    /// Not tidiness: ggml's static destructors abort the process when a model is
    /// still alive at exit, and the person gets a crash report after a dictation
    /// that worked. Swift must call this from its termination handler.
    pub fn shutdown(&self) {
        if let Some(engine) = self
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
        {
            engine.shutdown();
        }
    }
}

// MARK: - History

/// One remembered dictation.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiHistoryEntry {
    pub id: String,
    /// Foundation's own reference date, so a file written by either side reads
    /// identically on the other.
    pub date: f64,
    pub text: String,
    pub audio_file_name: Option<String>,
}

#[uniffi::export]
pub fn load_history(directory: String) -> Vec<FfiHistoryEntry> {
    ramble_history::HistoryStore::new(&directory)
        .load()
        .into_iter()
        .map(|entry| FfiHistoryEntry {
            id: entry.id,
            date: entry.date.0,
            text: entry.text,
            audio_file_name: entry.audio_file_name,
        })
        .collect()
}

/// What went wrong, in a form Swift can catch.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{0}")]
    Manifest(String),
    #[error("{0}")]
    Engine(String),
}

// MARK: - Text

/// One dictionary entry. Mirrors [`DictionaryReplacement`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiReplacement {
    pub id: String,
    pub spoken: String,
    pub written: String,
    pub inflects: bool,
    pub no_acoustic_boost: bool,
    pub allows_phonetic_matching: bool,
}

impl From<FfiReplacement> for DictionaryReplacement {
    fn from(value: FfiReplacement) -> Self {
        DictionaryReplacement {
            id: value.id,
            spoken: value.spoken,
            written: value.written,
            inflects: value.inflects,
            no_acoustic_boost: value.no_acoustic_boost,
            allows_phonetic_matching: value.allows_phonetic_matching,
        }
    }
}

/// A command spoken at the end of a dictation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiTrailingCommand {
    PressReturn,
    NewLine,
}

/// A protected piece of the final text.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiSpan {
    pub kind: FfiSpanKind,
    pub start: u32,
    pub end: u32,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FfiSpanKind {
    Backticks,
    Path,
    Flag,
    Identifier,
}

/// What the pipeline produced.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiTextResult {
    pub text: String,
    pub command: Option<FfiTrailingCommand>,
    /// The state after the dictionary and before any cosmetics — the honest
    /// answer to "did the dictionary fire, or did the polisher move something?"
    pub after_dictionary: String,
    pub spans: Vec<FfiSpan>,
}

/// Run the text pipeline.
#[uniffi::export]
pub fn process_text(
    recognized: String,
    replacements: Vec<FfiReplacement>,
    allow_press_return_command: bool,
    phonetic_matching: bool,
) -> FfiTextResult {
    let pipeline = TextPipeline {
        replacements: replacements.into_iter().map(Into::into).collect(),
        allow_press_return_command,
        phonetic_matching,
    };
    let run = pipeline.run(&recognized);
    FfiTextResult {
        text: run.output.text,
        command: run.output.command.map(|command| match command {
            TrailingCommand::PressReturn => FfiTrailingCommand::PressReturn,
            TrailingCommand::NewLine => FfiTrailingCommand::NewLine,
        }),
        after_dictionary: run.provenance.after_dictionary,
        spans: run
            .provenance
            .spans
            .into_iter()
            .map(|span| FfiSpan {
                kind: match span.kind {
                    SpanKind::Backticks => FfiSpanKind::Backticks,
                    SpanKind::Path => FfiSpanKind::Path,
                    SpanKind::Flag => FfiSpanKind::Flag,
                    SpanKind::Identifier => FfiSpanKind::Identifier,
                },
                // Character offsets, not bytes — the whole pipeline counts in
                // characters, and Swift reading these must too.
                start: span.start as u32,
                end: span.end as u32,
                text: span.text,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_boundary_carries_the_same_answers_as_the_core() {
        assert!(state_is_capturing(FfiDictationState::Listening));
        assert!(!state_is_capturing(FfiDictationState::Preparing));
        assert_eq!(
            decide_stop(FfiDictationState::Preparing, false),
            FfiStopDecision::DeferUntilListening
        );
        assert!(!can_cancel(FfiDictationState::Inserting));
        assert_eq!(
            deadline_for_audio(Duration::from_secs(30)),
            Duration::from_secs(120)
        );
    }

    #[test]
    fn a_gesture_survives_the_round_trip() {
        let machine = FfiGestureMachine::new(Duration::from_millis(350));
        assert_eq!(
            machine.handle(true, true, true, Duration::ZERO),
            FfiGestureAction::Press
        );
        assert_eq!(
            machine.handle(true, false, false, Duration::from_millis(50)),
            FfiGestureAction::Release {
                after: Duration::from_millis(300)
            }
        );
        assert!(!machine.is_held());
    }

    #[test]
    fn text_crosses_with_its_spans_intact() {
        let result = process_text(
            "  \u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} TextPipeline.Output  ".to_string(),
            Vec::new(),
            false,
            true,
        );
        assert_eq!(
            result.text,
            "\u{0421}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} TextPipeline.Output"
        );
        assert_eq!(result.spans.len(), 1);
        assert_eq!(result.spans[0].kind, FfiSpanKind::Identifier);
        // Character offsets: the Cyrillic prefix is 6 characters, not 12 bytes.
        assert_eq!(result.spans[0].start, 7);
    }
}

//! One dictation, run.
//!
//! Everything decidable was decided in `ramble-core` and `ramble-text`; what
//! happens here is the calling. The order below is the product: press starts the
//! microphone, release stops it, and between the two nothing may be lost.

use crate::adapters::capture::Capture;
use crate::adapters::inject::{self, InjectError};
use crate::session::Outcome;
use crate::take::{Ending, KeyJob, Waiting};
use ramble_core::session::{Effect, Event, SessionMachine};
use ramble_engine::Engine;
use ramble_history::HistoryStore;
use ramble_model::{Manifest, ModelState, ModelStore};
use ramble_text::pipeline::TextPipeline;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

/// The model the Mac ships, Parakeet Ultra in Q4_K_M.
const MAC_MANIFEST: &str =
    include_str!("../../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

/// The same Ultra revision in Q8_0. Windows and Linux recognize on the CPU
/// backend, where Q4_K_M measured 1.29 times slower than v3 and Q8_0 within 3%
/// of it (`research/model-upgrade-2026-10/HYPOTHESES.md`, H13 and H13b).
const CPU_MANIFEST: &str = include_str!("../model-manifest.json");

/// A Mac running this app shares the Swift app's install, which is keyed by
/// model and revision rather than by file, so it must ask for the same file.
const SHIPPING_MANIFEST: &str = if cfg!(target_os = "macos") {
    MAC_MANIFEST
} else {
    CPU_MANIFEST
};

/// The application's own directory for things it keeps.
fn support_root() -> Option<PathBuf> {
    let models = models_root()?;
    // Models live inside it, so its parent is the root itself.
    models.parent().map(Path::to_path_buf)
}

/// Where installed models live on this platform.
///
/// The macOS path matches what the Swift app already uses, so a Mac running both
/// shares one model download rather than keeping two.
pub fn models_root() -> Option<PathBuf> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()?;
    Some(models_root_from(
        std::env::var("OPENRAMBLE_SUPPORT_ROOT").ok(),
        std::env::var("LOCALAPPDATA").ok(),
        std::env::var("XDG_DATA_HOME").ok(),
        PathBuf::from(home),
    ))
}

/// The same decision, with the environment handed in.
///
/// Split out so it can be tested without setting process-wide variables. Rust
/// tests share one environment across parallel threads, so a test that calls
/// `set_var` changes what every other test reads. That is not hypothetical: the
/// version of this that set the variable passed here and failed on Linux, purely
/// on which thread ran first.
pub fn models_root_from(
    support_root: Option<String>,
    local_app_data: Option<String>,
    xdg_data_home: Option<String>,
    home: PathBuf,
) -> PathBuf {
    if let Some(root) = support_root {
        return PathBuf::from(root).join("Models");
    }
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/OpenRamble/Models")
    } else if cfg!(windows) {
        // Local rather than roaming, so a corporate profile sync does not try to
        // copy 739 MB around.
        local_app_data
            .map(|local| PathBuf::from(local).join("OpenRamble/Models"))
            .unwrap_or_else(|| home.join("AppData/Local/OpenRamble/Models"))
    } else {
        xdg_data_home
            .map(|data| PathBuf::from(data).join("openramble/models"))
            .unwrap_or_else(|| home.join(".local/share/openramble/models"))
    }
}

/// How much audio a take actually contains.
///
/// Deliberately not the wall clock. The two differ in exactly the case the
/// silent-input rule exists for: a muted or occupied microphone returns nothing
/// while the clock keeps running, and by the clock that reads as a perfectly
/// good three-second take. It would go to the engine, come back empty, and the
/// person would be told nothing at all.
fn recorded_duration(sample_count: usize, rate: u32) -> std::time::Duration {
    if rate == 0 {
        return std::time::Duration::ZERO;
    }
    std::time::Duration::from_secs_f64(sample_count as f64 / rate as f64)
}

/// How finished words leave the app.
///
/// Handed in rather than called directly, so the rules about words that could
/// not land can be checked without pasting into whatever is in front of the
/// person running the tests.
pub struct Delivery {
    /// Borrow the clipboard, send the paste shortcut, give the clipboard back.
    pub paste: fn(&str) -> Result<(), InjectError>,
    /// Put the words on the clipboard and leave them there.
    pub copy: fn(&str) -> Result<(), InjectError>,
    /// Whether this desktop lets an application type into other windows at
    /// all. Where it does not, the clipboard is the delivery and the paste is
    /// the person's own.
    pub types_for_you: bool,
}

impl Delivery {
    fn system() -> Self {
        Delivery {
            paste: inject::insert,
            copy: inject::copy,
            types_for_you: session_types_for_you(),
        }
    }
}

fn session_types_for_you() -> bool {
    #[cfg(target_os = "linux")]
    {
        crate::adapters::linux_session::detect()
            .injection
            .types_for_you()
    }
    #[cfg(not(target_os = "linux"))]
    {
        true
    }
}

/// The running dictation service.
pub struct Dictation {
    machine: Mutex<SessionMachine>,
    capture: Mutex<Option<Capture>>,
    /// Loaded on the first dictation and kept.
    ///
    /// Kept, emphatically. Unloading between takes is what made the Mac slow and
    /// unpredictable: the next take pays a cold load, and a person cannot tell a
    /// cold load from a broken app.
    engine: Mutex<Option<Engine>>,
    pipeline: Mutex<TextPipeline>,
    store: ModelStore,
    history: HistoryStore,
    dictionary_directory: PathBuf,
    pub(crate) delivery: Delivery,
    /// Words that could not land. In memory only: they are in History as
    /// well, and keeping them anywhere else would be a third store.
    waiting: Mutex<Option<Waiting>>,
}

impl Dictation {
    pub fn new() -> Option<Self> {
        let manifest = Manifest::parse(SHIPPING_MANIFEST).ok()?;
        let store = ModelStore::new(manifest, models_root()?);
        // Anything an interrupted install left behind is settled before the
        // person is shown a state.
        let _ = store.recover_interrupted_promotion();
        let dictation = Dictation {
            machine: Mutex::new(SessionMachine::new()),
            capture: Mutex::new(None),
            engine: Mutex::new(None),
            // The supplied terms are on from the start, as they are on the
            // Mac. Someone dictating Russian with English terms should not have
            // to discover a dictionary before the product works for them.
            pipeline: Mutex::new(TextPipeline::with_replacements(
                ramble_text::starter::developer(),
            )),
            store,
            history: HistoryStore::new(support_root()?.join("History")),
            dictionary_directory: support_root()?,
            delivery: Delivery::system(),
            waiting: Mutex::new(None),
        };
        // Their own terms are in effect from the first dictation, not from the
        // first time they open settings.
        dictation.reload_pipeline();
        Some(dictation)
    }

    /// A dictation service that touches no clipboard and no keyboard, and has
    /// no model: whatever it is asked to deliver goes through `delivery`.
    #[cfg(test)]
    pub(crate) fn for_tests(delivery: Delivery) -> Self {
        let root = std::env::temp_dir().join("openramble-delivery-tests");
        Dictation {
            machine: Mutex::new(SessionMachine::new()),
            capture: Mutex::new(None),
            engine: Mutex::new(None),
            pipeline: Mutex::new(TextPipeline::default()),
            store: ModelStore::new(
                Manifest::parse(SHIPPING_MANIFEST).expect("the shipping manifest parses"),
                root.join("Models"),
            ),
            history: HistoryStore::new(root.join("History")),
            dictionary_directory: root,
            delivery,
            waiting: Mutex::new(None),
        }
    }

    /// Rebuild the pipeline from the supplied terms plus the person's own.
    fn reload_pipeline(&self) {
        let mut replacements = ramble_text::starter::developer();
        replacements.extend(self.personal_terms());
        *self
            .pipeline
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) =
            TextPipeline::with_replacements(replacements);
    }

    fn machine(&self) -> MutexGuard<'_, SessionMachine> {
        self.machine
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Feed the machine an event and carry out what it asks for.
    ///
    /// The machine decides; this only does. Keeping that split is what lets the
    /// rules be tested without a microphone — and what stops a second, subtly
    /// different copy of them growing here.
    fn advance(&self, event: Event) -> Vec<Effect> {
        let ready = self.model_is_ready();
        self.machine().handle(event, ready)
    }

    pub fn model_is_ready(&self) -> bool {
        self.store.state() == ModelState::Ready
    }

    pub fn model_state(&self) -> ModelState {
        self.store.state()
    }

    pub fn store(&self) -> &ModelStore {
        &self.store
    }

    /// The person's own replacements, as stored.
    pub fn personal_terms(&self) -> Vec<ramble_text::dictionary::DictionaryReplacement> {
        let Ok(bytes) = std::fs::read(self.dictionary_path()) else {
            return Vec::new();
        };
        serde_json::from_slice(&bytes).unwrap_or_default()
    }

    /// Store the person's replacements and put them into effect at once.
    ///
    /// Their own entries come after the supplied ones, so a person who disagrees
    /// with a shipped term simply wins: replacements layer, and the later rule
    /// rewrites what the earlier produced.
    pub fn set_personal_terms(&self, terms: Vec<(String, String)>) -> std::io::Result<()> {
        let entries: Vec<_> = terms
            .into_iter()
            .enumerate()
            .map(|(index, (spoken, written))| {
                ramble_text::dictionary::DictionaryReplacement::new(
                    format!("personal-{index}"),
                    spoken,
                    written,
                )
            })
            .collect();

        let path = self.dictionary_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(
            &path,
            serde_json::to_vec(&entries).map_err(std::io::Error::other)?,
        )?;

        self.reload_pipeline();
        Ok(())
    }

    fn dictionary_path(&self) -> PathBuf {
        self.dictionary_directory.join("dictionary.json")
    }

    pub fn history(&self) -> &HistoryStore {
        &self.history
    }

    /// How much a person is being asked to download, so the number can be shown
    /// before they commit to it rather than after.
    pub fn download_byte_count(&self) -> i64 {
        self.store.manifest.total_byte_count()
    }

    /// Begin recording.
    ///
    /// `accepted` runs once the take is certain to start and before the
    /// microphone is opened, which is the moment the take block appears: a
    /// press that starts nothing must not flash a block.
    pub fn begin(&self, accepted: impl FnOnce()) -> Result<(), String> {
        if self.advance(Event::Pressed).is_empty() {
            return Err(if self.model_is_ready() {
                "A dictation is already in progress.".into()
            } else {
                "The speech model is not installed yet.".into()
            });
        }
        accepted();

        match Capture::start() {
            Ok(capture) => {
                *self
                    .capture
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(capture);
                self.advance(Event::CaptureStarted);
                Ok(())
            }
            Err(error) => {
                self.advance(Event::CaptureFailed);
                Err(error.to_string())
            }
        }
    }

    /// Stop recording and produce the text.
    pub fn finish(&self, held: std::time::Duration) -> Outcome {
        self.advance(Event::Released { held });

        let taken = self
            .capture
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        let Some(capture) = taken else {
            self.advance(Event::CancelRequested);
            return Outcome::DroppedSilently;
        };

        let rate = capture.sample_rate();
        let (samples, truncated) = capture.finish();

        // How much audio there actually is, not how long the key was down. Those
        // differ in exactly the case the silent-input rule exists for: a muted or
        // occupied microphone returns nothing while the clock keeps running.
        let recorded = recorded_duration(samples.len(), rate);
        let effects = self.advance(Event::CaptureFinished {
            recorded,
            truncated,
        });

        if effects.contains(&Effect::FinishSilently) {
            return Outcome::DroppedSilently;
        }
        if effects.contains(&Effect::ReportSilentInput) {
            return Outcome::SilentInput;
        }

        let samples = match ramble_audio::resample(&samples, rate) {
            Ok(samples) => samples,
            Err(error) => return self.failed(error.to_string()),
        };
        let text = match self.transcribe(&samples) {
            Ok(text) => text,
            Err(error) => return self.failed(error),
        };

        let output = self
            .pipeline
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .process(&text);

        let effects = self.advance(Event::Transcribed {
            heard: !text.trim().is_empty(),
            is_empty: output.text.is_empty(),
        });
        if effects.contains(&Effect::FinishSilently) {
            return Outcome::DroppedSilently;
        }
        if effects.contains(&Effect::ReportTakenBack) {
            return self.keep_taken_back(&text, &samples);
        }

        // Recorded before insertion is attempted: if putting the text into the
        // other application fails, the words are the one thing that must not be
        // lost, and history is where a person goes to find them. A failed write
        // is not reported while the words are about to appear in the app. If
        // they cannot land either, the block that holds them says so.
        let kept = self.remember(&output.text, &samples).is_ok();

        if !self.land(output.text, !kept) {
            self.advance(Event::InsertionFailed);
            return Outcome::WordsWait;
        }
        self.advance(Event::Inserted);

        if truncated {
            Outcome::Truncated
        } else {
            Outcome::Inserted
        }
    }

    /// Keep a take whose every word cleanup took back.
    ///
    /// Nothing was inserted, so History is the only copy of what was heard. A
    /// write that fails is reported: telling the person the take was kept
    /// when it was not would discard it silently.
    fn keep_taken_back(&self, heard: &str, samples: &[f32]) -> Outcome {
        // What was heard, not what cleanup left: that is what a person
        // needs to undo a take-back they did not mean.
        match self.remember(heard, samples) {
            Ok(()) => Outcome::TakenBack,
            Err(_) => Outcome::Failed(
                "Nothing left to insert after cleanup, and the take couldn't be saved to History."
                    .into(),
            ),
        }
    }

    /// Put the words where the person was typing.
    ///
    /// `false` when they could not land. Then they wait, in full, and
    /// `waiting` has them.
    pub(crate) fn land(&self, words: String, kept_nowhere_else: bool) -> bool {
        let waiting = if self.delivery.types_for_you {
            match (self.delivery.paste)(&words) {
                Ok(()) => return true,
                Err(error) => Waiting::after_paste(&error, words, kept_nowhere_else),
            }
        } else {
            let copied = (self.delivery.copy)(&words).is_ok();
            Waiting::after_copy(copied, words, kept_nowhere_else)
        };
        *self.waiting_slot() = Some(waiting);
        false
    }

    fn waiting_slot(&self) -> MutexGuard<'_, Option<Waiting>> {
        self.waiting
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The words that wait, or `None` once they no longer do.
    pub fn waiting(&self) -> Option<Waiting> {
        self.waiting_slot().clone()
    }

    /// Do what the dictation key says while words wait: try the paste again,
    /// or copy where this desktop cannot type.
    ///
    /// `Some` once the words have landed, `None` while they still wait.
    /// Copied words have nothing left to try.
    pub fn retry_waiting(&self) -> Option<Ending> {
        let mut slot = self.waiting_slot();
        let waiting = slot.as_mut()?;
        if waiting.copied {
            return None;
        }
        match waiting.job {
            KeyJob::Paste => match (self.delivery.paste)(&waiting.words) {
                Ok(()) => {
                    *slot = None;
                    Some(Ending::Pasted)
                }
                Err(error) => {
                    let words = std::mem::take(&mut waiting.words);
                    *waiting = Waiting::after_paste(&error, words, waiting.kept_nowhere_else);
                    None
                }
            },
            KeyJob::Copy => {
                waiting.copied = (self.delivery.copy)(&waiting.words).is_ok();
                None
            }
        }
    }

    /// Let the waiting words leave the block, for Later or for a new take.
    ///
    /// They are in History already, so nothing more is needed, unless History
    /// could not keep them. Then they go to the clipboard first, and if that
    /// fails too they stay: the block is the only place they are, and
    /// dropping them would discard what the person said.
    ///
    /// `None` when nothing waits, or when the words cannot leave yet.
    pub fn release_waiting(&self) -> Option<Ending> {
        let mut slot = self.waiting_slot();
        let waiting = slot.as_ref()?;
        let ending = if !waiting.kept_nowhere_else {
            Ending::Kept
        } else if waiting.copied || (self.delivery.copy)(&waiting.words).is_ok() {
            Ending::Copied
        } else {
            return None;
        };
        *slot = None;
        Some(ending)
    }

    fn failed(&self, detail: String) -> Outcome {
        self.advance(Event::TranscriptionFailed);
        Outcome::Failed(detail)
    }

    /// Abandon the take without inserting anything.
    pub fn cancel(&self) {
        *self
            .capture
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
        self.advance(Event::CancelRequested);
    }

    /// Keep the take, with the audio that produced it.
    ///
    /// The caller decides what a failure means. Where the words are about to
    /// appear in the app, History is a convenience: losing it must never cost
    /// someone the dictation they just made, and an error about a bookkeeping
    /// file at that moment would be worse than the missing row. Where nothing
    /// is inserted, History is the only copy, and a failure has to be said.
    fn remember(&self, text: &str, samples: &[f32]) -> std::io::Result<()> {
        let limit = ramble_history::DEFAULT_LIMIT;
        let id = format!(
            "{:x}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|since| since.as_nanos())
                .unwrap_or(0)
        );

        let audio = std::env::temp_dir().join(format!("openramble-{id}.wav"));
        let recorded = ramble_audio::write_wav(&audio, samples, ramble_audio::ENGINE_SAMPLE_RATE);
        let source = recorded.is_ok().then_some(audio.as_path());

        let kept = self.history.record(
            text,
            source,
            limit,
            ramble_history::ReferenceDate::now(),
            id,
        );
        let _ = std::fs::remove_file(&audio);
        kept.map(|_| ())
    }

    fn transcribe(&self, samples: &[f32]) -> Result<String, String> {
        let mut slot = self
            .engine
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if slot.is_none() {
            let engine =
                Engine::load(&self.store.engine_directory()).map_err(|error| error.to_string())?;
            if let Some(notice) = engine.report().notice() {
                eprintln!("{notice}");
            }
            *slot = Some(engine);
        }
        slot.as_ref()
            .expect("just loaded")
            .transcribe(samples)
            .map_err(|error| error.to_string())
    }

    /// Drop the model before the process exits.
    ///
    /// ggml's static destructors abort with signal 6 when a model is still alive
    /// at exit, so quitting cleanly depends on this being called.
    pub fn shutdown(&self) {
        if let Some(engine) = self
            .engine
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
        {
            engine.shutdown();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Windows and Linux follow the Mac's model and revision, differing only
    /// in the file, and keep a mirror like every shipped manifest.
    #[test]
    fn the_cpu_manifest_is_the_macs_model_in_q8() {
        let mac = Manifest::parse(MAC_MANIFEST).expect("the Mac manifest must parse");
        let cpu = Manifest::parse(CPU_MANIFEST).expect("the CPU manifest must parse");
        assert_eq!(cpu.model_id, mac.model_id);
        assert_eq!(cpu.revision, mac.revision);
        assert_eq!(cpu.mirror, mac.mirror);
        assert_eq!(cpu.quantization, "Q8_0");
        assert_eq!(cpu.files.len(), 1);
        assert_eq!(cpu.files[0].path, "parakeet-ultra-Q8_0.gguf");
        assert_eq!(cpu.total_byte_count(), 740_363_168);
    }

    /// Quitting calls this from the tray menu, and the exit handler calls it
    /// again. Both paths exist on purpose — a person can quit either way — so
    /// the second call must be harmless rather than a double free of a model.
    #[test]
    fn shutdown_is_safe_with_no_engine_and_safe_twice() {
        let Some(dictation) = Dictation::new() else {
            eprintln!("no support directory; skipping");
            return;
        };
        dictation.shutdown();
        dictation.shutdown();
    }

    fn pastes(_: &str) -> Result<(), InjectError> {
        Ok(())
    }

    fn shortcut_not_sent(_: &str) -> Result<(), InjectError> {
        Err(InjectError::Keystroke("blocked".into()))
    }

    fn clipboard_unusable(_: &str) -> Result<(), InjectError> {
        Err(InjectError::Clipboard("busy".into()))
    }

    fn must_not_paste(_: &str) -> Result<(), InjectError> {
        panic!("a session that cannot type must never send a paste")
    }

    fn dictation_delivering(delivery: Delivery) -> Dictation {
        Dictation::for_tests(delivery)
    }

    fn typing(paste: fn(&str) -> Result<(), InjectError>) -> Delivery {
        Delivery {
            paste,
            copy: pastes,
            types_for_you: true,
        }
    }

    #[test]
    fn a_paste_that_lands_leaves_nothing_waiting() {
        let dictation = dictation_delivering(typing(pastes));
        assert!(dictation.land("Ship it Friday.".into(), false));
        assert_eq!(dictation.waiting(), None);
    }

    /// The clipboard is written before the shortcut is sent, so a shortcut
    /// that could not be sent leaves the words one paste away. The block says
    /// that, and the key has nothing left to do.
    #[test]
    fn a_shortcut_that_could_not_be_sent_leaves_the_words_copied() {
        let dictation = dictation_delivering(typing(shortcut_not_sent));
        assert!(!dictation.land("Ship it Friday.".into(), false));
        let waiting = dictation.waiting().expect("the words wait");
        assert_eq!(waiting.words, "Ship it Friday.");
        assert!(waiting.copied);
        assert_eq!(dictation.retry_waiting(), None);
        assert!(dictation.waiting().is_some(), "copied words stay put");
    }

    /// The whole of what a tap does: the same paste again. When it lands the
    /// words stop waiting; when it does not, they are still there, in full.
    #[test]
    fn a_tap_tries_the_paste_again_until_it_lands() {
        let mut dictation = dictation_delivering(typing(clipboard_unusable));
        assert!(!dictation.land("Ship it Friday.".into(), false));
        assert!(!dictation.waiting().expect("the words wait").copied);

        assert_eq!(dictation.retry_waiting(), None);
        assert_eq!(
            dictation.waiting().expect("still waiting").words,
            "Ship it Friday."
        );

        dictation.delivery.paste = pastes;
        assert_eq!(dictation.retry_waiting(), Some(Ending::Pasted));
        assert_eq!(dictation.waiting(), None);
    }

    /// Where the desktop forbids typing into other windows, a paste would be
    /// sent to nothing and the old clipboard put back over the words. The
    /// clipboard is the delivery there, and the paste is the person's own.
    #[test]
    fn a_session_that_cannot_type_copies_and_never_pastes() {
        let dictation = dictation_delivering(Delivery {
            paste: must_not_paste,
            copy: pastes,
            types_for_you: false,
        });
        assert!(!dictation.land("Ship it Friday.".into(), false));
        let waiting = dictation.waiting().expect("the words wait");
        assert!(waiting.copied);
        assert_eq!(waiting.job, KeyJob::Copy);
    }

    #[test]
    fn where_the_copy_failed_a_tap_copies_again() {
        let mut dictation = dictation_delivering(Delivery {
            paste: must_not_paste,
            copy: clipboard_unusable,
            types_for_you: false,
        });
        assert!(!dictation.land("Ship it Friday.".into(), false));
        assert!(!dictation.waiting().expect("the words wait").copied);

        dictation.delivery.copy = pastes;
        assert_eq!(dictation.retry_waiting(), None);
        assert!(dictation.waiting().expect("still on the block").copied);
    }

    /// Later is a promise that the words are somewhere. In History when
    /// History kept them; on the clipboard when it could not; and if neither,
    /// they do not leave the block.
    #[test]
    fn words_leave_the_block_only_for_somewhere_they_can_be_found() {
        let dictation = dictation_delivering(typing(clipboard_unusable));
        dictation.land("Ship it Friday.".into(), false);
        assert_eq!(dictation.release_waiting(), Some(Ending::Kept));
        assert_eq!(dictation.waiting(), None);
        assert_eq!(dictation.release_waiting(), None, "nothing waits now");

        let mut unkept = dictation_delivering(typing(clipboard_unusable));
        unkept.delivery.copy = clipboard_unusable;
        unkept.land("Ship it Friday.".into(), true);
        assert_eq!(unkept.release_waiting(), None);
        assert_eq!(
            unkept.waiting().expect("they must not be dropped").words,
            "Ship it Friday."
        );

        unkept.delivery.copy = pastes;
        assert_eq!(unkept.release_waiting(), Some(Ending::Copied));
        assert_eq!(unkept.waiting(), None);
    }

    fn dictation_keeping_history_in(history: PathBuf, root: &Path) -> Dictation {
        Dictation {
            machine: Mutex::new(SessionMachine::new()),
            capture: Mutex::new(None),
            engine: Mutex::new(None),
            pipeline: Mutex::new(TextPipeline::default()),
            store: ModelStore::new(
                Manifest::parse(SHIPPING_MANIFEST).expect("the shipping manifest parses"),
                root.join("Models"),
            ),
            history: HistoryStore::new(history),
            dictionary_directory: root.to_path_buf(),
            delivery: typing(pastes),
            waiting: Mutex::new(None),
        }
    }

    /// A take whose every word cleanup took back inserts nothing, so History
    /// is the only copy of what was heard. A write that fails is said, never
    /// swallowed: the person must not be told the take is kept when it is not.
    #[test]
    fn a_taken_back_take_history_cannot_keep_is_reported_not_dropped() {
        let root = std::env::temp_dir().join(format!(
            "openramble-taken-back-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        // A file where the History folder belongs: nothing can be written there.
        let blocked = root.join("Blocked");
        std::fs::write(&blocked, b"not a folder").unwrap();
        let samples = [0.0_f32; 1_600];

        let failing = dictation_keeping_history_in(blocked, &root);
        assert!(
            matches!(
                failing.keep_taken_back("Ship it Friday. Scratch that.", &samples),
                Outcome::Failed(_)
            ),
            "a take-back History could not keep must not read as kept"
        );

        let kept = dictation_keeping_history_in(root.join("History"), &root);
        assert_eq!(
            kept.keep_taken_back("Ship it Friday. Scratch that.", &samples),
            Outcome::TakenBack
        );
        assert_eq!(kept.history().load().len(), 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    /// A held key with a silent microphone must read as no audio, not as a
    /// take as long as the hold.
    #[test]
    fn a_microphone_that_gave_nothing_reads_as_nothing() {
        assert_eq!(recorded_duration(0, 48_000), std::time::Duration::ZERO);
        assert_eq!(
            recorded_duration(48_000, 48_000),
            std::time::Duration::from_secs(1)
        );
        // A device that reported no rate cannot divide; zero, not a panic.
        assert_eq!(recorded_duration(1_000, 0), std::time::Duration::ZERO);
    }

    #[test]
    fn the_models_root_is_per_platform_and_absolute() {
        let root = models_root().expect("a home directory must resolve");
        assert!(root.is_absolute(), "{}", root.display());
        assert!(
            root.to_string_lossy().to_lowercase().contains("openramble"),
            "{}",
            root.display()
        );
    }

    /// A Mac running both apps must share one model download, not keep two.
    #[cfg(target_os = "macos")]
    #[test]
    fn macos_uses_the_same_location_as_the_swift_app() {
        let root = models_root().unwrap();
        assert!(
            root.ends_with("Library/Application Support/OpenRamble/Models"),
            "{}",
            root.display()
        );
    }

    /// The same override the Mac app uses, so a debug launch cannot touch a
    /// person's real install.
    ///
    /// Handed in rather than set on the process: the version of this test that
    /// used `set_var` broke a different test depending on which thread ran
    /// first, and did it only on Linux.
    #[test]
    fn an_explicit_support_root_is_honoured_for_isolated_runs() {
        assert_eq!(
            models_root_from(
                Some("/tmp/isolated-run".into()),
                None,
                None,
                PathBuf::from("/home/someone")
            ),
            PathBuf::from("/tmp/isolated-run/Models")
        );
    }

    #[test]
    fn without_an_override_the_location_is_under_the_home_directory() {
        let root = models_root_from(None, None, None, PathBuf::from("/home/someone"));
        assert!(root.starts_with("/home/someone"), "{}", root.display());
        assert!(
            root.to_string_lossy().to_lowercase().contains("openramble"),
            "{}",
            root.display()
        );
    }
}

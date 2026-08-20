//! One dictation, run.
//!
//! Everything decidable was decided in `ramble-core` and `ramble-text`; what
//! happens here is the calling. The order below is the product: press starts the
//! microphone, release stops it, and between the two nothing may be lost.

use crate::adapters::capture::Capture;
use crate::adapters::inject;
use crate::session::Outcome;
use ramble_core::session::{Effect, Event, SessionMachine};
use ramble_engine::Engine;
use ramble_history::HistoryStore;
use ramble_model::{Manifest, ModelState, ModelStore};
use ramble_text::pipeline::TextPipeline;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex, MutexGuard};

const SHIPPING_MANIFEST: &str =
    include_str!("../../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

/// The application's own directory for things it keeps.
fn support_root() -> Option<PathBuf> {
    let models = models_root()?;
    // Models live inside it, so its parent is the root itself.
    models.parent().map(Path::to_path_buf)
}

/// Where installed models live on this platform.
///
/// The macOS path matches what the Swift app already uses, so a Mac running both
/// shares one 739 MB download rather than keeping two.
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
    history: Arc<Mutex<HistoryStore>>,
    history_writer: HistoryWriter,
    dictionary_directory: PathBuf,
}

impl Dictation {
    pub fn new() -> Result<Self, String> {
        let manifest = Manifest::parse(SHIPPING_MANIFEST).map_err(|error| error.to_string())?;
        let store = ModelStore::new(
            manifest,
            models_root()
                .ok_or_else(|| "OpenRamble could not resolve its model directory.".to_string())?,
        );
        let root = support_root()
            .ok_or_else(|| "OpenRamble could not resolve its support directory.".to_string())?;
        let history = Arc::new(Mutex::new(HistoryStore::new(root.join("History"))));
        // Anything an interrupted install left behind is settled before the
        // person is shown a state.
        store.recover_interrupted_promotion().map_err(|error| {
            format!("The interrupted model install could not be recovered: {error}")
        })?;
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
            history: Arc::clone(&history),
            history_writer: HistoryWriter::new(history),
            dictionary_directory: root,
        };
        // Their own terms are in effect from the first dictation, not from the
        // first time they open settings.
        dictation
            .reload_pipeline()
            .map_err(|error| format!("The personal dictionary could not be loaded: {error}"))?;
        Ok(dictation)
    }

    /// Rebuild the pipeline from the supplied terms plus the person's own.
    fn reload_pipeline(&self) -> std::io::Result<()> {
        let mut replacements = ramble_text::starter::developer();
        replacements.extend(self.personal_terms()?);
        *self
            .pipeline
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) =
            TextPipeline::with_replacements(replacements);
        Ok(())
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
    pub fn personal_terms(
        &self,
    ) -> std::io::Result<Vec<ramble_text::dictionary::DictionaryReplacement>> {
        let bytes = match std::fs::read(self.dictionary_path()) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        parse_personal_terms(&bytes)
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
        let json = serde_json::to_vec(&entries).map_err(std::io::Error::other)?;
        let parent = path
            .parent()
            .ok_or_else(|| std::io::Error::other("the dictionary path has no parent directory"))?;
        let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
        temporary.write_all(&json)?;
        temporary.as_file().sync_all()?;
        temporary.persist(&path).map_err(|error| error.error)?;

        self.reload_pipeline()?;
        Ok(())
    }

    fn dictionary_path(&self) -> PathBuf {
        self.dictionary_directory.join("dictionary.json")
    }

    pub fn history_entries(&self) -> std::io::Result<Vec<ramble_history::HistoryEntry>> {
        self.history
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .try_load()
    }

    pub fn history_has_audio(&self, entry: &ramble_history::HistoryEntry) -> bool {
        self.history
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .audio_path(entry)
            .is_some()
    }

    pub fn delete_history_entry(&self, id: &str) -> std::io::Result<()> {
        self.history
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .delete(id)
            .map(|_| ())
    }

    pub fn clear_history(&self) -> std::io::Result<()> {
        self.history
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .delete_all()
    }

    /// How much a person is being asked to download, so the number can be shown
    /// before they commit to it rather than after.
    pub fn download_byte_count(&self) -> i64 {
        self.store.manifest.total_byte_count()
    }

    /// Begin recording.
    pub fn begin(&self) -> Result<(), String> {
        if self.advance(Event::Pressed).is_empty() {
            return Err(if self.model_is_ready() {
                "A dictation is already in progress.".into()
            } else {
                "The speech model is not installed yet.".into()
            });
        }

        match Capture::start() {
            Ok(capture) => {
                *self
                    .capture
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(capture);
                self.advance(Event::CaptureStarted);
                // Warm the resident recognizer while speech is arriving. This
                // runs on the lifecycle worker, never the keyboard callback or
                // UI thread. Release is already admitted independently and
                // waits behind this command, so a cold model cannot lose the
                // end of a short gesture.
                if let Err(error) = self.prepare_engine() {
                    *self
                        .capture
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
                    self.advance(Event::TranscriptionFailed);
                    return Err(error);
                }
                Ok(())
            }
            Err(error) => {
                self.advance(Event::CaptureFailed);
                Err(error.to_string())
            }
        }
    }

    /// Stop recording and produce the text.
    pub fn finish_with<F>(&self, held: std::time::Duration, insert: F) -> Outcome
    where
        F: FnOnce(&str) -> Result<(), String>,
    {
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
        let (samples, truncated) = match capture.finish() {
            Ok(recording) => recording,
            Err(error) => return self.failed(error.to_string()),
        };

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

        if self
            .advance(Event::Transcribed {
                is_empty: output.text.is_empty(),
            })
            .contains(&Effect::FinishSilently)
        {
            return Outcome::DroppedSilently;
        }

        // Hand persistence its own copy of ownership before insertion, but do
        // not wait for disk. If paste fails the history worker still has the
        // words; if the disk is under pressure the words still reach the field.
        if let Err(error) = self.remember(output.text.clone(), samples) {
            eprintln!("The dictation could not be queued for history: {error}");
        }

        if let Err(error) = insert(&output.text) {
            self.advance(Event::InsertionFailed);
            return Outcome::Failed(error);
        }
        self.advance(Event::Inserted);

        if truncated {
            Outcome::Truncated
        } else {
            Outcome::Inserted
        }
    }

    /// Stop recording and insert from the current thread.
    ///
    /// Kept for non-GUI callers. The Tauri shell uses [`Self::finish_with`] to
    /// schedule platform UI work on the main thread.
    pub fn finish(&self, held: std::time::Duration) -> Outcome {
        self.finish_with(held, |text| {
            inject::insert(text).map_err(|error| error.to_string())
        })
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
    fn remember(&self, text: String, samples: Vec<f32>) -> Result<(), String> {
        self.history_writer.record(text, samples)
    }

    fn transcribe(&self, samples: &[f32]) -> Result<String, String> {
        self.prepare_engine()?;
        let slot = self
            .engine
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        slot.as_ref()
            .expect("prepare_engine returned with a loaded engine")
            .transcribe(samples)
            .map_err(|error| error.to_string())
    }

    fn prepare_engine(&self) -> Result<(), String> {
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
        Ok(())
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
        self.history_writer.shutdown();
    }
}

enum HistoryMessage {
    Record { text: String, samples: Vec<f32> },
    Shutdown,
}

/// A single bounded persistence lane.
///
/// One writer prevents two quick dictations from racing on `history.json`.
/// Capacity two is enough for the normal case and finite under a stalled disk;
/// overload is returned and reported instead of consuming unbounded memory.
struct HistoryWriter {
    sender: Mutex<Option<mpsc::SyncSender<HistoryMessage>>>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
}

impl HistoryWriter {
    fn new(history: Arc<Mutex<HistoryStore>>) -> Self {
        let (sender, receiver) = mpsc::sync_channel(2);
        let thread = std::thread::Builder::new()
            .name("openramble-history".into())
            .spawn(move || {
                while let Ok(message) = receiver.recv() {
                    match message {
                        HistoryMessage::Record { text, samples } => {
                            if let Err(error) = persist_history(&history, &text, &samples) {
                                eprintln!("The dictation history could not be saved: {error}");
                            }
                        }
                        HistoryMessage::Shutdown => return,
                    }
                }
            })
            .expect("the history persistence thread could not start");
        Self {
            sender: Mutex::new(Some(sender)),
            thread: Mutex::new(Some(thread)),
        }
    }

    fn record(&self, text: String, samples: Vec<f32>) -> Result<(), String> {
        let sender = self
            .sender
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(sender) = sender.as_ref() else {
            return Err("history persistence is already shut down".into());
        };
        sender
            .try_send(HistoryMessage::Record { text, samples })
            .map_err(|error| match error {
                mpsc::TrySendError::Full(_) => {
                    "the bounded history queue is full because disk writes are delayed".into()
                }
                mpsc::TrySendError::Disconnected(_) => {
                    "the history persistence worker stopped".into()
                }
            })
    }

    fn shutdown(&self) {
        let sender = self
            .sender
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        let Some(sender) = sender else {
            return;
        };
        // Finish already accepted records before releasing process resources.
        if sender.send(HistoryMessage::Shutdown).is_err() {
            eprintln!("The history persistence worker stopped before shutdown completed.");
        }
        drop(sender);
        if let Some(thread) = self
            .thread
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
        {
            if thread.join().is_err() {
                eprintln!("The history persistence worker stopped unexpectedly during shutdown.");
            }
        }
    }
}

fn persist_history(
    history: &Arc<Mutex<HistoryStore>>,
    text: &str,
    samples: &[f32],
) -> std::io::Result<()> {
    let id = format!(
        "{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|since| since.as_nanos())
            .unwrap_or(0)
    );
    let audio = std::env::temp_dir().join(format!("openramble-{id}.wav"));
    ramble_audio::write_wav(&audio, samples, ramble_audio::ENGINE_SAMPLE_RATE)
        .map_err(std::io::Error::other)?;
    let result = history
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .record(
            text,
            Some(&audio),
            ramble_history::DEFAULT_LIMIT,
            ramble_history::ReferenceDate::now(),
            id,
        )
        .map(|_| ());
    let cleanup = std::fs::remove_file(&audio);
    result.and(cleanup)
}

fn parse_personal_terms(
    bytes: &[u8],
) -> std::io::Result<Vec<ramble_text::dictionary::DictionaryReplacement>> {
    serde_json::from_slice(bytes).map_err(std::io::Error::other)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_corrupt_personal_dictionary_is_reported_instead_of_erased_in_memory() {
        let error = parse_personal_terms(b"{not json").expect_err("corruption must be visible");
        assert_eq!(error.kind(), std::io::ErrorKind::Other);
    }

    /// Quitting calls this from the tray menu, and the exit handler calls it
    /// again. Both paths exist on purpose — a person can quit either way — so
    /// the second call must be harmless rather than a double free of a model.
    #[test]
    fn shutdown_is_safe_with_no_engine_and_safe_twice() {
        let Ok(dictation) = Dictation::new() else {
            eprintln!("no support directory; skipping");
            return;
        };
        dictation.shutdown();
        dictation.shutdown();
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

    /// A Mac running both apps must share one 739 MB download, not keep two.
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

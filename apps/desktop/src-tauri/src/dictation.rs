//! One dictation, run.
//!
//! Everything decidable was decided in `ramble-core` and `ramble-text`; what
//! happens here is the calling. The order below is the product: press starts the
//! microphone, release stops it, and between the two nothing may be lost.

use crate::adapters::capture::Capture;
use crate::adapters::inject;
use crate::session::{outcome_for_recording, Outcome};
use ramble_core::session::DictationState;
use ramble_engine::Engine;
use ramble_model::{Manifest, ModelState, ModelStore};
use ramble_text::pipeline::TextPipeline;
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use std::time::Instant;

const SHIPPING_MANIFEST: &str =
    include_str!("../../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

/// Where installed models live on this platform.
///
/// The macOS path matches what the Swift app already uses, so a Mac running both
/// shares one 739 MB download rather than keeping two.
pub fn models_root() -> Option<PathBuf> {
    if let Ok(root) = std::env::var("OPENRAMBLE_SUPPORT_ROOT") {
        return Some(PathBuf::from(root).join("Models"));
    }
    let home = PathBuf::from(
        std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .ok()?,
    );
    Some(if cfg!(target_os = "macos") {
        home.join("Library/Application Support/OpenRamble/Models")
    } else if cfg!(windows) {
        // %APPDATA% proper, so the model is not in a roaming profile that a
        // corporate sync would try to copy 739 MB of.
        std::env::var("LOCALAPPDATA")
            .map(|local| PathBuf::from(local).join("OpenRamble/Models"))
            .unwrap_or_else(|_| home.join("AppData/Local/OpenRamble/Models"))
    } else {
        std::env::var("XDG_DATA_HOME")
            .map(|data| PathBuf::from(data).join("openramble/models"))
            .unwrap_or_else(|_| home.join(".local/share/openramble/models"))
    })
}

/// The running dictation service.
pub struct Dictation {
    state: Mutex<DictationState>,
    capture: Mutex<Option<(Capture, Instant)>>,
    /// Loaded on the first dictation and kept.
    ///
    /// Kept, emphatically. Unloading between takes is what made the Mac slow and
    /// unpredictable: the next take pays a cold load, and a person cannot tell a
    /// cold load from a broken app.
    engine: Mutex<Option<Engine>>,
    pipeline: Mutex<TextPipeline>,
    store: ModelStore,
}

impl Dictation {
    pub fn new() -> Option<Self> {
        let manifest = Manifest::parse(SHIPPING_MANIFEST).ok()?;
        let store = ModelStore::new(manifest, models_root()?);
        // Anything an interrupted install left behind is settled before the
        // person is shown a state.
        let _ = store.recover_interrupted_promotion();
        Some(Dictation {
            state: Mutex::new(DictationState::Idle),
            capture: Mutex::new(None),
            engine: Mutex::new(None),
            pipeline: Mutex::new(TextPipeline::default()),
            store,
        })
    }

    fn state(&self) -> MutexGuard<'_, DictationState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn current_state(&self) -> DictationState {
        *self.state()
    }

    pub fn model_is_ready(&self) -> bool {
        self.store.state() == ModelState::Ready
    }

    pub fn model_state(&self) -> ModelState {
        self.store.state()
    }

    /// Begin recording.
    pub fn begin(&self) -> Result<(), String> {
        if !crate::session::may_start(self.current_state(), self.model_is_ready()) {
            return Err(if self.model_is_ready() {
                "A dictation is already in progress.".into()
            } else {
                "The speech model is not installed yet.".into()
            });
        }

        *self.state() = DictationState::Preparing;
        match Capture::start() {
            Ok(capture) => {
                *self
                    .capture
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                    Some((capture, Instant::now()));
                *self.state() = DictationState::Listening;
                Ok(())
            }
            Err(error) => {
                // The microphone never opened, so the session must not be left
                // sitting in Preparing with no way back to Idle.
                *self.state() = DictationState::Idle;
                Err(error.to_string())
            }
        }
    }

    /// Stop recording and produce the text.
    pub fn finish(&self, held: std::time::Duration) -> Outcome {
        let taken = self
            .capture
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        let Some((capture, started)) = taken else {
            *self.state() = DictationState::Idle;
            return Outcome::DroppedSilently;
        };

        *self.state() = DictationState::Transcribing;
        let rate = capture.sample_rate();
        let (samples, truncated) = capture.finish();
        let recorded = started.elapsed();

        let finish = |outcome| {
            *self.state() = DictationState::Idle;
            outcome
        };

        if let Some(short) = outcome_for_recording(recorded, held, truncated) {
            return finish(short);
        }

        let samples = match ramble_audio::resample(&samples, rate) {
            Ok(samples) => samples,
            Err(error) => return finish(Outcome::Failed(error.to_string())),
        };

        let text = match self.transcribe(&samples) {
            Ok(text) => text,
            Err(error) => return finish(Outcome::Failed(error)),
        };

        let output = self
            .pipeline
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .process(&text);

        if output.text.is_empty() {
            // Nothing was said. Silence is the honest answer; an error would
            // suggest a fault that is not there.
            return finish(Outcome::DroppedSilently);
        }

        *self.state() = DictationState::Inserting;
        if let Err(error) = inject::insert(&output.text) {
            return finish(Outcome::Failed(error.to_string()));
        }

        finish(if truncated {
            Outcome::Truncated(output.text)
        } else {
            Outcome::Inserted(output.text)
        })
    }

    /// Abandon the take without inserting anything.
    pub fn cancel(&self) {
        *self
            .capture
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
        *self.state() = DictationState::Idle;
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

    #[test]
    fn an_explicit_support_root_is_honoured_for_isolated_runs() {
        // The same override the Mac app uses, so a debug launch cannot touch a
        // person's real install.
        let previous = std::env::var("OPENRAMBLE_SUPPORT_ROOT").ok();
        std::env::set_var("OPENRAMBLE_SUPPORT_ROOT", "/tmp/isolated-run");
        assert_eq!(
            models_root().unwrap(),
            PathBuf::from("/tmp/isolated-run/Models")
        );
        match previous {
            Some(value) => std::env::set_var("OPENRAMBLE_SUPPORT_ROOT", value),
            None => std::env::remove_var("OPENRAMBLE_SUPPORT_ROOT"),
        }
    }
}

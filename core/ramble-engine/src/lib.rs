//! The recognizer.
//!
//! The only crate in this workspace that touches the inference runtime, mirroring
//! the rule the Mac already keeps: exactly one file may import it, so the blast
//! radius of a runtime change is one place.
//!
//! What the shipping Mac app learned the hard way, kept here:
//!
//! - **Slowness must never become failure.** A model that took a long time
//!   because the machine was busy is still working. Killing the take discards the
//!   loaded model, which makes the next take colder and slower still — a spiral
//!   the person cannot escape. Cancellation exists for a person who pressed
//!   Escape, not for a clock.
//! - **The model must be gone before the process exits.** ggml's static
//!   destructors abort — signal 6, a crash report — if a model is still alive at
//!   `exit()`. See [`Engine::shutdown`].
//! - **A fallback is announced, never silent.** Running on the CPU because the
//!   GPU was unavailable is a fact the person is entitled to, since it is the
//!   difference between two seconds and twenty.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use transcribe_cpp::{Backend, Model, ModelOptions, RunOptions, Session, TimestampKind};

mod report;
pub use report::{BackendReport, Compiled};

#[derive(Debug)]
pub enum EngineError {
    /// The model directory holds no loadable model.
    NoModel(PathBuf),
    Load(String),
    Run(String),
    /// The person pressed Escape.
    Cancelled,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::NoModel(path) => {
                write!(f, "no model file in {}", path.display())
            }
            EngineError::Load(detail) => write!(f, "the recognizer could not start: {detail}"),
            EngineError::Run(detail) => write!(f, "the recognition failed: {detail}"),
            EngineError::Cancelled => write!(f, "cancelled"),
        }
    }
}

impl std::error::Error for EngineError {}

/// A loaded recognizer.
///
/// The session is behind a mutex because the runtime's session is `Send` but not
/// `Sync`, and because two takes must not decode through one session at once.
/// Dictation is inherently one-at-a-time, so the lock is never contended in
/// practice; it exists to make that a compile-time fact rather than a hope.
pub struct Engine {
    session: Mutex<Session>,
    /// Kept alive alongside the session, and dropped after it: the session
    /// borrows the model's tensors.
    _model: Model,
    report: BackendReport,
}

impl Engine {
    /// Load the model in a directory.
    ///
    /// The runtime wants a file, the installer produces a directory, so the
    /// single `.gguf` inside is found here rather than making every caller know
    /// the filename.
    pub fn load(model_directory: &Path) -> Result<Self, EngineError> {
        install_logging_policy();
        let model_path = find_model_file(model_directory)
            .ok_or_else(|| EngineError::NoModel(model_directory.to_path_buf()))?;

        let requested = preferred_backend();
        let (model, active) = load_with_fallback(&model_path, requested)?;

        let report = BackendReport::new(requested, &model, active);
        let session = model
            .session()
            .map_err(|error| EngineError::Load(error.to_string()))?;

        Ok(Engine {
            session: Mutex::new(session),
            _model: model,
            report,
        })
    }

    /// What the recognizer is actually running on.
    pub fn report(&self) -> &BackendReport {
        &self.report
    }

    /// Recognize 16 kHz mono audio.
    ///
    /// Short clips are padded before the runtime sees them — the mel front-end
    /// emits NaNs on anything under two frames.
    pub fn transcribe(&self, samples: &[f32]) -> Result<String, EngineError> {
        let prepared = ramble_audio::prepare_for_engine(samples);

        let options = RunOptions {
            // Timestamps cost decoding work and nothing in this product reads
            // them: the text goes straight into somebody else's text field.
            timestamps: TimestampKind::None,
            ..Default::default()
        };

        let mut session = self
            .session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let transcript = session
            .run(&prepared, &options)
            .map_err(|error| EngineError::Run(error.to_string()))?;
        if session.was_aborted() {
            return Err(EngineError::Cancelled);
        }
        Ok(transcript.text)
    }

    /// Drop the model before the process exits.
    ///
    /// Not tidiness. ggml registers static destructors that abort the process —
    /// signal 6, a crash report on the person's screen — when a model is still
    /// alive as `exit()` runs. The app quitting cleanly after a dictation
    /// depends on this being called, and it is why `Engine` is not simply left
    /// to the allocator at shutdown.
    pub fn shutdown(self) {
        drop(self);
    }
}

/// Decide once what the runtime is allowed to print.
///
/// Silent by default. The runtime narrates every Metal kernel it compiles
/// straight to stderr, which on a person's machine is dozens of lines of noise
/// per dictation and tells them nothing they can act on — and a dictation tool
/// that chatters into the system log looks broken even when it is not.
///
/// `OPENRAMBLE_ENGINE_LOG=1` turns it back on, matching how the Mac app gates
/// its own diagnostics: available when something is being investigated, absent
/// from the build people actually use.
fn install_logging_policy() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let wanted = std::env::var("OPENRAMBLE_ENGINE_LOG")
            .map(|value| value == "1" || value.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        if wanted {
            transcribe_cpp::init_logging();
        } else {
            transcribe_cpp::disable_logging();
        }
    });
}

/// The accelerator this platform should ask for.
///
/// Asking by name rather than taking `Auto` so the answer is a decision recorded
/// here, and so a machine that cannot honour it produces a report instead of a
/// quiet demotion.
fn preferred_backend() -> Backend {
    if cfg!(target_os = "macos") {
        Backend::Metal
    } else {
        Backend::Vulkan
    }
}

/// Load on the preferred accelerator, falling back to the CPU.
///
/// The fallback is real and necessary — a Linux box with no Vulkan driver, a VM
/// with no GPU passthrough — but it is never silent. The active backend is
/// carried out so the interface can say so.
fn load_with_fallback(path: &Path, requested: Backend) -> Result<(Model, Backend), EngineError> {
    let options = ModelOptions {
        backend: requested,
        device: None,
    };
    match Model::load_with(path, &options) {
        Ok(model) => Ok((model, requested)),
        Err(accelerator_error) => {
            let cpu = ModelOptions {
                backend: Backend::Cpu,
                device: None,
            };
            match Model::load_with(path, &cpu) {
                Ok(model) => Ok((model, Backend::Cpu)),
                // Report the accelerator's failure, not the CPU's: the first is
                // what the person can act on.
                Err(_) => Err(EngineError::Load(accelerator_error.to_string())),
            }
        }
    }
}

/// The single `.gguf` in a directory.
fn find_model_file(directory: &Path) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = std::fs::read_dir(directory)
        .ok()?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|extension| extension.eq_ignore_ascii_case("gguf"))
        })
        .collect();
    // Sorted so a directory that somehow holds two produces the same answer on
    // every launch rather than whatever the filesystem enumerated first.
    candidates.sort();
    candidates.into_iter().next()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_directory_without_a_model_says_so_rather_than_panicking() {
        let directory = tempfile::tempdir().unwrap();
        assert!(matches!(
            Engine::load(directory.path()),
            Err(EngineError::NoModel(_))
        ));
    }

    #[test]
    fn the_model_file_is_found_by_extension_and_chosen_deterministically() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("notes.txt"), b"x").unwrap();
        assert_eq!(find_model_file(directory.path()), None);

        std::fs::write(directory.path().join("b-model.gguf"), b"x").unwrap();
        std::fs::write(directory.path().join("a-model.gguf"), b"x").unwrap();
        // The same answer every launch, not whatever the filesystem listed first.
        assert_eq!(
            find_model_file(directory.path())
                .unwrap()
                .file_name()
                .unwrap(),
            "a-model.gguf"
        );
    }

    #[test]
    fn each_platform_asks_for_its_own_accelerator() {
        if cfg!(target_os = "macos") {
            assert_eq!(preferred_backend(), Backend::Metal);
        } else {
            assert_eq!(preferred_backend(), Backend::Vulkan);
        }
    }
}

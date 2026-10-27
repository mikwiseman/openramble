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

use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use transcribe_cpp::{
    Backend, Model, ModelOptions, RunOptions, Session, SessionOptions, TimestampKind,
};

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

/// One recognized word and where it lies in the clip, in milliseconds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Word {
    pub text: String,
    pub start_ms: u32,
    pub end_ms: u32,
}

/// The text of a clip with its words and their times.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Recognized {
    /// Exactly what [`Engine::transcribe`] returns for the same clip.
    pub text: String,
    /// The raw words in order, each trimmed and never empty.
    pub words: Vec<Word>,
    /// The decode hit the runtime's output budget; the words are what came
    /// before it.
    pub truncated: bool,
}

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
        let model_path = model_file(model_directory)
            .ok_or_else(|| EngineError::NoModel(model_directory.to_path_buf()))?;

        let requested = preferred_backend();
        let (model, active) = load_with_fallback(&model_path, requested)?;

        let report = BackendReport::new(requested, &model, active);
        // Match the shipping macOS adapter. Parakeet's CPU predictor installs
        // a spin/yield barrier for every graph node at two or more threads;
        // one thread removes that pressure-sensitive synchronization while
        // the Metal/Vulkan encoder keeps its own parallelism.
        // Intel macOS also runs the encoder on the CPU, so it uses four threads.
        let session = model
            .session_with(&SessionOptions {
                n_threads: if cfg!(all(target_os = "macos", target_arch = "x86_64")) {
                    4
                } else {
                    1
                },
                ..SessionOptions::default()
            })
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
    /// emits NaNs on anything under two frames — and long ones are cut into
    /// runs of at most [`MAX_RUN_SAMPLES`].
    pub fn transcribe(&self, samples: &[f32]) -> Result<String, EngineError> {
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
        let mut texts = Vec::new();
        for run in runs(samples) {
            let prepared = ramble_audio::prepare_for_engine(&samples[run]);
            let transcript = session
                .run(&prepared, &options)
                .map_err(|error| EngineError::Run(error.to_string()))?;
            if session.was_aborted() {
                return Err(EngineError::Cancelled);
            }
            texts.push(transcript.text);
        }
        Ok(joined(texts))
    }

    /// Recognize 16 kHz mono audio and say where each word lies.
    ///
    /// The text is the same as [`Engine::transcribe`] gives: Parakeet builds
    /// its words either way and only drops them when no times were asked for.
    /// Padding goes at the end of a short clip, so it moves no time; times are
    /// clamped to the clip so the padding can never hold a word.
    pub fn recognize(&self, samples: &[f32]) -> Result<Recognized, EngineError> {
        let options = RunOptions {
            timestamps: TimestampKind::Word,
            ..Default::default()
        };
        let mut session = self
            .session
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut whole = Recognized::default();
        let mut texts = Vec::new();
        for run in runs(samples) {
            let offset = clip_ms(run.start);
            let prepared = ramble_audio::prepare_for_engine(&samples[run.clone()]);
            let outcome = session.run(&prepared, &options);
            let part = recognized(outcome, session.was_aborted(), clip_ms(run.len()))?;
            texts.push(part.text);
            whole.truncated |= part.truncated;
            whole.words.extend(part.words.into_iter().map(|word| Word {
                start_ms: word.start_ms + offset,
                end_ms: word.end_ms + offset,
                ..word
            }));
        }
        whole.text = joined(texts);
        Ok(whole)
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

/// The longest audio the runtime is given in one run: 30 seconds.
///
/// Parakeet Ultra segments a longer run itself, at pauses its own speech head
/// finds, and on transcribe.cpp 0.4.1 that head can miss the speech at the
/// start of a piece that begins mid-sentence and drop it without a trace. So
/// longer audio is cut here, the bound the Mac's file chunker keeps too.
pub const MAX_RUN_SAMPLES: usize = 30 * ramble_audio::ENGINE_SAMPLE_RATE as usize;

/// Where to cut audio into runs of at most [`MAX_RUN_SAMPLES`]: in the middle
/// of the quietest 20 ms frame of the last 5 s before each limit, so a cut
/// lands in a pause whenever the speaker made one.
fn runs(samples: &[f32]) -> Vec<Range<usize>> {
    const FRAME: usize = 320;
    const SEARCH: usize = 5 * 16_000;
    let energy = |at: usize| samples[at..at + FRAME].iter().map(|s| s * s).sum::<f32>();
    let mut runs = Vec::new();
    let mut start = 0;
    while samples.len() - start > MAX_RUN_SAMPLES {
        let limit = start + MAX_RUN_SAMPLES;
        let cut = (limit - SEARCH..=limit - FRAME)
            .step_by(FRAME)
            .min_by(|&a, &b| energy(a).total_cmp(&energy(b)))
            .map_or(limit, |frame| frame + FRAME / 2);
        runs.push(start..cut);
        start = cut;
    }
    runs.push(start..samples.len());
    runs
}

/// The text of consecutive runs. One run's text is returned exactly as the
/// runtime gave it.
fn joined(mut texts: Vec<String>) -> String {
    if texts.len() == 1 {
        return texts.remove(0);
    }
    texts
        .iter()
        .map(|text| text.trim())
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// The length of a 16 kHz clip in whole milliseconds.
fn clip_ms(samples: usize) -> u32 {
    let ms = samples as u64 * 1000 / u64::from(ramble_audio::ENGINE_SAMPLE_RATE);
    u32::try_from(ms).unwrap_or(u32::MAX)
}

/// What a run produced, in this crate's terms.
///
/// A truncated decode is still an answer: its words are real and the caller
/// is told the rest is missing. An abort is the caller's own cancellation.
fn recognized(
    outcome: Result<transcribe_cpp::Transcript, transcribe_cpp::Error>,
    aborted: bool,
    clip_ms: u32,
) -> Result<Recognized, EngineError> {
    let (transcript, truncated) = match outcome {
        _ if aborted => return Err(EngineError::Cancelled),
        Ok(transcript) => (transcript, false),
        Err(transcribe_cpp::Error::OutputTruncated { partial, .. }) => {
            (partial.map(|partial| *partial).unwrap_or_default(), true)
        }
        Err(transcribe_cpp::Error::Aborted { .. }) => return Err(EngineError::Cancelled),
        Err(error) => return Err(EngineError::Run(error.to_string())),
    };
    let clamp = |ms: i64| ms.clamp(0, i64::from(clip_ms)) as u32;
    let words = transcript
        .words
        .into_iter()
        .filter_map(|word| {
            let text = word.text.trim();
            if text.is_empty() {
                return None;
            }
            let start_ms = clamp(word.t0_ms);
            Some(Word {
                text: text.to_string(),
                start_ms,
                end_ms: clamp(word.t1_ms).max(start_ms),
            })
        })
        .collect();
    Ok(Recognized {
        text: transcript.text,
        words,
        truncated,
    })
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
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        Backend::Metal
    } else {
        // The CPU, until a build with Vulkan compiled in exists. Asking for an
        // accelerator this build cannot provide would fail every load rather
        // than run slowly, which is the worse of the two outcomes.
        Backend::Cpu
    }
}

/// Load on the preferred accelerator, falling back to the CPU.
///
/// The fallback is real and necessary — a Linux box with no Vulkan driver, a VM
/// with no GPU passthrough — but it is never silent. The active backend is
/// carried out so the interface can say so.
fn load_with_fallback(path: &Path, requested: Backend) -> Result<(Model, Backend), EngineError> {
    // The weights stay memory-mapped (the runtime's default): engines loaded
    // from one file share its pages, and the OS can drop them under pressure
    // instead of swapping them. Installs replace a model by renaming a new
    // directory into place, never by rewriting the mapped file.
    let options = ModelOptions {
        backend: requested,
        ..ModelOptions::default()
    };
    match Model::load_with(path, &options) {
        Ok(model) => Ok((model, requested)),
        Err(accelerator_error) => {
            let cpu = ModelOptions {
                backend: Backend::Cpu,
                ..ModelOptions::default()
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

/// The `.gguf` in a directory: the first by name if there are several.
pub fn model_file(directory: &Path) -> Option<PathBuf> {
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

    fn runtime_word(text: &str, t0_ms: i64, t1_ms: i64) -> transcribe_cpp::Word {
        transcribe_cpp::Word {
            t0_ms,
            t1_ms,
            text: text.into(),
            ..Default::default()
        }
    }

    fn transcript(text: &str, words: Vec<transcribe_cpp::Word>) -> transcribe_cpp::Transcript {
        transcribe_cpp::Transcript {
            text: text.into(),
            words,
            ..Default::default()
        }
    }

    #[test]
    fn word_times_are_clamped_into_the_clip_and_never_end_before_they_start() {
        let outcome = Ok(transcript(
            "early late inverted",
            vec![
                runtime_word("early", -40, 300),
                runtime_word("late", 900, 1_400),
                runtime_word("inverted", 700, 650),
            ],
        ));
        let clamped = recognized(outcome, false, 1_000).unwrap();
        assert_eq!(
            clamped.words,
            vec![
                Word {
                    text: "early".into(),
                    start_ms: 0,
                    end_ms: 300
                },
                Word {
                    text: "late".into(),
                    start_ms: 900,
                    end_ms: 1_000
                },
                Word {
                    text: "inverted".into(),
                    start_ms: 700,
                    end_ms: 700
                },
            ]
        );
        assert_eq!(clamped.text, "early late inverted");
        assert!(!clamped.truncated);
    }

    #[test]
    fn empty_words_are_dropped_and_the_order_is_kept() {
        let outcome = Ok(transcript(
            "one two",
            vec![
                runtime_word(" one", 0, 100),
                runtime_word("  ", 100, 120),
                runtime_word("", 120, 130),
                runtime_word("two ", 130, 300),
            ],
        ));
        let words: Vec<String> = recognized(outcome, false, 1_000)
            .unwrap()
            .words
            .into_iter()
            .map(|word| word.text)
            .collect();
        assert_eq!(words, ["one", "two"]);
    }

    #[test]
    fn a_truncated_decode_keeps_its_partial_words() {
        let outcome = Err(transcribe_cpp::Error::OutputTruncated {
            message: "budget".into(),
            partial: Some(Box::new(transcript(
                "cut",
                vec![runtime_word("cut", 0, 200)],
            ))),
        });
        let partial = recognized(outcome, false, 1_000).unwrap();
        assert!(partial.truncated);
        assert_eq!(partial.text, "cut");
        assert_eq!(partial.words.len(), 1);

        let without_partial = Err(transcribe_cpp::Error::OutputTruncated {
            message: "budget".into(),
            partial: None,
        });
        let empty = recognized(without_partial, false, 1_000).unwrap();
        assert_eq!(
            empty,
            Recognized {
                truncated: true,
                ..Default::default()
            }
        );
    }

    #[test]
    fn an_abort_is_a_cancellation_and_other_failures_stay_failures() {
        let aborted = Err(transcribe_cpp::Error::Aborted {
            message: "stop".into(),
            partial: None,
        });
        assert!(matches!(
            recognized(aborted, true, 1_000),
            Err(EngineError::Cancelled)
        ));
        assert!(matches!(
            recognized(Ok(transcript("x", vec![])), true, 1_000),
            Err(EngineError::Cancelled)
        ));
        let failed = Err(transcribe_cpp::Error::InvalidArgument("bad".into()));
        assert!(matches!(
            recognized(failed, false, 1_000),
            Err(EngineError::Run(_))
        ));
    }

    #[test]
    fn the_clip_length_is_counted_in_milliseconds_of_16_khz_audio() {
        assert_eq!(clip_ms(16_000), 1_000);
        assert_eq!(clip_ms(8), 0);
        assert_eq!(clip_ms(24_000), 1_500);
    }

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
        assert_eq!(model_file(directory.path()), None);

        std::fs::write(directory.path().join("b-model.gguf"), b"x").unwrap();
        std::fs::write(directory.path().join("a-model.gguf"), b"x").unwrap();
        // The same answer every launch, not whatever the filesystem listed first.
        assert_eq!(
            model_file(directory.path()).unwrap().file_name().unwrap(),
            "a-model.gguf"
        );
    }

    #[test]
    fn no_run_is_longer_than_thirty_seconds_and_runs_cover_the_audio_in_order() {
        for seconds in [1.0, 29.9, 30.0, 30.02, 34.0, 61.5, 600.0] {
            let samples = vec![0.1f32; (seconds * 16_000.0) as usize];
            let runs = runs(&samples);
            assert!(
                runs.iter().all(|run| run.len() <= MAX_RUN_SAMPLES),
                "{seconds} s"
            );
            assert_eq!(runs.first().unwrap().start, 0);
            assert_eq!(runs.last().unwrap().end, samples.len());
            assert!(runs.windows(2).all(|pair| pair[0].end == pair[1].start));
        }
        assert_eq!(runs(&vec![0.1f32; MAX_RUN_SAMPLES]).len(), 1);
    }

    #[test]
    fn a_long_run_is_cut_in_the_last_pause_before_thirty_seconds() {
        // Speech with one 200 ms pause at 27 s and another at 12 s.
        let mut samples = vec![0.3f32; 70 * 16_000];
        for pause in [12 * 16_000, 27 * 16_000] {
            samples[pause..pause + 3_200].fill(0.0);
        }
        let first = runs(&samples)[0].clone();
        assert!(
            (27 * 16_000..27 * 16_000 + 3_200).contains(&first.end),
            "cut at {}",
            first.end
        );
    }

    #[test]
    fn texts_of_several_runs_are_joined_by_one_space_and_one_run_is_untouched() {
        assert_eq!(joined(vec![" one ".into()]), " one ");
        assert_eq!(
            joined(vec![" one".into(), "".into(), "two ".into()]),
            "one two"
        );
    }

    #[test]
    fn the_mac_app_pins_the_runtime_this_crate_links() {
        // One runtime everywhere. A measurement taken on one platform says
        // nothing about another that runs a different build, and for five
        // days in October 2026 the Mac and this crate ran 0.4.0 and 0.2.0.
        // The fork's release tag is `v<version>-<commit>`, so the Mac's
        // framework names the commit both targets here must build.
        let package = include_str!("../../../Packages/LocalASR/Package.swift");
        let tag = package
            .split("transcribe.cpp/releases/download/v")
            .nth(1)
            .and_then(|rest| rest.split('/').next())
            .expect("Package.swift pins CTranscribe by its release URL");
        let (version, commit) = tag.split_once('-').expect("the tag is <version>-<commit>");
        assert_eq!(version, transcribe_cpp::version());
        let manifest = include_str!("../Cargo.toml");
        assert_eq!(manifest.matches(&format!("rev = \"{commit}")).count(), 2);
    }

    #[test]
    fn each_platform_asks_for_what_its_build_can_actually_provide() {
        if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
            assert_eq!(preferred_backend(), Backend::Metal);
        } else {
            // Asking for an accelerator this build has no support for would
            // fail every load instead of running slowly.
            assert_eq!(preferred_backend(), Backend::Cpu);
        }
    }
}

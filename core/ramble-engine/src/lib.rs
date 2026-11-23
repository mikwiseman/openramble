//! The recognizer.
//!
//! The only crate in this workspace that touches the recognition engine,
//! mirroring the rule the Mac already keeps: exactly one place may call it, so
//! the blast radius of an engine change is one place.
//!
//! The engine is ours and lives in `engine/`: plain C that `build.rs` compiles
//! into this crate. It runs on the processor, chooses its kernels for the
//! processor it finds when a model is opened, and needs nothing of the machine
//! that built it.
//!
//! What the shipping Mac app learned the hard way, kept here:
//!
//! - **Slowness must never become failure.** A model that took a long time
//!   because the machine was busy is still working. Killing the take discards the
//!   loaded model, which makes the next take colder and slower still — a spiral
//!   the person cannot escape. Cancellation exists for a person who pressed
//!   Escape, not for a clock.
//! - **A slower path is announced, never silent.** A processor without the
//!   instructions the fast kernels need still recognizes, several times more
//!   slowly, and the person is entitled to know which of the two they have.

use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[allow(unsafe_code)]
mod ore;
mod report;
pub use report::{processor_notice, BackendReport};

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
    /// Always false: this model's decoder has no output budget that stops it
    /// before the end of the clip. Kept for the callers that report it.
    pub truncated: bool,
}

/// A loaded recognizer.
///
/// The session is behind a mutex because two takes must not decode through one
/// session at once. Dictation is inherently one-at-a-time, so the lock is never
/// contended in practice; it exists to make that a compile-time fact rather
/// than a hope.
pub struct Engine {
    recognizer: Mutex<ore::Recognizer>,
    report: BackendReport,
}

impl Engine {
    /// Load the model in a directory for one person dictating: one
    /// recognition at a time, on as many threads as the machine has, at most
    /// four.
    ///
    /// The engine's threads take their work from a shared counter and never
    /// wait for one another, so a busy machine slows a recognition down
    /// without stalling it (research/own-engine-2026-11, the ledger's rows on
    /// threads under load).
    ///
    /// The engine wants a file, the installer produces a directory, so the
    /// single `.gguf` inside is found here rather than making every caller know
    /// the filename.
    pub fn load(model_directory: &Path) -> Result<Self, EngineError> {
        Self::load_with_threads(model_directory, 0)
    }

    /// Load with a fixed number of threads. The server runs several engines
    /// side by side, each on one thread.
    pub fn load_with_threads(model_directory: &Path, threads: usize) -> Result<Self, EngineError> {
        let model_path = model_file(model_directory)
            .ok_or_else(|| EngineError::NoModel(model_directory.to_path_buf()))?;
        // The weights stay memory-mapped: engines loaded from one file share
        // its pages, and the OS can drop them under pressure instead of
        // swapping them. Installs replace a model by renaming a new directory
        // into place, never by rewriting the mapped file.
        let recognizer = ore::Recognizer::open(&model_path, threads).map_err(EngineError::Load)?;
        let report = BackendReport {
            kernels: recognizer.kernels(),
            threads: recognizer.threads(),
        };
        Ok(Engine {
            recognizer: Mutex::new(recognizer),
            report,
        })
    }

    /// What the recognizer is actually running on.
    pub fn report(&self) -> &BackendReport {
        &self.report
    }

    /// The engine's version.
    pub fn version() -> String {
        ore::version()
    }

    /// Recognize 16 kHz mono audio.
    ///
    /// Short clips are padded before the engine sees them, as they always
    /// were, and long ones are cut into runs of at most [`MAX_RUN_SAMPLES`].
    pub fn transcribe(&self, samples: &[f32]) -> Result<String, EngineError> {
        self.recognize(samples).map(|recognized| recognized.text)
    }

    /// Recognize 16 kHz mono audio and say where each word lies.
    ///
    /// Padding goes at the end of a short clip, so it moves no time; times are
    /// clamped to the clip so the padding can never hold a word.
    pub fn recognize(&self, samples: &[f32]) -> Result<Recognized, EngineError> {
        let mut recognizer = self
            .recognizer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut whole = Recognized::default();
        let mut texts = Vec::new();
        for run in runs(samples) {
            let offset = clip_ms(run.start);
            let prepared = ramble_audio::prepare_for_engine(&samples[run.clone()]);
            let part = recognized(recognizer.run(&prepared), clip_ms(run.len()))?;
            texts.push(part.text);
            whole.words.extend(part.words.into_iter().map(|word| Word {
                start_ms: word.start_ms + offset,
                end_ms: word.end_ms + offset,
                ..word
            }));
        }
        whole.text = joined(texts);
        Ok(whole)
    }

    /// Release the model and stop the engine's threads.
    ///
    /// Dropping the engine does the same. Callers name the moment so that it
    /// happens on the thread that owns the engine, before the process exits.
    pub fn shutdown(self) {
        drop(self);
    }
}

/// The longest audio the engine is given in one run: 30 seconds.
///
/// Parakeet Ultra segments a longer run itself, at pauses its own speech head
/// finds, and that head can miss the speech at the start of a piece that
/// begins mid-sentence and drop it without a trace. The engine keeps that
/// behaviour of transcribe.cpp 0.4.1, so longer audio is cut here, the bound
/// the Mac's file chunker keeps too.
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
/// engine gave it.
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

/// What a run produced, in this crate's terms. An abort is the caller's own
/// cancellation.
fn recognized(
    outcome: Result<ore::Heard, ore::Failure>,
    clip_ms: u32,
) -> Result<Recognized, EngineError> {
    let heard = match outcome {
        Ok(heard) => heard,
        Err(ore::Failure::Aborted) => return Err(EngineError::Cancelled),
        Err(ore::Failure::Other(detail)) => return Err(EngineError::Run(detail.into())),
    };
    let clamp = |ms: i64| ms.clamp(0, i64::from(clip_ms)) as u32;
    let words = heard
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
        text: heard.text,
        words,
        truncated: false,
    })
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

    fn engine_word(text: &str, t0_ms: i64, t1_ms: i64) -> ore::Word {
        ore::Word {
            text: text.into(),
            t0_ms,
            t1_ms,
        }
    }

    fn heard(text: &str, words: Vec<ore::Word>) -> Result<ore::Heard, ore::Failure> {
        Ok(ore::Heard {
            text: text.into(),
            words,
        })
    }

    #[test]
    fn word_times_are_clamped_into_the_clip_and_never_end_before_they_start() {
        let outcome = heard(
            "early late inverted",
            vec![
                engine_word("early", -40, 300),
                engine_word("late", 900, 1_400),
                engine_word("inverted", 700, 650),
            ],
        );
        let clamped = recognized(outcome, 1_000).unwrap();
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
        let outcome = heard(
            "one two",
            vec![
                engine_word(" one", 0, 100),
                engine_word("  ", 100, 120),
                engine_word("", 120, 130),
                engine_word("two ", 130, 300),
            ],
        );
        let words: Vec<String> = recognized(outcome, 1_000)
            .unwrap()
            .words
            .into_iter()
            .map(|word| word.text)
            .collect();
        assert_eq!(words, ["one", "two"]);
    }

    #[test]
    fn an_abort_is_a_cancellation_and_other_failures_stay_failures() {
        assert!(matches!(
            recognized(Err(ore::Failure::Aborted), 1_000),
            Err(EngineError::Cancelled)
        ));
        assert!(matches!(
            recognized(Err(ore::Failure::Other("bad")), 1_000),
            Err(EngineError::Run(_))
        ));
    }

    #[test]
    fn a_file_that_is_not_a_model_fails_to_load_with_a_reason() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("model.gguf"), b"not a model").unwrap();
        match Engine::load(directory.path()) {
            Err(EngineError::Load(detail)) => assert!(!detail.is_empty()),
            other => panic!("expected a load failure, got {:?}", other.err()),
        }
    }

    #[test]
    fn the_engine_states_its_version() {
        let version = Engine::version();
        assert!(version.split('.').count() >= 2, "{version}");
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
}

//! Does the recognizer actually recognize?
//!
//! Unit tests can prove the model file is found and that a fallback is
//! announced. They cannot prove that audio goes in and words come out, and that
//! is the only claim this crate really makes.
//!
//! So this test speaks a known sentence, transcribes it, and checks the words
//! came back. It needs the model installed, so it skips on a machine without one
//! rather than failing — an absent 739 MB download is not a defect in this code.

use ramble_engine::Engine;
use ramble_model::{Manifest, ModelState, ModelStore};
use std::path::PathBuf;
use std::process::Command;

const SHIPPING_MANIFEST: &str =
    include_str!("../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

const SPOKEN: &str = "Checking work without the Internet";

fn installed_model() -> Option<PathBuf> {
    let root = match std::env::var("OPENRAMBLE_SUPPORT_ROOT") {
        Ok(root) => PathBuf::from(root).join("Models"),
        Err(_) => PathBuf::from(std::env::var("HOME").ok()?)
            .join("Library/Application Support/OpenRamble/Models"),
    };
    let store = ModelStore::new(Manifest::parse(SHIPPING_MANIFEST).ok()?, root);
    (store.state() == ModelState::Ready).then(|| store.engine_directory())
}

/// Speech to transcribe: the repository's existing probe if a build left one,
/// otherwise synthesized the same way the macOS smoke test does.
fn speech() -> Option<(Vec<f32>, u32)> {
    let existing = PathBuf::from(".build-zero-network/probe-en.wav");
    let existing = if existing.exists() {
        existing
    } else {
        PathBuf::from("../../.build-zero-network/probe-en.wav")
    };
    if existing.exists() {
        return ramble_audio::read_wav(&existing).ok();
    }

    if !cfg!(target_os = "macos") {
        return None;
    }
    let directory = std::env::temp_dir().join("ramble-engine-speech");
    std::fs::create_dir_all(&directory).ok()?;
    let aiff = directory.join("probe.aiff");
    let wav = directory.join("probe.wav");
    Command::new("say")
        .args(["-v", "Samantha", "-o"])
        .arg(&aiff)
        .arg(SPOKEN)
        .status()
        .ok()?
        .success()
        .then_some(())?;
    Command::new("afconvert")
        .args(["-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])
        .arg(&aiff)
        .arg(&wav)
        .status()
        .ok()?
        .success()
        .then_some(())?;
    ramble_audio::read_wav(&wav).ok()
}

#[test]
fn spoken_words_come_back_as_text() {
    let Some(model_directory) = installed_model() else {
        eprintln!("no installed model; skipping the recognition check");
        return;
    };
    let Some((samples, rate)) = speech() else {
        eprintln!("no speech to transcribe; skipping the recognition check");
        return;
    };
    let samples = ramble_audio::resample(&samples, rate).expect("resample");

    let engine = Engine::load(&model_directory).expect("the model must load");
    eprintln!("backend: {:?}", engine.report());
    if let Some(notice) = engine.report().notice() {
        eprintln!("notice: {notice}");
    }

    let text = engine
        .transcribe(&samples)
        .expect("recognition must succeed");
    eprintln!("heard: {text:?}");

    let lowered = text.to_lowercase();
    for word in ["checking", "work", "internet"] {
        assert!(
            lowered.contains(word),
            "expected {word:?} in the transcript, got {text:?}"
        );
    }

    // The model must be gone before this process exits, or ggml's static
    // destructors abort with signal 6 and the test binary "fails" after passing.
    engine.shutdown();
}

/// A clip far shorter than the mel front-end's two-frame minimum.
///
/// Without padding this is where NaNs enter the decoder. It must return
/// something — empty text is a fine answer — rather than crashing or hanging.
#[test]
fn a_clip_too_short_to_contain_speech_does_not_poison_the_engine() {
    let Some(model_directory) = installed_model() else {
        eprintln!("no installed model; skipping");
        return;
    };
    let engine = Engine::load(&model_directory).expect("the model must load");
    let text = engine
        .transcribe(&vec![0.0_f32; 200])
        .expect("a short clip must not fail");
    assert!(!text.contains("NaN"), "got {text:?}");
    engine.shutdown();
}

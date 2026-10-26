//! File mode end to end with the real model: what the tool prints must be
//! what the engine hears in the same audio.
//!
//! Needs ffmpeg, an installed model and a way to make speech (macOS `say`),
//! and skips without them. `OPENRAMBLE_MODEL_DIR` names a model folder
//! directly; otherwise the Mac app's installed model is used.

use std::fs::File;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use ramble_model::{Manifest, ModelState, ModelStore};

const SHIPPING_MANIFEST: &str =
    include_str!("../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

pub fn model_directory() -> Option<PathBuf> {
    if let Ok(directory) = std::env::var("OPENRAMBLE_MODEL_DIR") {
        return Some(PathBuf::from(directory));
    }
    let root = PathBuf::from(std::env::var("HOME").ok()?)
        .join("Library/Application Support/OpenRamble/Models");
    let store = ModelStore::new(Manifest::parse(SHIPPING_MANIFEST).ok()?, root);
    (store.state() == ModelState::Ready).then(|| store.engine_directory())
}

fn have(tool: &str, flag: &str) -> bool {
    Command::new(tool)
        .arg(flag)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok()
}

/// Synthesized English: two sentences with a pause between them.
fn speech(directory: &Path) -> Option<PathBuf> {
    if !cfg!(target_os = "macos") || !have("ffmpeg", "-version") {
        return None;
    }
    let aiff = directory.join("probe.aiff");
    let wav = directory.join("probe.wav");
    Command::new("say")
        .args(["-v", "Samantha", "-o"])
        .arg(&aiff)
        .arg("Checking work without the Internet. [[slnc 2500]] The second sentence comes after a pause.")
        .status()
        .ok()?
        .success()
        .then_some(())?;
    Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-i"])
        .arg(&aiff)
        .args(["-ar", "16000", "-ac", "1"])
        .arg(&wav)
        .status()
        .ok()?
        .success()
        .then_some(wav)
}

fn samples(path: &Path) -> Vec<f32> {
    let temp = tempfile::tempdir().unwrap();
    let decoded =
        openramble_cli::decode::decode(File::open(path).unwrap(), temp.path(), 600.0, &|| false)
            .unwrap();
    let mut bytes = vec![0u8; decoded.samples as usize * 4];
    decoded.pcm.read_exact_at(&mut bytes, 0).unwrap();
    bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect()
}

fn openramble(args: &[&str]) -> serde_json::Value {
    let output = Command::new(env!("CARGO_BIN_EXE_openramble"))
        .args(args)
        .stderr(Stdio::inherit())
        .output()
        .unwrap();
    assert!(output.status.success());
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn the_tool_prints_what_the_engine_hears() {
    let Some(model) = model_directory() else {
        eprintln!("no installed model; skipping");
        return;
    };
    let directory = tempfile::tempdir().unwrap();
    let Some(wav) = speech(directory.path()) else {
        eprintln!("no speech or no ffmpeg; skipping");
        return;
    };
    let engine = ramble_engine::Engine::load(&model).unwrap();
    let heard = engine.transcribe(&samples(&wav)).unwrap();
    engine.shutdown();

    let model_arg = model.to_str().unwrap();
    let wav_arg = wav.to_str().unwrap();
    let whole = openramble(&[
        "--format",
        "json",
        "--workers",
        "1",
        "--no-gate",
        "--model-dir",
        model_arg,
        wav_arg,
    ]);
    assert_eq!(whole["text"], heard.trim());
    let stem = ramble_engine::model_file(&model)
        .unwrap()
        .file_stem()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    assert_eq!(whole["model"], stem);

    // labelled spans: each sentence in its own span keeps its label
    let spans = directory.path().join("spans.json");
    std::fs::write(
        &spans,
        r#"[{"start": 0, "end": 2.6, "label": "first"}, {"start": 2.6, "end": 60, "label": "second"}]"#,
    )
    .unwrap();
    let labelled = openramble(&[
        "--format",
        "json",
        "--workers",
        "2",
        "--segments",
        spans.to_str().unwrap(),
        "--model-dir",
        model_arg,
        wav_arg,
    ]);
    let rows = labelled["segments"].as_array().unwrap();
    assert!(rows.len() >= 2, "{labelled}");
    assert_eq!(rows.first().unwrap()["label"], "first");
    assert_eq!(rows.last().unwrap()["label"], "second");
    let text = labelled["text"].as_str().unwrap().to_lowercase();
    assert!(
        text.contains("internet") && text.contains("pause"),
        "{text}"
    );
}

#[test]
fn checking_the_model_verifies_its_bytes() {
    let Some(model) = model_directory() else {
        eprintln!("no installed model; skipping");
        return;
    };
    let output = Command::new(env!("CARGO_BIN_EXE_openramble"))
        .args(["--check-model", "--model-dir"])
        .arg(&model)
        .output()
        .unwrap();
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("SHA-256 match"), "{stdout}");
}

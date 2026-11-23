//! Recognize WAV files with this crate exactly as the app does.
//!
//!     cargo run --release -p ramble-engine --example recognize -- MODEL_DIR CLIP.wav...
//!
//! One line per clip: its name, the best of three wall times in milliseconds,
//! and the text, separated by tabs. The hosted benchmark compares the text
//! with the engine's own command-line tool, which CMake builds from the same
//! files, so a difference in how this crate compiles them cannot hide.

use std::path::Path;
use std::time::Instant;

use ramble_engine::Engine;

fn main() -> Result<(), String> {
    let mut arguments = std::env::args().skip(1);
    let usage = "usage: recognize MODEL_DIR CLIP.wav...";
    let model_directory = arguments.next().ok_or(usage)?;
    let clips: Vec<String> = arguments.collect();
    if clips.is_empty() {
        return Err(usage.into());
    }

    let engine = Engine::load(Path::new(&model_directory)).map_err(|error| error.to_string())?;
    let report = engine.report();
    eprintln!(
        "engine {}, {} kernels, {} threads",
        Engine::version(),
        report.kernels,
        report.threads
    );
    if let Some(notice) = report.notice() {
        eprintln!("{notice}");
    }

    for clip in &clips {
        let (samples, rate) =
            ramble_audio::read_wav(Path::new(clip)).map_err(|error| format!("{clip}: {error}"))?;
        let samples =
            ramble_audio::resample(&samples, rate).map_err(|error| format!("{clip}: {error}"))?;
        let mut best = f64::INFINITY;
        let mut text = String::new();
        for _ in 0..3 {
            let started = Instant::now();
            text = engine
                .transcribe(&samples)
                .map_err(|error| error.to_string())?;
            best = best.min(started.elapsed().as_secs_f64() * 1000.0);
        }
        let name = Path::new(clip)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        println!("{name}\t{best:.0}\t{text}");
    }
    engine.shutdown();
    Ok(())
}

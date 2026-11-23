//! Loads the model the way the app does and says what happened.
//!
//! Proof-only: lives on the proof branch for the processor check, not in the
//! product.
//!
//! load <model directory> [<wav> <seconds>]

use ramble_engine::Engine;
use std::path::PathBuf;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let engine = match Engine::load(&PathBuf::from(&arguments[1])) {
        Ok(engine) => engine,
        Err(error) => {
            println!("openramble: {error}");
            std::process::exit(1);
        }
    };
    println!("loaded on {}", engine.report().device);
    if let [_, _, wav, seconds] = arguments.as_slice() {
        let (samples, rate) = ramble_audio::read_wav(&PathBuf::from(wav)).expect("wav");
        let samples = ramble_audio::resample(&samples, rate).expect("resample");
        let seconds: usize = seconds.parse().expect("seconds");
        let clip = &samples[..(seconds * 16_000).min(samples.len())];
        // A public sample clip, not anyone's dictation.
        let text = engine.transcribe(clip).expect("recognition must succeed");
        println!("heard: {text}");
    }
    engine.shutdown();
}

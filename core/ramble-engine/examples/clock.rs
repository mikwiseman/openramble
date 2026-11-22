//! Times recognition through the same path the desktop app uses.
//!
//! Proof-only: lives on the proof branch for the instruction-set change, not
//! in the product.
//!
//! clock <model directory> <wav> <repetitions> <seconds>...

use ramble_engine::Engine;
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    let model_directory = PathBuf::from(&arguments[1]);
    let (samples, rate) = ramble_audio::read_wav(&PathBuf::from(&arguments[2])).expect("wav");
    let samples = ramble_audio::resample(&samples, rate).expect("resample");
    let repetitions: usize = arguments[3].parse().expect("repetitions");

    let started = Instant::now();
    let engine = Engine::load(&model_directory).expect("the model must load");
    println!("load {} ms", started.elapsed().as_millis());

    println!("seconds | wall min | chars");
    for seconds in arguments[4..].iter().map(|s| s.parse::<usize>().expect("seconds")) {
        let clip = &samples[..(seconds * 16_000).min(samples.len())];
        let mut best = f64::MAX;
        let mut text = String::new();
        for _ in 0..repetitions {
            let started = Instant::now();
            text = engine.transcribe(clip).expect("recognition must succeed");
            best = best.min(started.elapsed().as_secs_f64() * 1000.0);
        }
        println!("{seconds:>7} | {best:>8.1} | {}", text.chars().count());
        // A public sample clip, not anyone's dictation.
        eprintln!("heard {seconds} s: {text}");
    }

    engine.shutdown();
}

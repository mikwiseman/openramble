//! Recognizes a list of public evaluation clips through the same path the
//! desktop app uses, and writes what it heard.
//!
//! Proof-only: lives on the proof branch for hypothesis H17 of
//! `research/model-upgrade-2026-10/HYPOTHESES.md`, not in the product. The
//! clips are FLEURS test speech and generated noise, never anyone's
//! dictation, which is why their text may be written to a file.
//!
//!   fleurs words <model directory> <clips.tsv> <out.tsv> [<shard> <shards>]
//!   fleurs speed <first model directory> <second model directory> <clips.tsv> <out.tsv>
//!
//! `clips.tsv` has one clip per line: an id, a tab, the path of a WAV file.
//! `words` recognizes every clip once. `speed` loads both models and
//! recognizes every clip four times, alternating which model goes first, so
//! drift on a shared machine falls on both equally.
#![allow(unsafe_code)]

use ramble_engine::Engine;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Instant;

fn main() {
    let arguments: Vec<String> = std::env::args().collect();
    match arguments.get(1).map(String::as_str) {
        Some("words") => words(&arguments[2..]),
        Some("speed") => speed(&arguments[2..]),
        _ => panic!("fleurs words|speed ..., see the top of examples/fleurs.rs"),
    }
}

fn clips(list: &str) -> Vec<(String, PathBuf)> {
    let base = Path::new(list)
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    std::fs::read_to_string(list)
        .expect("the clip list must be readable")
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let (id, path) = line.split_once('\t').expect("id, tab, path");
            (id.to_string(), base.join(path.trim()))
        })
        .collect()
}

fn audio(path: &Path) -> Vec<f32> {
    let (samples, rate) = ramble_audio::read_wav(path).expect("wav");
    ramble_audio::resample(&samples, rate).expect("resample")
}

/// One line of text, so a row stays a row.
fn flat(text: &str) -> String {
    text.replace(['\t', '\n', '\r'], " ")
}

fn load(directory: &str) -> Engine {
    let started = Instant::now();
    let engine = Engine::load(Path::new(directory)).expect("the model must load");
    eprintln!(
        "loaded {directory} in {} ms on {}",
        started.elapsed().as_millis(),
        engine.report().device
    );
    engine
}

fn words(arguments: &[String]) {
    let (shard, shards) = match arguments.get(3) {
        Some(shard) => (
            shard.parse::<usize>().expect("shard"),
            arguments[4].parse::<usize>().expect("shards"),
        ),
        None => (0, 1),
    };
    let clips = clips(&arguments[1]);
    let after_start = memory();
    let engine = load(&arguments[0]);
    let after_load = memory();
    let mut out = std::fs::File::create(&arguments[2]).expect("the output file");
    for (index, (id, path)) in clips.iter().enumerate() {
        if index % shards != shard {
            continue;
        }
        let samples = audio(path);
        let started = Instant::now();
        let text = engine
            .transcribe(&samples)
            .expect("recognition must succeed");
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        writeln!(
            out,
            "{id}\t{ms:.1}\t{:.3}\t{}",
            samples.len() as f64 / 16_000.0,
            flat(&text)
        )
        .expect("write");
    }
    let after_work = memory();
    engine.shutdown();
    eprintln!("memory at start: {after_start}");
    eprintln!("memory after load: {after_load}");
    eprintln!("memory after recognition: {after_work}");
}

fn speed(arguments: &[String]) {
    let clips = clips(&arguments[2]);
    let engines = [load(&arguments[0]), load(&arguments[1])];
    let mut out = std::fs::File::create(&arguments[3]).expect("the output file");
    // One recognition each before timing, as the app warms its model.
    if let Some((_, path)) = clips.first() {
        let samples = audio(path);
        for engine in &engines {
            engine.transcribe(&samples).expect("warm-up");
        }
    }
    for (index, (id, path)) in clips.iter().enumerate() {
        let samples = audio(path);
        let order = if index % 2 == 0 {
            [0, 1, 1, 0]
        } else {
            [1, 0, 0, 1]
        };
        for (position, which) in order.into_iter().enumerate() {
            let started = Instant::now();
            let text = engines[which]
                .transcribe(&samples)
                .expect("recognition must succeed");
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            writeln!(
                out,
                "{id}\t{which}\t{position}\t{ms:.1}\t{:.3}\t{}",
                samples.len() as f64 / 16_000.0,
                text.chars().count()
            )
            .expect("write");
        }
    }
    for engine in engines {
        engine.shutdown();
    }
}

/// What the process holds now and held at most, in megabytes.
#[cfg(target_os = "linux")]
fn memory() -> String {
    use std::fmt::Write as _;
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let mut line = String::new();
    for (key, name) in [
        ("VmHWM:", "peak resident"),
        ("VmRSS:", "resident"),
        ("RssAnon:", "resident, the process's own"),
        ("RssFile:", "resident, mapped from files"),
    ] {
        let kilobytes = status
            .lines()
            .find_map(|row| row.strip_prefix(key))
            .and_then(|rest| rest.split_whitespace().next())
            .and_then(|value| value.parse::<f64>().ok())
            .unwrap_or(f64::NAN);
        let _ = write!(line, "{name} {:.0} MB; ", kilobytes / 1024.0);
    }
    line
}

#[cfg(windows)]
fn memory() -> String {
    #[repr(C)]
    struct Counters {
        size: u32,
        page_fault_count: u32,
        peak_working_set: usize,
        working_set: usize,
        quota_peak_paged_pool: usize,
        quota_paged_pool: usize,
        quota_peak_non_paged_pool: usize,
        quota_non_paged_pool: usize,
        pagefile: usize,
        peak_pagefile: usize,
    }
    extern "system" {
        fn GetCurrentProcess() -> *mut core::ffi::c_void;
        fn K32GetProcessMemoryInfo(
            process: *mut core::ffi::c_void,
            counters: *mut Counters,
            size: u32,
        ) -> i32;
    }
    let mut counters = Counters {
        size: std::mem::size_of::<Counters>() as u32,
        page_fault_count: 0,
        peak_working_set: 0,
        working_set: 0,
        quota_peak_paged_pool: 0,
        quota_paged_pool: 0,
        quota_peak_non_paged_pool: 0,
        quota_non_paged_pool: 0,
        pagefile: 0,
        peak_pagefile: 0,
    };
    // SAFETY: the structure is the one the call documents, sized by its own
    // first field, and the pseudo-handle of this process is always valid.
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.size) };
    if ok == 0 {
        return "not available".into();
    }
    let megabytes = |bytes: usize| bytes as f64 / 1_048_576.0;
    format!(
        "peak resident {:.0} MB; resident {:.0} MB; committed {:.0} MB; peak committed {:.0} MB; ",
        megabytes(counters.peak_working_set),
        megabytes(counters.working_set),
        megabytes(counters.pagefile),
        megabytes(counters.peak_pagefile)
    )
}

#[cfg(not(any(target_os = "linux", windows)))]
fn memory() -> String {
    "not measured on this system".into()
}

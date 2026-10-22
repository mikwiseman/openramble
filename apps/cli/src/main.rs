//! `openramble` for Linux servers: transcribe audio files with the OpenRamble
//! engine (Parakeet Ultra through transcribe.cpp) on the processor.
//!
//! The macOS tool lives in `apps/macos/OpenRambleCLI` and leans on LocalASR,
//! which is Swift and Apple-only. This one does the same job on top of the
//! shared Rust core: ffmpeg decodes any input to 16 kHz mono, the audio is cut
//! at pauses into pieces of at most `--max-chunk` seconds, and `--workers`
//! engines recognize the pieces in parallel. Each engine is single-threaded by
//! design (see `ramble_engine::Engine::load`), so parallelism comes from
//! several engines rather than from threads inside one.

use ramble_engine::Engine;
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Instant;

const RATE: usize = 16_000;
const FRAME: usize = RATE / 50; // 20 ms

struct Options {
    inputs: Vec<PathBuf>,
    model_dir: PathBuf,
    format: String,
    workers: usize,
    max_chunk: f32,
    output_dir: Option<PathBuf>,
    segments: Option<PathBuf>,
    check_model: bool,
}

#[derive(Clone)]
struct Piece {
    start: usize,
    end: usize,
    label: Option<String>,
    text: String,
}

fn usage() -> &'static str {
    "usage: openramble [options] <audio>...\n\
     \n\
     options:\n\
       --format text|json|srt   output format (default text)\n\
       --workers N              parallel engines (default: half the cores, at most 4)\n\
       --max-chunk SECONDS      longest piece sent to the engine (default 25)\n\
       --output-dir DIR         write <name>.<ext> files there instead of stdout\n\
       --segments FILE          JSON [{\"start\": s, \"end\": s, \"label\": \"…\"}]: transcribe only these spans\n\
                                (e.g. speaker turns), long spans still cut at pauses; labels are kept\n\
       --model-dir DIR          folder with the .gguf model\n\
                                (default $OPENRAMBLE_MODEL_DIR or ~/opt/openramble-models/parakeet-ultra-gguf)\n\
       --check-model            load the model, report the backend and exit\n"
}

fn parse() -> Result<Options, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
    let mut options = Options {
        inputs: Vec::new(),
        model_dir: std::env::var("OPENRAMBLE_MODEL_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(&home).join("opt/openramble-models/parakeet-ultra-gguf")),
        format: "text".into(),
        workers: (cores / 2).clamp(1, 4),
        max_chunk: 25.0,
        output_dir: None,
        segments: None,
        check_model: false,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Err(String::new()),
            "--format" => options.format = value("--format")?,
            "--workers" => options.workers = value("--workers")?.parse().map_err(|_| "bad --workers")?,
            "--max-chunk" => options.max_chunk = value("--max-chunk")?.parse().map_err(|_| "bad --max-chunk")?,
            "--output-dir" => options.output_dir = Some(PathBuf::from(value("--output-dir")?)),
            "--model-dir" => options.model_dir = PathBuf::from(value("--model-dir")?),
            "--segments" => options.segments = Some(PathBuf::from(value("--segments")?)),
            "--check-model" => options.check_model = true,
            flag if flag.starts_with("--") => return Err(format!("unknown option {flag}")),
            path => options.inputs.push(PathBuf::from(path)),
        }
    }
    if !["text", "json", "srt"].contains(&options.format.as_str()) {
        return Err("--format must be text, json or srt".into());
    }
    if options.workers == 0 || !(5.0..=120.0).contains(&options.max_chunk) {
        return Err("--workers must be at least 1 and --max-chunk 5–120 seconds".into());
    }
    if options.inputs.is_empty() && !options.check_model {
        return Err("no input files".into());
    }
    Ok(options)
}

/// Any audio or video file → 16 kHz mono f32, through ffmpeg.
fn decode(path: &Path) -> Result<Vec<f32>, String> {
    let mut child = Command::new("ffmpeg")
        .args(["-nostdin", "-v", "error", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", "16000", "-f", "f32le", "-"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("ffmpeg: {e}"))?;
    let mut bytes = Vec::new();
    child.stdout.take().unwrap().read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!("ffmpeg could not read {}: {}", path.display(), String::from_utf8_lossy(&output.stderr).trim()));
    }
    Ok(bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])).collect())
}

/// Cut at pauses: every piece is at most `max` seconds, and a cut lands on the
/// quietest 20 ms frame in the last third of the window, so words are not split.
/// Pieces with almost no sound above the noise floor are dropped.
fn pieces(samples: &[f32], max: f32) -> Vec<Piece> {
    let rms: Vec<f32> = samples
        .chunks(FRAME)
        .map(|f| (f.iter().map(|x| x * x).sum::<f32>() / f.len().max(1) as f32).sqrt())
        .collect();
    let mut sorted = rms.clone();
    sorted.sort_by(|a, b| a.total_cmp(b));
    let floor = sorted.get(sorted.len() / 5).copied().unwrap_or(0.0);
    let voiced = (floor * 3.0).max(0.003);
    let max_frames = (max * 50.0) as usize;
    let mut out = Vec::new();
    let mut start = 0;
    while start < rms.len() {
        let mut end = (start + max_frames).min(rms.len());
        if end < rms.len() {
            let from = start + max_frames * 2 / 3;
            // the quietest point, smoothed over 200 ms so a single quiet frame
            // inside a word is not mistaken for a pause
            end = (from..end)
                .min_by(|&a, &b| {
                    let around = |i: usize| rms[i.saturating_sub(5)..(i + 5).min(rms.len())].iter().sum::<f32>();
                    around(a).total_cmp(&around(b))
                })
                .unwrap_or(end);
        }
        let speech = rms[start..end].iter().filter(|&&r| r > voiced).count();
        if speech * 50 >= (end - start) * 2 && speech >= 10 {
            out.push(Piece { start: start * FRAME, end: (end * FRAME).min(samples.len()), label: None, text: String::new() });
        }
        start = end;
    }
    out
}

/// Pieces inside the given spans only, each carrying its span's label.
fn spans(file: &Path, samples: &[f32], max: f32) -> Result<Vec<Piece>, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let list: Vec<serde_json::Value> = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", file.display()))?;
    let mut out = Vec::new();
    for span in list {
        let second = |key: &str| span.get(key).and_then(|v| v.as_f64()).ok_or_else(|| format!("segment without {key}"));
        let a = ((second("start")? * RATE as f64) as usize).min(samples.len());
        let b = ((second("end")? * RATE as f64) as usize).min(samples.len());
        if b <= a {
            continue;
        }
        let label = span.get("label").and_then(|v| v.as_str()).map(str::to_string);
        for mut piece in pieces(&samples[a..b], max) {
            piece.start += a;
            piece.end += a;
            piece.label = label.clone();
            out.push(piece);
        }
    }
    Ok(out)
}

fn transcribe(samples: Arc<Vec<f32>>, mut work: Vec<Piece>, options: &Options) -> Result<Vec<Piece>, String> {
    let total = work.len();
    let queue = Arc::new(Mutex::new(work.drain(..).enumerate().collect::<VecDeque<_>>()));
    let results = Arc::new(Mutex::new(vec![None::<Piece>; total]));
    let done = Arc::new(Mutex::new(0usize));
    let started = Instant::now();
    let workers = options.workers.min(total.max(1));
    let handles: Vec<_> = (0..workers)
        .map(|_| {
            let (queue, results, done, samples) = (queue.clone(), results.clone(), done.clone(), samples.clone());
            let dir = options.model_dir.clone();
            std::thread::spawn(move || -> Result<(), String> {
                let engine = Engine::load(&dir).map_err(|e| e.to_string())?;
                loop {
                    let next = queue.lock().unwrap().pop_front();
                    let Some((index, mut piece)) = next else { break };
                    piece.text = match engine.transcribe(&samples[piece.start..piece.end]) {
                        Ok(text) => text.trim().to_string(),
                        Err(e) => {
                            engine.shutdown();
                            return Err(e.to_string());
                        }
                    };
                    results.lock().unwrap()[index] = Some(piece);
                    let mut n = done.lock().unwrap();
                    *n += 1;
                    eprint!("\rTranscribing: {}/{} pieces, {:.0} s", *n, total, started.elapsed().as_secs_f32());
                }
                engine.shutdown();
                Ok(())
            })
        })
        .collect();
    for handle in handles {
        handle.join().map_err(|_| "a worker crashed".to_string())??;
    }
    eprintln!();
    let results = Arc::try_unwrap(results).map_err(|_| "results still shared")?.into_inner().unwrap();
    Ok(results.into_iter().flatten().filter(|p| !p.text.is_empty()).collect())
}

fn clock(samples: usize, srt: bool) -> String {
    let ms = samples * 1000 / RATE;
    let (h, m, s, rest) = (ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000);
    if srt { format!("{h:02}:{m:02}:{s:02},{rest:03}") } else { format!("{h:02}:{m:02}:{s:02}") }
}

fn render(pieces: &[Piece], format: &str, duration: usize, elapsed: f32) -> String {
    match format {
        "json" => {
            let segments: Vec<_> = pieces
                .iter()
                .map(|p| serde_json::json!({"start": p.start as f64 / RATE as f64, "end": p.end as f64 / RATE as f64, "label": p.label, "text": p.text}))
                .collect();
            let text = pieces.iter().map(|p| p.text.as_str()).collect::<Vec<_>>().join(" ");
            serde_json::to_string_pretty(&serde_json::json!({
                "model": "parakeet-ultra-Q4_K_M",
                "duration": duration as f64 / RATE as f64,
                "elapsed": elapsed,
                "segments": segments,
                "text": text,
            }))
            .unwrap()
                + "\n"
        }
        "srt" => pieces
            .iter()
            .enumerate()
            .map(|(i, p)| format!("{}\n{} --> {}\n{}\n\n", i + 1, clock(p.start, true), clock(p.end, true), p.text))
            .collect(),
        _ => pieces
            .iter()
            .map(|p| match &p.label {
                Some(label) => format!("[{}] {label}: {}\n", clock(p.start, false), p.text),
                None => format!("[{}] {}\n", clock(p.start, false), p.text),
            })
            .collect(),
    }
}

fn run(options: Options) -> Result<(), String> {
    if options.check_model {
        let engine = Engine::load(&options.model_dir).map_err(|e| e.to_string())?;
        println!("model: {}", options.model_dir.display());
        println!("backend: {:?}", engine.report());
        engine.shutdown();
        if options.inputs.is_empty() {
            return Ok(());
        }
    }
    for input in &options.inputs {
        let started = Instant::now();
        let samples = Arc::new(decode(input)?);
        let work = match &options.segments {
            Some(file) => spans(file, &samples, options.max_chunk)?,
            None => pieces(&samples, options.max_chunk),
        };
        eprintln!("{}: {:.0} s of audio, {} pieces, {} workers", input.display(), samples.len() as f32 / RATE as f32, work.len(), options.workers);
        let done = transcribe(samples.clone(), work, &options)?;
        let text = render(&done, &options.format, samples.len(), started.elapsed().as_secs_f32());
        match &options.output_dir {
            Some(dir) => {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                let stem = input.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "transcript".into());
                let path = dir.join(format!("{stem}.{}", if options.format == "text" { "txt" } else { &options.format }));
                if path.exists() {
                    return Err(format!("{} exists; not overwriting", path.display()));
                }
                std::fs::write(&path, text).map_err(|e| e.to_string())?;
                eprintln!("wrote {}", path.display());
            }
            None => std::io::stdout().write_all(text.as_bytes()).map_err(|e| e.to_string())?,
        }
        eprintln!("done in {:.0} s", started.elapsed().as_secs_f32());
    }
    Ok(())
}

fn main() -> ExitCode {
    match parse().and_then(run) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) if message.is_empty() => {
            print!("{}", usage());
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("openramble: {message}\n\n{}", usage());
            ExitCode::FAILURE
        }
    }
}

//! `openramble` for Linux servers: transcribe audio files with the OpenRamble
//! engine (Parakeet Ultra through transcribe.cpp) on the processor.
//!
//! The macOS tool lives in `apps/macos/OpenRambleCLI` and leans on LocalASR,
//! which is Swift and Apple-only. This one does the same job on top of the
//! shared Rust core: ffmpeg decodes any input to 16 kHz mono, silence is left
//! out, the rest is cut at pauses into pieces of at most `--max-chunk`
//! seconds, and `--workers` engines recognize the pieces in parallel. Each
//! engine is single-threaded by design (see `ramble_engine::Engine::load`),
//! so parallelism comes from several engines rather than from threads inside
//! one.

use std::fs::File;
use std::io::Write;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Instant;

use openramble_cli::pool::Pool;
use openramble_cli::serve::{Config, Keys, Log, Server, DRAIN_GRACE};
use openramble_cli::{decode, model, output, plan, pool};
use ramble_engine::Engine;

struct Options {
    inputs: Vec<PathBuf>,
    model_dir: PathBuf,
    format: String,
    workers: usize,
    max_chunk: f32,
    gate: bool,
    output_dir: Option<PathBuf>,
    segments: Option<PathBuf>,
    check_model: bool,
}

fn usage() -> &'static str {
    "usage: openramble [options] <audio>...\n\
            openramble serve --keys FILE [--listen HOST:PORT] [--engines N] [--model-dir DIR]\n\
     \n\
     options:\n\
       --format text|json|srt   output format (default text)\n\
       --workers N              parallel engines (default: half the cores, at most 4)\n\
       --max-chunk SECONDS      longest piece sent to the engine, 5-120 (default 20)\n\
       --no-gate                transcribe silence too instead of leaving it out\n\
       --output-dir DIR         write <name>.<ext> files there instead of stdout\n\
       --segments FILE          JSON [{\"start\": s, \"end\": s, \"label\": \"…\"}]: transcribe only these spans\n\
                                (e.g. speaker turns), long spans still cut at pauses; labels are kept\n\
       --model-dir DIR          folder with the .gguf model\n\
                                (default $OPENRAMBLE_MODEL_DIR or ~/opt/openramble-models/parakeet-ultra-gguf)\n\
       --check-model            check the model's size and SHA-256, load it, report the backend and exit\n\
     \n\
     serve: answer POST /v1/speech-to-text (ElevenLabs Scribe's shape) and GET /health\n\
       --keys FILE              lines of `label sha256-of-key`; callers send the key as xi-api-key\n\
       --listen HOST:PORT       where to listen (default 127.0.0.1:8080)\n\
       --engines N              parallel engines (default: one per core)\n\
       --model-dir DIR          as above\n"
}

fn default_model_dir() -> PathBuf {
    std::env::var("OPENRAMBLE_MODEL_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default())
                .join("opt/openramble-models/parakeet-ultra-gguf")
        })
}

fn cores() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(2)
}

fn parse(args: Vec<String>) -> Result<Options, String> {
    let mut options = Options {
        inputs: Vec::new(),
        model_dir: default_model_dir(),
        format: "text".into(),
        workers: (cores() / 2).clamp(1, 4),
        max_chunk: 20.0,
        gate: true,
        output_dir: None,
        segments: None,
        check_model: false,
    };
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Err(String::new()),
            "--format" => options.format = value("--format")?,
            "--workers" => {
                options.workers = value("--workers")?.parse().map_err(|_| "bad --workers")?
            }
            "--max-chunk" => {
                options.max_chunk = value("--max-chunk")?
                    .parse()
                    .map_err(|_| "bad --max-chunk")?
            }
            "--no-gate" => options.gate = false,
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

/// Spans in samples, each with its label.
type Spans = Vec<(Range<u64>, Option<String>)>;

/// Labelled spans from a `--segments` file.
fn spans(file: &Path) -> Result<Spans, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("{}: {e}", file.display()))?;
    let list: Vec<serde_json::Value> =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", file.display()))?;
    list.iter()
        .map(|span| {
            let second = |key: &str| {
                span.get(key)
                    .and_then(|v| v.as_f64())
                    .filter(|s| s.is_finite() && *s >= 0.0)
                    .ok_or_else(|| format!("segment without a valid {key}"))
            };
            let start = (second("start")? * decode::RATE as f64) as u64;
            let end = (second("end")? * decode::RATE as f64) as u64;
            let label = span
                .get("label")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            Ok((start..end, label))
        })
        .collect()
}

fn transcribe(pool: &Pool, input: &Path, options: &Options, model: &str) -> Result<String, String> {
    let started = Instant::now();
    let named = |e: &dyn std::fmt::Display| format!("{}: {e}", input.display());
    let file = File::open(input).map_err(|e| named(&e))?;
    let decoded = decode::decode(file, &std::env::temp_dir(), f64::INFINITY, &|| false)
        .map_err(|e| named(&e))?;
    let spans = match &options.segments {
        Some(file) => spans(file)?,
        None => vec![(0..decoded.samples, None)],
    };
    let (ranges, labels): (Vec<_>, Vec<_>) = spans.into_iter().unzip();
    let pieces = plan::pieces_of_spans(
        &decoded.envelope,
        decoded.samples,
        &ranges,
        options.max_chunk,
        options.gate,
    );
    let rate = decode::RATE as f64;
    let voiced = pieces.iter().map(|(r, _)| r.end - r.start).sum::<u64>() as f64 / rate;
    eprintln!(
        "{}: {:.0} s of audio, {voiced:.0} s to recognize in {} pieces, {} engines",
        input.display(),
        decoded.samples as f64 / rate,
        pieces.len(),
        options.workers
    );
    let job = pool.open().map_err(|refusal| format!("{refusal:?}"))?;
    let outcome = pool
        .admit(
            job,
            Arc::new(decoded.pcm),
            pieces.iter().map(|(range, _)| range.clone()).collect(),
            0.0,
            f64::INFINITY,
        )
        .map_err(|refusal| format!("{refusal:?}"))
        .and_then(|_| match pool.wait(job, &|| false) {
            Some(Ok(recognized)) => Ok(recognized),
            Some(Err(error)) => Err(format!("{error:?}")),
            None => Err("cancelled".into()),
        });
    pool.close(job);
    let recognized = outcome.map_err(|e| named(&e))?;
    let segments = output::segments(&pieces, &labels, &recognized);
    let elapsed = started.elapsed().as_secs_f32();
    Ok(match options.format.as_str() {
        "json" => {
            let value = output::json(
                model,
                decoded.samples as f64 / rate,
                elapsed as f64,
                &segments,
            );
            serde_json::to_string_pretty(&value).expect("JSON values serialize") + "\n"
        }
        "srt" => output::srt(&segments),
        _ => output::text(&segments),
    })
}

fn run(options: Options) -> Result<(), String> {
    let model_file = ramble_engine::model_file(&options.model_dir)
        .ok_or_else(|| format!("no .gguf model in {}", options.model_dir.display()))?;
    if options.check_model {
        println!("model: {}", model_file.display());
        println!("verified: {}", model::verify(&model_file)?);
        let engine = Engine::load(&options.model_dir).map_err(|e| e.to_string())?;
        println!("backend: {:?}", engine.report());
        engine.shutdown();
        if options.inputs.is_empty() {
            return Ok(());
        }
    }
    let engines = pool::load(&options.model_dir, options.workers)?;
    let pool = Pool::start(
        engines
            .into_iter()
            .map(|engine| Box::new(engine) as Box<dyn pool::Recognize>)
            .collect(),
    );
    let model = model::stem(&model_file);
    let done = options.inputs.iter().try_for_each(|input| {
        let started = Instant::now();
        let text = transcribe(&pool, input, &options, &model)?;
        match &options.output_dir {
            Some(dir) => {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                let stem = input
                    .file_stem()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| "transcript".into());
                let extension = if options.format == "text" {
                    "txt"
                } else {
                    &options.format
                };
                let path = dir.join(format!("{stem}.{extension}"));
                std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&path)
                    .and_then(|mut file| file.write_all(text.as_bytes()))
                    .map_err(|e| format!("{}: {e}; not overwriting", path.display()))?;
                eprintln!("wrote {}", path.display());
            }
            None => std::io::stdout()
                .write_all(text.as_bytes())
                .map_err(|e| e.to_string())?,
        }
        eprintln!("done in {:.0} s", started.elapsed().as_secs_f32());
        Ok(())
    });
    // every model must be dropped before the process exits, error or not
    pool.stop();
    done
}

/// `openramble serve`: load and warm the engines, listen, and on SIGTERM or
/// SIGINT drain before dropping every model and exiting 0.
fn serve(args: Vec<String>) -> Result<(), String> {
    let mut listen = "127.0.0.1:8080".to_string();
    let mut model_dir = default_model_dir();
    let mut engines = cores();
    let mut keys_file = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or_else(|| format!("{name} needs a value"));
        match arg.as_str() {
            "-h" | "--help" => return Err(String::new()),
            "--listen" => listen = value("--listen")?,
            "--model-dir" => model_dir = PathBuf::from(value("--model-dir")?),
            "--engines" => {
                engines = value("--engines")?
                    .parse()
                    .ok()
                    .filter(|n| *n > 0)
                    .ok_or("--engines must be at least 1")?
            }
            "--keys" => keys_file = Some(PathBuf::from(value("--keys")?)),
            other => return Err(format!("serve does not take {other}")),
        }
    }
    let keys_file = keys_file.ok_or("serve needs --keys FILE")?;
    let keys = std::fs::read_to_string(&keys_file)
        .map_err(|e| format!("cannot read the keys file: {e}"))
        .and_then(|text| Keys::parse(&text))?;
    let model_file = ramble_engine::model_file(&model_dir)
        .ok_or_else(|| format!("no .gguf model in {}", model_dir.display()))?;
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    for signal in [signal_hook::consts::SIGTERM, signal_hook::consts::SIGINT] {
        signal_hook::flag::register(signal, stop.clone()).map_err(|e| e.to_string())?;
    }
    let loaded = pool::load(&model_dir, engines)?;
    let device = loaded
        .first()
        .map(|engine| engine.report().device.clone())
        .unwrap_or_default();
    let log: Log = Arc::new(|line: &str| eprintln!("{line}"));
    let model = model::stem(&model_file);
    let server = Server::start(
        Config {
            listen,
            keys,
            temp: std::env::temp_dir(),
            model: model.clone(),
            log: log.clone(),
        },
        loaded
            .into_iter()
            .map(|engine| Box::new(engine) as Box<dyn pool::Recognize>)
            .collect(),
    )?;
    log(&format!(
        "openramble serve: {engines} engines on {device}, model {model}, listening on {}",
        server.address()
    ));
    while !stop.load(std::sync::atomic::Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    log("stopping: new jobs get 429; jobs in flight have up to 25 minutes");
    server.stop(DRAIN_GRACE);
    log("stopped");
    Ok(())
}

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let outcome = if args.first().map(String::as_str) == Some("serve") {
        args.remove(0);
        serve(args)
    } else {
        parse(args).and_then(run)
    };
    match outcome {
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

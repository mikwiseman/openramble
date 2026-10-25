//! The server's contract, end to end over loopback: real HTTP, real ffmpeg,
//! the real scheduler, and a fake recognizer that can be held still.
//!
//! Skipped without ffmpeg. The last test uses the real model and the real
//! binary and is ignored by default (`cargo test -- --include-ignored`).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use openramble_cli::pool::Recognize;
use openramble_cli::serve::{Config, Keys, Server};
use ramble_engine::{EngineError, Recognized, Word};
use serde_json::Value;
use sha2::{Digest, Sha256};

const KEY: &str = "contract-test-key";

fn ffmpeg() -> bool {
    let found = Command::new("ffmpeg")
        .arg("-version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if !found {
        eprintln!("no ffmpeg; skipping");
    }
    found
}

/// Holds every recognition until opened.
#[derive(Default)]
struct Gate {
    open: Mutex<bool>,
    changed: Condvar,
}

impl Gate {
    fn set(&self, open: bool) {
        *self.open.lock().unwrap() = open;
        self.changed.notify_all();
    }

    fn pass(&self) {
        let mut open = self.open.lock().unwrap();
        while !*open {
            open = self.changed.wait(open).unwrap();
        }
    }
}

/// Hears the same words in every piece.
struct Fake {
    words: Vec<(&'static str, u32, u32)>,
    calls: Arc<AtomicUsize>,
    gate: Arc<Gate>,
    delay: Duration,
    warmed: AtomicBool,
}

impl Recognize for Fake {
    fn recognize(&self, _samples: &[f32]) -> Result<Recognized, EngineError> {
        if !self.warmed.swap(true, Ordering::SeqCst) {
            return Ok(Recognized::default());
        }
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.gate.pass();
        std::thread::sleep(self.delay);
        let words: Vec<Word> = self
            .words
            .iter()
            .map(|(text, start_ms, end_ms)| Word {
                text: text.to_string(),
                start_ms: *start_ms,
                end_ms: *end_ms,
            })
            .collect();
        Ok(Recognized {
            text: self.words.iter().map(|w| w.0).collect::<Vec<_>>().join(" "),
            words,
            truncated: false,
        })
    }

    fn shutdown(self: Box<Self>) {}
}

struct Harness {
    server: Option<Server>,
    temp: tempfile::TempDir,
    files: tempfile::TempDir,
    log: Arc<Mutex<Vec<String>>>,
    calls: Arc<AtomicUsize>,
    gate: Arc<Gate>,
}

impl Harness {
    fn new(engines: usize, words: &[(&'static str, u32, u32)], delay: Duration) -> Harness {
        let temp = tempfile::tempdir().unwrap();
        let log = Arc::new(Mutex::new(Vec::new()));
        let calls = Arc::new(AtomicUsize::new(0));
        let gate = Arc::new(Gate::default());
        gate.set(true);
        let fakes = (0..engines)
            .map(|_| {
                Box::new(Fake {
                    words: words.to_vec(),
                    calls: calls.clone(),
                    gate: gate.clone(),
                    delay,
                    warmed: AtomicBool::new(false),
                }) as Box<dyn Recognize>
            })
            .collect();
        let digest: String = Sha256::digest(KEY.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let sink = log.clone();
        let server = Server::start(
            Config {
                listen: "127.0.0.1:0".into(),
                keys: Keys::parse(&format!("tests {digest}\n")).unwrap(),
                temp: temp.path().to_path_buf(),
                model: "fake-model".into(),
                log: Arc::new(move |line: &str| sink.lock().unwrap().push(line.to_string())),
            },
            fakes,
        )
        .unwrap();
        Harness {
            server: Some(server),
            temp,
            files: tempfile::tempdir().unwrap(),
            log,
            calls,
            gate,
        }
    }

    fn server(&self) -> &Server {
        self.server.as_ref().unwrap()
    }

    fn address(&self) -> String {
        self.server().address().to_string()
    }

    /// Audio made by ffmpeg: speech-like (a tone whose loudness keeps
    /// changing, so the silence gate keeps it) or silence.
    fn audio(&self, name: &str, seconds: u32, speech: bool, codec: &[&str]) -> PathBuf {
        let path = self.files.path().join(name);
        let source = if speech {
            format!("aevalsrc=0.3*sin(2*PI*440*t)*(0.55+0.45*sin(2*PI*1.3*t)):s=16000:d={seconds}")
        } else {
            format!("anullsrc=r=16000:cl=mono:d={seconds}")
        };
        let made = Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", &source])
            .args(codec)
            .arg(&path)
            .stdin(Stdio::null())
            .status()
            .unwrap();
        assert!(made.success());
        path
    }

    fn temp_is_empty(&self) -> bool {
        std::fs::read_dir(self.temp.path())
            .unwrap()
            .next()
            .is_none()
    }

    fn wait_for(&self, what: &str, done: impl Fn(&Harness) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while !done(self) {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn log_text(&self) -> String {
        self.log.lock().unwrap().join("\n")
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        self.gate.set(true);
        if let Some(server) = self.server.take() {
            server.stop(Duration::ZERO);
        }
    }
}

#[derive(Debug)]
struct Response {
    status: u16,
    headers: Vec<(String, String)>,
    body: Value,
}

impl Response {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    fn detail(&self) -> &str {
        self.body["detail"]["status"].as_str().unwrap_or("")
    }
}

fn read_response(stream: &mut TcpStream) -> Response {
    let mut raw = Vec::new();
    let _ = stream.read_to_end(&mut raw);
    let text = String::from_utf8_lossy(&raw).to_string();
    let (head, body) = text.split_once("\r\n\r\n").expect("a complete response");
    let mut lines = head.split("\r\n");
    let status = lines
        .next()
        .unwrap()
        .split(' ')
        .nth(1)
        .unwrap()
        .parse()
        .unwrap();
    let headers = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(n, v)| (n.trim().to_string(), v.trim().to_string()))
        .collect();
    Response {
        status,
        headers,
        body: serde_json::from_str(body).unwrap_or(Value::Null),
    }
}

fn connect(address: &str) -> TcpStream {
    let stream = TcpStream::connect(address).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    stream
}

fn exchange(address: &str, request: &[u8]) -> Response {
    let mut stream = connect(address);
    stream.write_all(request).unwrap();
    read_response(&mut stream)
}

fn multipart(fields: &[(&str, &str)], file_name: &str, file: &[u8]) -> (String, Vec<u8>) {
    let boundary = "----contract7MA4YWxkTrZu0gW";
    let mut body = Vec::new();
    for (name, value) in fields {
        body.extend_from_slice(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n")
                .as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file_name}\"\r\n\
             Content-Type: application/octet-stream\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(file);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

fn post_form(key: Option<&str>, fields: &[(&str, &str)], file_name: &str, file: &[u8]) -> Vec<u8> {
    let (content_type, body) = multipart(fields, file_name, file);
    let key = key
        .map(|k| format!("xi-api-key: {k}\r\n"))
        .unwrap_or_default();
    let mut request = format!(
        "POST /v1/speech-to-text HTTP/1.1\r\nHost: test\r\n{key}Content-Type: {content_type}\r\n\
         Content-Length: {}\r\n\r\n",
        body.len()
    )
    .into_bytes();
    request.extend_from_slice(&body);
    request
}

fn post_chunked(query: &str, file: &[u8]) -> Vec<u8> {
    let mut request = format!(
        "POST /v1/speech-to-text?{query} HTTP/1.1\r\nHost: test\r\nxi-api-key: {KEY}\r\n\
         Transfer-Encoding: chunked\r\n\r\n"
    )
    .into_bytes();
    for chunk in file.chunks(7_777) {
        request.extend_from_slice(format!("{:x}\r\n", chunk.len()).as_bytes());
        request.extend_from_slice(chunk);
        request.extend_from_slice(b"\r\n");
    }
    request.extend_from_slice(b"0\r\n\r\n");
    request
}

fn health(address: &str) -> Value {
    exchange(address, b"GET /health HTTP/1.1\r\nHost: test\r\n\r\n").body
}

const WORDS: &[(&str, u32, u32)] = &[("alpha", 100, 400), ("beta", 500, 900)];

#[test]
fn a_missing_or_wrong_key_is_refused() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, WORDS, Duration::ZERO);
    for key in [None, Some("not-the-key")] {
        let response = exchange(&harness.address(), &post_form(key, &[], "a.m4a", b"x"));
        assert_eq!(response.status, 401, "{key:?}");
        assert_eq!(response.detail(), "invalid_api_key");
        assert_eq!(response.header("Connection"), Some("close"));
    }
    assert_eq!(harness.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn an_upload_over_two_gib_is_refused_from_its_length_alone() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, WORDS, Duration::ZERO);
    let started = Instant::now();
    let response = exchange(
        &harness.address(),
        format!(
            "POST /v1/speech-to-text HTTP/1.1\r\nxi-api-key: {KEY}\r\n\
             Content-Type: audio/mp4\r\nContent-Length: 3000000000\r\n\r\n"
        )
        .as_bytes(),
    );
    assert_eq!(response.status, 413);
    assert_eq!(response.detail(), "file_too_large");
    // answered at once, then the server waited up to 2 s for the body
    assert!(started.elapsed() < Duration::from_secs(4));
    assert!(harness.temp_is_empty());
}

#[test]
fn multipart_and_raw_chunked_uploads_are_both_transcribed() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(2, WORDS, Duration::ZERO);
    let m4a = harness.audio("note.m4a", 30, true, &["-c:a", "aac"]);
    let response = exchange(
        &harness.address(),
        &post_form(
            Some(KEY),
            &[
                ("model_id", "scribe_v2"),
                ("timestamps_granularity", "word"),
                ("tag_audio_events", "false"),
                ("diarize", "false"),
            ],
            "note.m4a",
            &std::fs::read(&m4a).unwrap(),
        ),
    );
    assert_eq!(response.status, 200, "{response:?}");
    let body = &response.body;
    // 30 s of speech is two pieces of about 15 s
    assert_eq!(body["text"], "alpha beta alpha beta");
    let words = body["words"].as_array().unwrap();
    assert_eq!(words.len(), 7);
    let joined: String = words.iter().map(|w| w["text"].as_str().unwrap()).collect();
    assert_eq!(joined, "alpha beta alpha beta");
    assert_eq!(words[0]["start"], 0.1);
    assert!(words[4]["start"].as_f64().unwrap() > 10.0, "file offsets");
    assert!(body["language_code"].is_null());
    assert!(body.get("detail").is_none() && body.get("error").is_none());
    assert_eq!(
        response.header("request-id").unwrap(),
        body["transcription_id"].as_str().unwrap()
    );
    assert!(body["transcription_id"]
        .as_str()
        .unwrap()
        .starts_with("or_"));

    let opus = harness.audio("voice.oga", 8, true, &["-c:a", "libopus"]);
    let response = exchange(
        &harness.address(),
        &post_chunked(
            "model_id=scribe_v2&timestamps_granularity=none",
            &std::fs::read(&opus).unwrap(),
        ),
    );
    assert_eq!(response.status, 200, "{response:?}");
    assert_eq!(response.body["text"], "alpha beta");
    assert_eq!(response.body["words"], serde_json::json!([]));
    assert!(harness.temp_is_empty());
}

#[test]
fn the_ninth_job_is_told_to_retry_and_health_counts_the_eight() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(2, WORDS, Duration::ZERO);
    let wav = std::fs::read(harness.audio("short.wav", 5, true, &[])).unwrap();
    harness.gate.set(false);
    let address = harness.address();
    let clients: Vec<_> = (0..8)
        .map(|_| {
            let (address, wav) = (address.clone(), wav.clone());
            std::thread::spawn(move || {
                exchange(&address, &post_form(Some(KEY), &[], "s.wav", &wav))
            })
        })
        .collect();
    harness.wait_for("eight open jobs", |h| h.server().health().jobs == 8);
    // a 5 s file is one 5 s piece: the gate's padding stops at the file's ends
    harness.wait_for("all eight admitted", |h| {
        h.server().health().queued_seconds > 8.0 * 4.9
    });
    let report = health(&address);
    assert_eq!(report["engines"], 2);
    assert_eq!(report["jobs"], 8);
    assert_eq!(report["draining"], false);
    let queued = report["queued_seconds"].as_f64().unwrap();
    assert!((8.0 * 4.9..=8.0 * 5.1).contains(&queued), "{report}");

    let ninth = exchange(&address, &post_form(Some(KEY), &[], "s.wav", &wav));
    assert_eq!(ninth.status, 429);
    assert_eq!(ninth.detail(), "system_busy");
    let retry: u64 = ninth.header("Retry-After").unwrap().parse().unwrap();
    assert!(retry >= 1);

    harness.gate.set(true);
    for client in clients {
        assert_eq!(client.join().unwrap().status, 200);
    }
    let idle = health(&address);
    assert_eq!(idle["jobs"], 0);
    assert_eq!(idle["queued_seconds"].to_string(), "0.0");
}

#[test]
fn a_client_that_leaves_cancels_its_job_and_leaves_no_file() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, WORDS, Duration::from_millis(100));
    let wav = std::fs::read(harness.audio("long.wav", 300, true, &[])).unwrap();
    let mut stream = connect(&harness.address());
    stream
        .write_all(&post_form(Some(KEY), &[], "long.wav", &wav))
        .unwrap();
    harness.wait_for("the job to start", |h| h.calls.load(Ordering::SeqCst) > 0);
    drop(stream);
    let left = Instant::now();
    harness.wait_for("the job to be cancelled", |h| h.server().health().jobs == 0);
    assert!(
        left.elapsed() < Duration::from_millis(500),
        "{:?}",
        left.elapsed()
    );
    let calls = harness.calls.load(Ordering::SeqCst);
    std::thread::sleep(Duration::from_millis(400));
    assert!(
        harness.calls.load(Ordering::SeqCst) <= calls + 1,
        "pieces kept running"
    );
    assert!(calls < 10, "{calls} of about 19 pieces ran");
    harness.wait_for("the files to go", |h| h.temp_is_empty());
    assert!(harness.log_text().contains("client_left"));
}

#[test]
fn a_deadline_the_queue_cannot_keep_gets_429_and_an_impossible_one_422() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(2, WORDS, Duration::ZERO);
    let wav = std::fs::read(harness.audio("track.wav", 700, true, &[])).unwrap();
    harness.gate.set(false);
    let address = harness.address();
    let first = {
        let (address, wav) = (address.clone(), wav.clone());
        std::thread::spawn(move || exchange(&address, &post_form(Some(KEY), &[], "t.wav", &wav)))
    };
    harness.wait_for("the first track to queue", |h| {
        h.server().health().queued_seconds > 600.0
    });
    // 1.15 * (700 + 700) * 0.45 / 2 engines = 362 s > 300
    let busy = exchange(
        &address,
        &post_form(Some(KEY), &[("deadline_s", "300")], "t.wav", &wav),
    );
    assert_eq!(busy.status, 429, "{busy:?}");
    assert_eq!(busy.detail(), "system_busy");
    let retry: u64 = busy.header("Retry-After").unwrap().parse().unwrap();
    assert!((175..=185).contains(&retry), "Retry-After {retry}");
    // 1.15 * 700 * 0.45 / 2 = 181 s > 100, even with nothing ahead
    let impossible = exchange(
        &address,
        &post_form(Some(KEY), &[("deadline_s", "100")], "t.wav", &wav),
    );
    assert_eq!(impossible.status, 422);
    assert_eq!(impossible.detail(), "audio_too_long_for_deadline");
    harness.gate.set(true);
    assert_eq!(first.join().unwrap().status, 200);
}

#[test]
fn silence_is_empty_text_without_calling_the_engine() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, WORDS, Duration::ZERO);
    let wav = std::fs::read(harness.audio("silence.wav", 10, false, &[])).unwrap();
    let response = exchange(
        &harness.address(),
        &post_form(Some(KEY), &[], "s.wav", &wav),
    );
    assert_eq!(response.status, 200);
    assert_eq!(response.body["text"], "");
    assert_eq!(response.body["words"], serde_json::json!([]));
    assert_eq!(harness.calls.load(Ordering::SeqCst), 0);
    let log = harness.log_text();
    assert!(log.contains(" voiced=0.0s pieces=0 "), "{log}");
}

#[test]
fn while_draining_new_jobs_are_told_the_server_is_restarting() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, WORDS, Duration::ZERO);
    harness.server().drain();
    let response = exchange(
        &harness.address(),
        &post_form(Some(KEY), &[], "a.wav", b"RIFF"),
    );
    assert_eq!(response.status, 429);
    assert_eq!(response.detail(), "shutting_down");
    assert_eq!(response.header("Retry-After"), Some("60"));
    assert_eq!(health(&harness.address())["draining"], true);
}

#[test]
fn the_log_holds_no_file_names_key_terms_or_words() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, &[("zanzibarword", 100, 400)], Duration::ZERO);
    let m4a = std::fs::read(harness.audio("x.m4a", 4, true, &["-c:a", "aac"])).unwrap();
    let response = exchange(
        &harness.address(),
        &post_form(
            Some(KEY),
            &[("keyterms", "Quetzalcoatlterm"), ("keyterms", "Wai")],
            "private-meeting-name.m4a",
            &m4a,
        ),
    );
    assert_eq!(response.status, 200);
    assert_eq!(response.body["text"], "zanzibarword");
    let bad = exchange(
        &harness.address(),
        &post_form(
            Some(KEY),
            &[("diarize", "true")],
            "private-meeting-name.m4a",
            &m4a,
        ),
    );
    assert_eq!(bad.detail(), "diarization_unsupported");
    let log = harness.log_text();
    assert!(log.contains(" 200 ") && log.contains(" 400 "), "{log}");
    for secret in ["private-meeting", "Quetzalcoatl", "zanzibar", KEY] {
        assert!(!log.contains(secret), "the log contains {secret}: {log}");
    }
}

#[test]
fn other_paths_methods_and_shapes() {
    if !ffmpeg() {
        return;
    }
    let harness = Harness::new(1, &[("Um,", 0, 200), ("hello", 300, 600)], Duration::ZERO);
    let address = harness.address();
    let missing = exchange(&address, b"GET /v1/models HTTP/1.1\r\n\r\n");
    assert_eq!((missing.status, missing.detail()), (404, "not_found"));
    let wrong = exchange(&address, b"GET /v1/speech-to-text HTTP/1.1\r\n\r\n");
    assert_eq!((wrong.status, wrong.detail()), (405, "method_not_allowed"));

    let m4a = std::fs::read(harness.audio("x.m4a", 4, true, &["-c:a", "aac"])).unwrap();
    let cli = exchange(
        &address,
        &post_form(Some(KEY), &[("output_format", "openramble")], "x.m4a", &m4a),
    );
    assert_eq!(cli.status, 200);
    let mut keys: Vec<&str> = cli
        .body
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    assert_eq!(keys, ["duration", "elapsed", "model", "segments", "text"]);
    assert_eq!(cli.body["model"], "fake-model");
    assert_eq!(cli.body["text"], "Um, hello");

    let clean = exchange(
        &address,
        &post_form(Some(KEY), &[("no_verbatim", "true")], "x.m4a", &m4a),
    );
    assert_eq!(clean.body["text"], "Hello");
    // the cleaned word keeps the raw word's time
    assert_eq!(clean.body["words"][0]["start"], 0.3);

    let garbage = exchange(
        &address,
        &post_form(Some(KEY), &[], "x.m4a", b"definitely not audio"),
    );
    assert_eq!((garbage.status, garbage.detail()), (422, "invalid_audio"));
    let refused = exchange(
        &address,
        &post_form(
            Some(KEY),
            &[("timestamps_granularity", "character")],
            "x.m4a",
            &m4a,
        ),
    );
    assert_eq!(
        (refused.status, refused.detail()),
        (400, "unsupported_parameter")
    );
    assert!(harness.temp_is_empty());
}

// ---------------------------------------------------------------------------
// The real binary and model.

fn model_directory() -> Option<PathBuf> {
    if let Ok(directory) = std::env::var("OPENRAMBLE_MODEL_DIR") {
        return Some(PathBuf::from(directory));
    }
    let manifest = ramble_model::Manifest::parse(include_str!(
        "../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json"
    ))
    .ok()?;
    let root = PathBuf::from(std::env::var("HOME").ok()?)
        .join("Library/Application Support/OpenRamble/Models");
    let store = ramble_model::ModelStore::new(manifest, root);
    (store.state() == ramble_model::ModelState::Ready).then(|| store.engine_directory())
}

fn spoken(directory: &Path) -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let aiff = directory.join("speech.aiff");
    let m4a = directory.join("speech.m4a");
    let text = "The server keeps working while it is asked to stop. ".repeat(6);
    Command::new("say")
        .args(["-v", "Samantha", "-o"])
        .arg(&aiff)
        .arg(text)
        .status()
        .ok()?
        .success()
        .then_some(())?;
    Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-i"])
        .arg(&aiff)
        .args(["-c:a", "aac"])
        .arg(&m4a)
        .status()
        .ok()?
        .success()
        .then_some(m4a)
}

#[test]
#[ignore = "loads the real model; run with --include-ignored"]
fn a_stop_during_a_job_lets_it_finish_and_exits_cleanly() {
    let Some(model) = model_directory() else {
        eprintln!("no installed model; skipping");
        return;
    };
    if !ffmpeg() {
        return;
    }
    let directory = tempfile::tempdir().unwrap();
    let Some(speech) = spoken(directory.path()) else {
        eprintln!("no speech; skipping");
        return;
    };
    let digest: String = Sha256::digest(KEY.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let keys = directory.path().join("keys");
    std::fs::write(&keys, format!("tests {digest}\n")).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_openramble"))
        .args([
            "serve",
            "--listen",
            "127.0.0.1:0",
            "--engines",
            "1",
            "--keys",
        ])
        .arg(&keys)
        .arg("--model-dir")
        .arg(&model)
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = child.stderr.take().unwrap();
    let (lines, receive) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        use std::io::BufRead;
        for line in std::io::BufReader::new(stderr)
            .lines()
            .map_while(Result::ok)
        {
            if lines.send(line).is_err() {
                break;
            }
        }
    });
    let address = loop {
        let line = receive.recv_timeout(Duration::from_secs(120)).unwrap();
        if let Some(address) = line.split("listening on ").nth(1) {
            break address.trim().to_string();
        }
    };
    let request = post_form(
        Some(KEY),
        &[],
        "speech.m4a",
        &std::fs::read(&speech).unwrap(),
    );
    let client = {
        let address = address.clone();
        std::thread::spawn(move || exchange(&address, &request))
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    while health(&address)["queued_seconds"].as_f64().unwrap_or(0.0) == 0.0 {
        assert!(Instant::now() < deadline, "the job never started");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(Command::new("kill")
        .args(["-TERM", &child.id().to_string()])
        .status()
        .unwrap()
        .success());
    let response = client.join().unwrap();
    assert_eq!(response.status, 200, "{response:?}");
    let text = response.body["text"].as_str().unwrap().to_lowercase();
    assert!(text.contains("server") && text.contains("stop"), "{text}");
    let status = child.wait().unwrap();
    assert_eq!(status.code(), Some(0), "exited with {status:?}");
}

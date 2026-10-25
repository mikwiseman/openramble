//! `openramble serve`: the transcription server.
//!
//! The port answers from the moment the server starts until it exits: while
//! the engines load, requests get 429 `starting` and `/health` 503, and while
//! it stops, 429 `shutting_down`, so a caller behind the proxy sees something
//! it retries rather than a 502.
//!
//! One thread per connection and one request per connection. A request goes
//! head → key → size → job slot → 100 Continue → upload into an unnamed file
//! → parameters → decode into unnamed PCM (the upload is freed) → plan →
//! admission → the engines → the response. The client's connection is
//! watched while it waits, and a client that leaves cancels its job.
//!
//! Errors that can be told from the head (a bad key, an upload over 2 GiB)
//! are answered at once, then the server stops writing and reads what is
//! still coming for up to 2 s, so the client sees the status rather than a
//! reset. A 429 for a full server is answered after the body has been read,
//! unless the client asked `Expect: 100-continue`: a caller that only retries
//! on 429 must always see it.
//!
//! The log has one line per request: who (the key's label), the status and
//! counts and timings. Never text, words, key terms or file names.

use std::collections::hash_map::RandomState;
use std::hash::BuildHasher;
use std::io::{self, BufWriter, Read, Write};
use std::ops::Range;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ramble_engine::Recognized;
use sha2::{Digest, Sha256};

use crate::decode::{self, DecodeError};
use crate::http::{self, Body, Head, HttpError, Input};
use crate::listen::{Conn, Listener};
use crate::pool::{Health, Pool, Recognize};
use crate::schedule::{Class, JobError, JobId, Refusal};
use crate::scribe::{self, ApiError, Format};
use crate::{output, plan, verbatim};

/// The largest upload.
pub const UPLOAD_CAP: u64 = 2 << 30;
/// The longest audio.
pub const AUDIO_CAP_S: f64 = 12.0 * 3600.0;
/// The longest piece the engine is given.
pub const PIECE_CAP_S: f32 = 20.0;
/// Connections served at once; more wait to be accepted.
pub const MAX_CONNECTIONS: usize = 32;
/// How long jobs in flight may run on after a stop is asked for.
pub const DRAIN_GRACE: Duration = Duration::from_secs(25 * 60);
const HEAD_TIMEOUT: Duration = Duration::from_secs(30);
const BODY_IDLE: Duration = Duration::from_secs(120);
const WRITE_TIMEOUT: Duration = Duration::from_secs(60);
const LINGER: Duration = Duration::from_secs(2);
const ACCEPT_POLL: Duration = Duration::from_millis(20);
const WARM_UP_SAMPLES: usize = 32_000;

/// One caller, as the keys file names it.
#[derive(Debug, Clone, PartialEq)]
pub struct Caller {
    /// Who it is, for the log.
    pub label: String,
    /// How long it waits in all, for requests that send no `deadline_s`.
    pub deadline_s: Option<f64>,
}

/// Who may call: callers with the SHA-256 of their key.
#[derive(Debug, Clone)]
pub struct Keys {
    entries: Vec<(Caller, Vec<u8>)>,
}

impl Keys {
    /// Lines of `label sha256hex [seconds]`, the seconds being how long that
    /// caller waits in all; blank lines and `#` comments are skipped. Errors
    /// name the line, never its contents.
    pub fn parse(text: &str) -> Result<Keys, String> {
        let mut entries = Vec::new();
        for (number, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let number = number + 1;
            let mut parts = line.split_whitespace();
            let (Some(label), Some(digest), wait, None) =
                (parts.next(), parts.next(), parts.next(), parts.next())
            else {
                return Err(format!(
                    "keys line {number} is not `label sha256hex [seconds]`"
                ));
            };
            let digest = hex(digest)
                .filter(|bytes| bytes.len() == 32)
                .ok_or_else(|| format!("keys line {number} does not hold a SHA-256 in hex"))?;
            let deadline_s = wait
                .map(|wait| {
                    wait.parse::<f64>()
                        .ok()
                        .filter(|s| s.is_finite() && *s > 0.0 && *s <= scribe::MAX_DEADLINE_S)
                        .ok_or_else(|| {
                            format!(
                                "keys line {number}: the wait must be seconds above 0 and at most 86400"
                            )
                        })
                })
                .transpose()?;
            let caller = Caller {
                label: label.to_string(),
                deadline_s,
            };
            entries.push((caller, digest));
        }
        if entries.is_empty() {
            return Err("the keys file holds no keys".into());
        }
        Ok(Keys { entries })
    }

    /// The caller whose key this is.
    pub fn check(&self, presented: &str) -> Option<&Caller> {
        let digest = Sha256::digest(presented.trim().as_bytes());
        self.entries
            .iter()
            .find(|(_, stored)| {
                stored.len() == digest.len()
                    && stored
                        .iter()
                        .zip(digest.iter())
                        .fold(0u8, |differ, (a, b)| differ | (a ^ b))
                        == 0
            })
            .map(|(caller, _)| caller)
    }
}

fn hex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok())
        .collect()
}

/// Where log lines go: standard error in the server, a list in tests.
pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

pub struct Config {
    /// `host:port` to listen on.
    pub listen: String,
    pub keys: Keys,
    /// Where the unnamed temporary files are made.
    pub temp: PathBuf,
    /// The model's name, for `output_format=openramble`.
    pub model: String,
    pub log: Log,
}

struct Shared {
    config: Config,
    /// Set once the engines are loaded and warm.
    pool: OnceLock<Pool>,
    connections: Mutex<usize>,
    freed: Condvar,
    stopping: AtomicBool,
}

pub struct Server {
    shared: Arc<Shared>,
    address: String,
    acceptor: Option<JoinHandle<()>>,
}

impl Server {
    /// Listen, then load the engines with `load` and warm every one up,
    /// answering 429 `starting` meanwhile. Returns once they are ready. The
    /// engines are dropped properly if anything fails.
    pub fn start(
        config: Config,
        load: impl FnOnce() -> Result<Vec<Box<dyn Recognize>>, String>,
    ) -> Result<Server, String> {
        let listener = Listener::bind(&config.listen)
            .map_err(|error| format!("cannot listen on {}: {error}", config.listen))?;
        let address = listener.address();
        let shared = Arc::new(Shared {
            config,
            pool: OnceLock::new(),
            connections: Mutex::new(0),
            freed: Condvar::new(),
            stopping: AtomicBool::new(false),
        });
        let acceptor = {
            let shared = shared.clone();
            std::thread::Builder::new()
                .name("accept".into())
                .spawn(move || accept(&shared, &listener))
                .map_err(|error| error.to_string())?
        };
        let server = Server {
            shared,
            address,
            acceptor: Some(acceptor),
        };
        let recognizers = match load() {
            Ok(recognizers) => recognizers,
            Err(error) => {
                server.stop(Duration::ZERO);
                return Err(error);
            }
        };
        let warmed: Vec<(Box<dyn Recognize>, Result<(), String>)> = std::thread::scope(|scope| {
            let warming: Vec<_> = recognizers
                .into_iter()
                .map(|recognizer| {
                    scope.spawn(move || {
                        let warmed = recognizer
                            .recognize(&vec![0.0; WARM_UP_SAMPLES])
                            .map(|_| ())
                            .map_err(|error| error.to_string());
                        (recognizer, warmed)
                    })
                })
                .collect();
            warming
                .into_iter()
                .map(|handle| handle.join().expect("warming an engine panicked"))
                .collect()
        });
        let failure = warmed.iter().find_map(|(_, result)| result.clone().err());
        let recognizers: Vec<_> = warmed
            .into_iter()
            .map(|(recognizer, _)| recognizer)
            .collect();
        if let Some(error) = failure {
            for recognizer in recognizers {
                recognizer.shutdown();
            }
            server.stop(Duration::ZERO);
            return Err(format!("an engine failed to warm up: {error}"));
        }
        if server.shared.pool.set(Pool::start(recognizers)).is_err() {
            unreachable!("the engines are set once");
        }
        Ok(server)
    }

    fn pool(&self) -> &Pool {
        self.shared
            .pool
            .get()
            .expect("a started server has its engines")
    }

    /// The address actually listened on.
    pub fn address(&self) -> &str {
        &self.address
    }

    pub fn health(&self) -> Health {
        self.pool().health()
    }

    /// Refuse new jobs with 429 `shutting_down`; jobs in flight carry on.
    pub fn drain(&self) {
        self.pool().drain();
    }

    /// Drain, give the jobs in flight up to `grace`, end the rest with 429
    /// `shutting_down`, drop every engine and only then stop listening, so
    /// the port answers until the process exits.
    pub fn stop(mut self, grace: Duration) {
        if let Some(pool) = self.shared.pool.get() {
            pool.drain();
            let deadline = Instant::now() + grace;
            while pool.health().jobs > 0 && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(100));
            }
            pool.abort_all();
            // let the connections whose jobs just ended write their 429
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut open = lock(&self.shared.connections);
            while *open > 0 && Instant::now() < deadline {
                open = self
                    .shared
                    .freed
                    .wait_timeout(open, Duration::from_millis(100))
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            }
            drop(open);
            // each engine finishes the piece it holds; new requests still get
            // 429 shutting_down meanwhile
            pool.stop();
        }
        self.shared.stopping.store(true, Ordering::SeqCst);
        self.shared.freed.notify_all();
        if let Some(acceptor) = self.acceptor.take() {
            let _ = acceptor.join();
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn accept(shared: &Arc<Shared>, listener: &Listener) {
    while !shared.stopping.load(Ordering::SeqCst) {
        {
            let mut open = lock(&shared.connections);
            while *open >= MAX_CONNECTIONS && !shared.stopping.load(Ordering::SeqCst) {
                open = shared
                    .freed
                    .wait_timeout(open, ACCEPT_POLL)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            }
        }
        let conn = match listener.accept(ACCEPT_POLL) {
            Ok(Some(conn)) => conn,
            Ok(None) => continue,
            Err(error) => {
                (shared.config.log)(&format!("accept failed: {error}"));
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
        };
        *lock(&shared.connections) += 1;
        let worker = shared.clone();
        let spawned = std::thread::Builder::new()
            .name("conn".into())
            .spawn(move || {
                let _slot = Slot(&worker);
                handle(&worker, conn);
            });
        if spawned.is_err() {
            *lock(&shared.connections) -= 1;
            shared.freed.notify_all();
        }
    }
}

/// Frees a connection slot however the connection's thread ends.
struct Slot<'a>(&'a Shared);

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        *lock(&self.0.connections) -= 1;
        self.0.freed.notify_all();
    }
}

/// Closes a job however the request ends, a panic included.
struct Job<'a> {
    pool: &'a Pool,
    id: JobId,
}

impl Drop for Job<'_> {
    fn drop(&mut self) {
        self.pool.close(self.id);
    }
}

fn request_id() -> String {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let state = RandomState::new();
    format!("or_{:016x}{:016x}", state.hash_one(n), state.hash_one(!n))
}

/// What the log says about a request: counts and timings only.
#[derive(Default)]
struct Record {
    label: String,
    status: u16,
    code: &'static str,
    audio_s: f64,
    voiced_s: f64,
    pieces: usize,
    class: &'static str,
    upload_s: f64,
    decode_s: f64,
}

fn handle(shared: &Shared, conn: Conn) {
    let started = Instant::now();
    let id = request_id();
    let _ = conn.set_write_timeout(Some(WRITE_TIMEOUT));
    let _ = conn.set_read_timeout(Some(HEAD_TIMEOUT));
    let mut input = Input::new(conn);
    let head = match http::read_head(&mut input) {
        Ok(head) => head,
        Err(HttpError::BadRequest(message)) => {
            answer_early(&mut input, &id, &ApiError::invalid(message));
            return;
        }
        Err(_) => return,
    };
    let mut record = Record::default();
    match (head.method.as_str(), head.path.as_str()) {
        ("GET", "/health") => {
            let Some(pool) = shared.pool.get() else {
                let starting = ApiError {
                    status: 503,
                    ..ApiError::starting()
                };
                return answer_early(&mut input, &id, &starting);
            };
            let health = pool.health();
            let body = serde_json::json!({
                "engines": health.engines,
                "jobs": health.jobs,
                "queued_seconds": (health.queued_seconds * 10.0).round() / 10.0,
                "draining": health.draining,
            });
            let _ = respond(input.get_mut(), 200, &id, &body, None);
            linger(&mut input);
            return;
        }
        ("POST", "/v1/speech-to-text") => {
            transcribe(shared, &mut input, &head, &id, started, &mut record);
        }
        (_, "/health" | "/v1/speech-to-text") => {
            fail_early(
                &mut input,
                &id,
                &ApiError::method_not_allowed(),
                &mut record,
            );
        }
        _ => fail_early(&mut input, &id, &ApiError::not_found(), &mut record),
    }
    let label = if record.label.is_empty() {
        "-"
    } else {
        &record.label
    };
    (shared.config.log)(&format!(
        "{id} {label} {} {} audio={:.1}s voiced={:.1}s pieces={} class={} upload={:.1}s decode={:.1}s total={:.1}s",
        record.status,
        if record.code.is_empty() { "ok" } else { record.code },
        record.audio_s,
        record.voiced_s,
        record.pieces,
        if record.class.is_empty() { "-" } else { record.class },
        record.upload_s,
        record.decode_s,
        started.elapsed().as_secs_f64(),
    ));
}

fn respond(
    out: &mut impl Write,
    status: u16,
    id: &str,
    body: &serde_json::Value,
    retry_after_s: Option<u64>,
) -> io::Result<()> {
    let mut extra = vec![("request-id", id.to_string())];
    if let Some(seconds) = retry_after_s {
        extra.push(("Retry-After", seconds.to_string()));
    }
    let bytes = serde_json::to_vec(body).expect("JSON values serialize");
    http::write_response(out, status, &extra, &bytes)
}

/// Read what the client still sends for up to 2 s, then let the connection
/// close: closing with unread input would reset it under the response.
fn linger(input: &mut Input<Conn>) {
    input.get_ref().shutdown_write();
    let deadline = Instant::now() + LINGER;
    let mut sink = [0u8; 16 * 1024];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() || input.get_ref().set_read_timeout(Some(left)).is_err() {
            return;
        }
        match input.read(&mut sink) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}

/// Answer now, without reading the body.
fn answer_early(input: &mut Input<Conn>, id: &str, error: &ApiError) {
    let _ = respond(
        input.get_mut(),
        error.status,
        id,
        &error.body(),
        error.retry_after_s,
    );
    linger(input);
}

fn fail_early(input: &mut Input<Conn>, id: &str, error: &ApiError, record: &mut Record) {
    record.status = error.status;
    record.code = error.code;
    answer_early(input, id, error);
}

/// Answer after the request has been read completely.
fn fail(input: &mut Input<Conn>, id: &str, error: &ApiError, record: &mut Record) {
    record.status = error.status;
    record.code = error.code;
    let _ = respond(
        input.get_mut(),
        error.status,
        id,
        &error.body(),
        error.retry_after_s,
    );
}

fn refusal(refused: Refusal) -> ApiError {
    match refused {
        Refusal::Busy { retry_after_s } => ApiError::busy(retry_after_s),
        Refusal::ShuttingDown => ApiError::shutting_down(),
        Refusal::TooLongForDeadline => ApiError::too_long_for_deadline(),
    }
}

fn transcribe(
    shared: &Shared,
    input: &mut Input<Conn>,
    head: &Head,
    id: &str,
    started: Instant,
    record: &mut Record,
) {
    let Some(caller) = head
        .header("xi-api-key")
        .and_then(|key| shared.config.keys.check(key))
    else {
        return fail_early(input, id, &ApiError::invalid_key(), record);
    };
    record.label = caller.label.clone();
    if head
        .content_length()
        .is_some_and(|length| length > UPLOAD_CAP)
    {
        return fail_early(input, id, &ApiError::too_large(), record);
    }
    let opened = match shared.pool.get() {
        Some(pool) => pool.open().map(|job| (pool, job)).map_err(refusal),
        None => Err(ApiError::starting()),
    };
    let (pool, job) = match opened {
        Ok((pool, job)) => (pool, Job { pool, id: job }),
        Err(error) => {
            if head.expects_continue() {
                return fail_early(input, id, &error, record);
            }
            // a caller that retries only on 429 must see it, so the body is
            // read first
            let _ = input.get_ref().set_read_timeout(Some(BODY_IDLE));
            return match http::discard(&mut Body::new(input, head.framing), UPLOAD_CAP) {
                Ok(true) => fail(input, id, &error, record),
                _ => fail_early(input, id, &error, record),
            };
        }
    };
    if head.expects_continue() && http::write_continue(input.get_mut()).is_err() {
        return;
    }

    // the upload, into a file with no name
    let _ = input.get_ref().set_read_timeout(Some(BODY_IDLE));
    let upload = match tempfile::tempfile_in(&shared.config.temp) {
        Ok(file) => file,
        Err(error) => {
            (shared.config.log)(&format!("{id} cannot make a temporary file: {error}"));
            return fail_early(input, id, &ApiError::internal(), record);
        }
    };
    let mut sink = BufWriter::with_capacity(1 << 20, upload);
    let fields = match http::read_body(head, input, &mut sink, UPLOAD_CAP) {
        Ok((fields, _)) => fields,
        Err(HttpError::BadRequest(message)) => {
            return fail_early(input, id, &ApiError::invalid(message), record)
        }
        Err(HttpError::TooLarge) => return fail_early(input, id, &ApiError::too_large(), record),
        Err(HttpError::Closed | HttpError::Io(_)) => {
            record.code = "client_left";
            return;
        }
    };
    let upload = match sink.into_inner() {
        Ok(file) => file,
        Err(error) => {
            (shared.config.log)(&format!("{id} cannot write the upload: {}", error.error()));
            return fail(input, id, &ApiError::internal(), record);
        }
    };
    record.upload_s = started.elapsed().as_secs_f64();
    let params = match scribe::params(&fields) {
        Ok(params) => params,
        Err(error) => return fail(input, id, &error, record),
    };

    // decoding frees the upload as soon as ffmpeg is done with it
    let decoding = Instant::now();
    let conn = input.get_ref();
    let decoded = match decode::decode(upload, &shared.config.temp, AUDIO_CAP_S, &|| conn.hung_up())
    {
        Ok(decoded) => decoded,
        Err(DecodeError::InvalidAudio) => {
            return fail(input, id, &ApiError::invalid_audio(), record)
        }
        Err(DecodeError::TooLong) => return fail(input, id, &ApiError::too_long(), record),
        Err(DecodeError::Cancelled) => {
            record.code = "client_left";
            return;
        }
        Err(DecodeError::Io(error)) => {
            (shared.config.log)(&format!("{id} decoding failed: {error}"));
            return fail(input, id, &ApiError::internal(), record);
        }
    };
    record.decode_s = decoding.elapsed().as_secs_f64();
    let rate = decode::RATE as f64;
    record.audio_s = decoded.samples as f64 / rate;
    let whole = 0..decoded.samples;
    let planned = plan::pieces_of_spans(
        &decoded.envelope,
        decoded.samples,
        std::slice::from_ref(&whole),
        PIECE_CAP_S,
        true,
    );
    let pieces: Vec<Range<u64>> = planned.iter().map(|(range, _)| range.clone()).collect();
    record.pieces = pieces.len();
    // summed in samples: an empty f64 sum is -0.0, which the log would print
    record.voiced_s = pieces.iter().map(|r| r.end - r.start).sum::<u64>() as f64 / rate;

    let elapsed = started.elapsed().as_secs_f64();
    match pool.admit(
        job.id,
        Arc::new(decoded.pcm),
        pieces.clone(),
        elapsed,
        params
            .deadline_s
            .or(caller.deadline_s)
            .unwrap_or(scribe::DEFAULT_DEADLINE_S),
    ) {
        Ok(class) => {
            record.class = match class {
                Class::Interactive => "interactive",
                Class::Batch => "batch",
            }
        }
        Err(refused) => return fail(input, id, &refusal(refused), record),
    }
    let recognized = match pool.wait(job.id, &|| conn.hung_up()) {
        Some(Ok(recognized)) => recognized,
        Some(Err(JobError::Engine(message))) => {
            (shared.config.log)(&format!("{id} engine failed: {message}"));
            return fail(input, id, &ApiError::internal(), record);
        }
        Some(Err(JobError::ShuttingDown)) => {
            return fail(input, id, &ApiError::shutting_down(), record)
        }
        None => {
            record.code = "client_left";
            return;
        }
    };
    drop(job);

    let recognized: Vec<Recognized> = if params.no_verbatim {
        recognized.iter().map(verbatim::clean).collect()
    } else {
        recognized
    };
    let body = match params.format {
        Format::Scribe => scribe::response(
            &scribe::timed_words(&pieces, &recognized),
            params.granularity,
            id,
        ),
        Format::OpenRamble => output::json(
            &shared.config.model,
            record.audio_s,
            started.elapsed().as_secs_f64(),
            &output::segments(&planned, &[None], &recognized),
        ),
    };
    record.status = 200;
    let _ = respond(input.get_mut(), 200, id, &body, None);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn digest(key: &str) -> String {
        Sha256::digest(key.as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }

    #[test]
    fn keys_are_checked_by_digest_and_named_by_label() {
        let text = format!(
            "# callers\n\nmeetings {}\nopenstrudel   {}\n",
            digest("meet-secret"),
            digest("strudel-secret")
        );
        let keys = Keys::parse(&text).unwrap();
        let label = |key: &str| keys.check(key).map(|caller| caller.label.clone());
        assert_eq!(label("meet-secret").as_deref(), Some("meetings"));
        assert_eq!(label(" strudel-secret ").as_deref(), Some("openstrudel"));
        assert_eq!(label("meet-secret2"), None);
        assert_eq!(label(""), None);
        assert_eq!(
            label(&digest("meet-secret")),
            None,
            "the digest is not the key"
        );
    }

    #[test]
    fn a_key_can_say_how_long_its_caller_waits() {
        let text = format!(
            "meetings {}\nopenstrudel {} 170\n",
            digest("meet-secret"),
            digest("strudel-secret")
        );
        let keys = Keys::parse(&text).unwrap();
        assert_eq!(keys.check("meet-secret").unwrap().deadline_s, None);
        assert_eq!(
            keys.check("strudel-secret").unwrap().deadline_s,
            Some(170.0)
        );
        for bad in ["0", "86401", "soon", "NaN", "170 extra"] {
            let error = Keys::parse(&format!("a {} {bad}\n", digest("x"))).unwrap_err();
            assert!(error.contains("line 1"), "{error}");
        }
    }

    #[test]
    fn a_bad_keys_file_is_refused_without_quoting_it() {
        for (text, line) in [
            ("meetings\n", "line 1"),
            ("ok 00\n", "line 1"),
            (
                &format!("a {}\nb nothex{}\n", digest("x"), "z".repeat(56)),
                "line 2",
            ),
            (&format!("a {} extra\n", digest("x")), "line 1"),
        ] {
            let error = Keys::parse(text).unwrap_err();
            assert!(error.contains(line), "{error}");
            assert!(
                !error.contains("nothex") && !error.contains("meetings"),
                "{error}"
            );
        }
        assert!(Keys::parse("# nothing\n").is_err());
    }

    #[test]
    fn request_ids_are_distinct_and_prefixed() {
        let ids: std::collections::HashSet<String> = (0..1000).map(|_| request_id()).collect();
        assert_eq!(ids.len(), 1000);
        assert!(ids.iter().all(|id| id.starts_with("or_") && id.len() == 35));
    }
}

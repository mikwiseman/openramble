//! The engines: one thread and one loaded model each, all fed by the scheduler.
//!
//! A loaded model runs one piece at a time, so parallelism is several models,
//! each on one thread (measured on the target: four one-thread engines beat
//! two two-thread ones and one four-thread one). Engines take pieces from the
//! scheduler under one lock and read the piece's samples from the job's
//! decoded file themselves.
//!
//! Crash-only: if an engine thread panics, the process aborts and systemd
//! starts a fresh one, rather than carrying on with an engine in an unknown
//! state. Stopping joins every engine thread, and each drops its model first,
//! because ggml aborts if a model is still alive at exit.

use std::fs::File;
use std::ops::Range;
use std::os::unix::fs::FileExt;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use ramble_engine::{Engine, EngineError, Recognized};

use crate::schedule::{Class, JobError, JobId, Refusal, Scheduler};

/// Something that turns 16 kHz samples into words: the engine, or a fake.
pub trait Recognize: Send {
    fn recognize(&self, samples: &[f32]) -> Result<Recognized, EngineError>;
    /// Drop the model; called once, on the engine's own thread.
    fn shutdown(self: Box<Self>);
}

impl Recognize for Engine {
    fn recognize(&self, samples: &[f32]) -> Result<Recognized, EngineError> {
        Engine::recognize(self, samples)
    }

    fn shutdown(self: Box<Self>) {
        Engine::shutdown(*self);
    }
}

/// Load `count` engines side by side. If any fails, the ones that loaded are
/// dropped properly and the first failure is returned.
pub fn load(
    model_directory: &std::path::Path,
    count: usize,
) -> Result<Vec<Box<dyn Recognize>>, String> {
    let loaded: Vec<Result<Engine, EngineError>> = std::thread::scope(|scope| {
        let loading: Vec<_> = (0..count)
            .map(|_| scope.spawn(|| Engine::load(model_directory)))
            .collect();
        loading
            .into_iter()
            .map(|handle| {
                handle
                    .join()
                    .unwrap_or_else(|_| Err(EngineError::Load("loading panicked".into())))
            })
            .collect()
    });
    let mut engines: Vec<Box<dyn Recognize>> = Vec::new();
    let mut failure = None;
    for result in loaded {
        match result {
            Ok(engine) => engines.push(Box::new(engine)),
            Err(error) => {
                failure.get_or_insert(error.to_string());
            }
        }
    }
    match failure {
        None => Ok(engines),
        Some(error) => {
            for engine in engines {
                engine.shutdown();
            }
            Err(error)
        }
    }
}

/// A job's decoded audio, shared by the engines working on it.
pub type Pcm = Arc<File>;

/// How often a waiting request looks at its connection.
const WATCH: Duration = Duration::from_millis(250);
/// Words per second above which a piece is probably the model looping.
const LOOPING_WPS: f64 = 6.0;

struct State {
    scheduler: Scheduler<Pcm>,
    stopping: bool,
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// What `/health` reports.
#[derive(Debug, Clone, PartialEq)]
pub struct Health {
    pub engines: usize,
    pub jobs: usize,
    pub queued_seconds: f64,
    pub draining: bool,
}

pub struct Pool {
    shared: Arc<Shared>,
    workers: Vec<JoinHandle<()>>,
}

impl Pool {
    pub fn start(recognizers: Vec<Box<dyn Recognize>>) -> Pool {
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                scheduler: Scheduler::new(recognizers.len()),
                stopping: false,
            }),
            changed: Condvar::new(),
        });
        let workers = recognizers
            .into_iter()
            .enumerate()
            .map(|(index, recognizer)| {
                let shared = shared.clone();
                std::thread::Builder::new()
                    .name(format!("engine-{index}"))
                    .spawn(move || {
                        let worked = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            work(&shared, recognizer)
                        }));
                        if worked.is_err() {
                            eprintln!("an engine thread panicked; stopping the process");
                            std::process::abort();
                        }
                    })
                    .expect("spawn an engine thread")
            })
            .collect();
        Pool { shared, workers }
    }

    /// Start a job when its request arrives.
    pub fn open(&self) -> Result<JobId, Refusal> {
        self.shared.lock().scheduler.open()
    }

    /// Queue a decoded job, if its budget can be kept.
    pub fn admit(
        &self,
        job: JobId,
        pcm: Pcm,
        pieces: Vec<Range<u64>>,
        elapsed_s: f64,
        budget_s: f64,
    ) -> Result<Class, Refusal> {
        let admitted = self
            .shared
            .lock()
            .scheduler
            .admit(job, pcm, pieces, elapsed_s, budget_s);
        self.shared.changed.notify_all();
        admitted
    }

    /// Wait for an admitted job's pieces, in file order. `None` when
    /// `hung_up()` turned true first; the job's queued pieces are dropped then.
    pub fn wait(
        &self,
        job: JobId,
        hung_up: &dyn Fn() -> bool,
    ) -> Option<Result<Vec<Recognized>, JobError>> {
        loop {
            {
                let state = self.shared.lock();
                if let Some(outcome) = state.scheduler.outcome(job) {
                    return Some(outcome);
                }
                let (state, _) = self
                    .shared
                    .changed
                    .wait_timeout(state, WATCH)
                    .unwrap_or_else(PoisonError::into_inner);
                if let Some(outcome) = state.scheduler.outcome(job) {
                    return Some(outcome);
                }
            }
            if hung_up() {
                self.close(job);
                return None;
            }
        }
    }

    /// The request is over, however it ended.
    pub fn close(&self, job: JobId) {
        self.shared.lock().scheduler.close(job);
        self.shared.changed.notify_all();
    }

    pub fn health(&self) -> Health {
        let state = self.shared.lock();
        Health {
            engines: state.scheduler.engines(),
            jobs: state.scheduler.open_jobs(),
            queued_seconds: state.scheduler.queued_seconds(),
            draining: state.scheduler.draining(),
        }
    }

    /// Refuse new jobs and let the open ones finish.
    pub fn drain(&self) {
        self.shared.lock().scheduler.drain();
    }

    /// End every open job with `ShuttingDown`.
    pub fn abort_all(&self) {
        self.shared.lock().scheduler.abort_all();
        self.shared.changed.notify_all();
    }

    /// Stop every engine thread once its current piece is done, and drop
    /// every model.
    pub fn stop(self) {
        self.shared.lock().stopping = true;
        self.shared.changed.notify_all();
        for worker in self.workers {
            // a panicking engine aborts the process, so a join error cannot
            // happen; there is nothing more to do if it somehow did
            let _ = worker.join();
        }
    }
}

fn work(shared: &Shared, recognizer: Box<dyn Recognize>) {
    loop {
        let task = {
            let mut state = shared.lock();
            loop {
                if state.stopping {
                    break None;
                }
                if let Some(task) = state.scheduler.next_task() {
                    break Some(task);
                }
                state = shared
                    .changed
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
            }
        };
        let Some(task) = task else { break };
        let started = Instant::now();
        let outcome = read_piece(&task.source, &task.range)
            .map_err(|error| format!("reading the decoded audio failed: {error}"))
            .and_then(|samples| {
                recognizer
                    .recognize(&samples)
                    .map_err(|error| error.to_string())
            });
        let compute_s = started.elapsed().as_secs_f64();
        if let Ok(recognized) = &outcome {
            note_oddities(recognized, &task.range);
        }
        shared.lock().scheduler.complete(&task, outcome, compute_s);
        shared.changed.notify_all();
    }
    recognizer.shutdown();
}

/// Counts only, never words.
fn note_oddities(recognized: &Recognized, range: &Range<u64>) {
    let seconds = (range.end - range.start) as f64 / 16_000.0;
    let rate = recognized.words.len() as f64 / seconds.max(0.001);
    if rate > LOOPING_WPS {
        eprintln!(
            "piece of {seconds:.1} s came back with {} words ({rate:.1} per second): possible loop",
            recognized.words.len()
        );
    }
    if recognized.truncated {
        eprintln!("piece of {seconds:.1} s hit the output budget and was truncated");
    }
}

fn read_piece(pcm: &File, range: &Range<u64>) -> std::io::Result<Vec<f32>> {
    let mut bytes = vec![0u8; ((range.end - range.start) * 4) as usize];
    pcm.read_exact_at(&mut bytes, range.start * 4)?;
    Ok(bytes
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Answers with the piece's length in samples, after `delay`.
    struct Fake {
        delay: Duration,
        active: Arc<AtomicUsize>,
        most: Arc<AtomicUsize>,
        log: Arc<Mutex<Vec<usize>>>,
        shut: Arc<AtomicUsize>,
        fail_on: Option<usize>,
    }

    #[derive(Default, Clone)]
    struct Probe {
        active: Arc<AtomicUsize>,
        most: Arc<AtomicUsize>,
        log: Arc<Mutex<Vec<usize>>>,
        shut: Arc<AtomicUsize>,
    }

    impl Probe {
        fn fakes(&self, count: usize, delay: Duration) -> Vec<Box<dyn Recognize>> {
            self.fakes_failing(count, delay, None)
        }

        fn fakes_failing(
            &self,
            count: usize,
            delay: Duration,
            fail_on: Option<usize>,
        ) -> Vec<Box<dyn Recognize>> {
            (0..count)
                .map(|_| {
                    Box::new(Fake {
                        delay,
                        active: self.active.clone(),
                        most: self.most.clone(),
                        log: self.log.clone(),
                        shut: self.shut.clone(),
                        fail_on,
                    }) as Box<dyn Recognize>
                })
                .collect()
        }
    }

    impl Recognize for Fake {
        fn recognize(&self, samples: &[f32]) -> Result<Recognized, EngineError> {
            let now = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.most.fetch_max(now, Ordering::SeqCst);
            self.log.lock().unwrap().push(samples.len());
            std::thread::sleep(self.delay);
            self.active.fetch_sub(1, Ordering::SeqCst);
            if self.fail_on == Some(samples.len()) {
                return Err(EngineError::Run("fake failure".into()));
            }
            Ok(Recognized {
                text: samples.len().to_string(),
                ..Default::default()
            })
        }

        fn shutdown(self: Box<Self>) {
            self.shut.fetch_add(1, Ordering::SeqCst);
        }
    }

    /// A sparse file of `seconds` of silence.
    fn pcm(seconds: u64) -> Pcm {
        let mut file = tempfile::tempfile().unwrap();
        file.set_len(seconds * 16_000 * 4).unwrap();
        file.flush().unwrap();
        Arc::new(file)
    }

    fn pieces(count: u64, samples: u64) -> Vec<Range<u64>> {
        (0..count).map(|i| i * samples..(i + 1) * samples).collect()
    }

    fn texts(outcome: Option<Result<Vec<Recognized>, JobError>>) -> Vec<String> {
        outcome
            .unwrap()
            .unwrap()
            .into_iter()
            .map(|r| r.text)
            .collect()
    }

    #[test]
    fn a_job_runs_on_every_engine_and_comes_back_in_file_order() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes(3, Duration::from_millis(40)));
        let job = pool.open().unwrap();
        let list: Vec<Range<u64>> = (1..=6).map(|i| i * 1000..i * 1000 + i * 10).collect();
        pool.admit(job, pcm(1), list, 0.0, 600.0).unwrap();
        assert_eq!(
            texts(pool.wait(job, &|| false)),
            ["10", "20", "30", "40", "50", "60"]
        );
        assert_eq!(
            probe.most.load(Ordering::SeqCst),
            3,
            "one job uses every engine"
        );
        pool.close(job);
        pool.stop();
    }

    #[test]
    fn a_voice_note_behind_a_long_track_starts_within_one_piece() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes(1, Duration::from_millis(20)));
        let track = pool.open().unwrap();
        // 40 pieces of 16 s: batch
        pool.admit(track, pcm(640), pieces(40, 16 * 16_000), 0.0, 1e9)
            .unwrap();
        while probe.log.lock().unwrap().is_empty() {
            std::thread::yield_now();
        }
        let note = pool.open().unwrap();
        // 3 pieces of 10 s: interactive
        pool.admit(note, pcm(30), pieces(3, 10 * 16_000), 0.0, 180.0)
            .unwrap();
        assert_eq!(texts(pool.wait(note, &|| false)).len(), 3);
        let log = probe.log.lock().unwrap().clone();
        let first_note = log.iter().position(|&n| n == 160_000).unwrap();
        assert!(
            first_note <= 2,
            "the note waited behind {first_note} pieces: {log:?}"
        );
        drop(log);
        pool.close(note);
        pool.close(track);
        pool.stop();
    }

    #[test]
    fn a_hang_up_cancels_the_rest_of_the_job() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes(1, Duration::from_millis(30)));
        let job = pool.open().unwrap();
        pool.admit(job, pcm(100), pieces(50, 16_000), 0.0, 600.0)
            .unwrap();
        let started = Instant::now();
        assert_eq!(pool.wait(job, &|| started.elapsed() > WATCH), None);
        let ran = probe.log.lock().unwrap().len();
        std::thread::sleep(Duration::from_millis(200));
        // at most the piece that was running when the hang-up was seen
        assert!(probe.log.lock().unwrap().len() <= ran + 1);
        assert_eq!(pool.health().jobs, 0);
        assert_eq!(pool.health().queued_seconds, 0.0);
        pool.stop();
    }

    #[test]
    fn an_engine_failure_fails_only_its_own_job() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes_failing(1, Duration::ZERO, Some(777)));
        let broken = pool.open().unwrap();
        let fine = pool.open().unwrap();
        pool.admit(
            broken,
            pcm(1),
            vec![0..100, 100..877, 900..1000],
            0.0,
            600.0,
        )
        .unwrap();
        pool.admit(fine, pcm(1), pieces(1, 5), 0.0, 600.0).unwrap();
        assert_eq!(
            pool.wait(broken, &|| false),
            Some(Err(JobError::Engine(
                "the recognition failed: fake failure".into()
            )))
        );
        assert_eq!(texts(pool.wait(fine, &|| false)), ["5"]);
        pool.close(broken);
        pool.close(fine);
        pool.stop();
    }

    #[test]
    fn health_counts_open_jobs_and_queued_audio() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes(2, Duration::from_millis(50)));
        let uploading = pool.open().unwrap();
        let queued = pool.open().unwrap();
        pool.admit(queued, pcm(40), pieces(4, 10 * 16_000), 0.0, 600.0)
            .unwrap();
        let health = pool.health();
        assert_eq!(health.engines, 2);
        assert_eq!(health.jobs, 2);
        assert_eq!(health.queued_seconds, 40.0);
        assert!(!health.draining);
        pool.wait(queued, &|| false).unwrap().unwrap();
        pool.close(queued);
        pool.drain();
        let health = pool.health();
        assert_eq!(
            (health.jobs, health.queued_seconds, health.draining),
            (1, 0.0, true)
        );
        pool.close(uploading);
        pool.stop();
    }

    #[test]
    fn stopping_wakes_idle_engines_and_drops_every_model() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes(4, Duration::ZERO));
        std::thread::sleep(Duration::from_millis(20));
        pool.stop();
        assert_eq!(probe.shut.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn aborting_ends_waiting_jobs_with_shutting_down() {
        let probe = Probe::default();
        let pool = Pool::start(probe.fakes(1, Duration::from_millis(20)));
        let job = pool.open().unwrap();
        pool.admit(job, pcm(100), pieces(50, 16_000), 0.0, 600.0)
            .unwrap();
        let shared = pool.shared.clone();
        let aborter = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(60));
            shared.lock().scheduler.abort_all();
            shared.changed.notify_all();
        });
        assert_eq!(pool.wait(job, &|| false), Some(Err(JobError::ShuttingDown)));
        aborter.join().unwrap();
        pool.close(job);
        pool.stop();
    }
}

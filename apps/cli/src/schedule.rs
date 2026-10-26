//! Which piece the next free engine takes, and whether a job can be promised.
//!
//! Pure: no threads, no clock, no files. The pool calls it under one lock and
//! passes in the measured times.
//!
//! - **Two classes, by how long the caller waits.** A job whose caller waits
//!   at most 10 minutes in all is interactive (a voice note); any other is
//!   batch (a meeting track). How much speech a job has says nothing about
//!   who is waiting: a quiet participant's track has little, a long voice
//!   note has a lot. Interactive pieces go first at every piece boundary, so
//!   a voice note never waits behind a nine-hour track for more than the
//!   piece already running. Within a class jobs go in the order they were
//!   admitted, and a job's pieces in file order. Every engine takes whatever
//!   is next, so one job alone uses all of them.
//! - **Admission is a promise.** A job is admitted only when the work ahead
//!   of it in its own class plus its own fits its caller's budget at the
//!   measured speed (batch work is not ahead of an interactive job).
//!   Otherwise it gets 429 with the time the queue needs, which callers
//!   retry, rather than a timeout, which they do not.
//! - **Cancel drops queued pieces.** A piece already running finishes (the
//!   runtime cannot stop mid-piece) and its result is thrown away.

use std::collections::{HashMap, VecDeque};
use std::ops::Range;

use ramble_engine::Recognized;

pub type JobId = u64;

/// A job whose caller waits at most this many seconds in all is interactive.
pub const INTERACTIVE_BUDGET_S: f64 = 600.0;
/// Most jobs open at once, uploads and decodes included.
pub const MAX_JOBS: usize = 8;
/// Compute seconds per audio second before anything has been measured: what
/// one Neoverse-N1 engine took on the 20.8-minute track.
pub const SEED_COST: f64 = 0.45;
const ALPHA: f64 = 0.1;
/// Headroom on every estimate.
const MARGIN: f64 = 1.15;
const RATE: f64 = 16_000.0;
/// The least Retry-After a busy server asks for.
const MIN_RETRY_S: u64 = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Class {
    Interactive,
    Batch,
}

/// Why a job is not taken.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// 429: come back after this many seconds.
    Busy { retry_after_s: u64 },
    /// 429: the server is stopping.
    ShuttingDown,
    /// 422: even an empty queue could not finish it within its budget.
    TooLongForDeadline,
}

/// Why an admitted job ended without its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JobError {
    /// The engine failed on one of its pieces.
    Engine(String),
    /// The server stopped before the job could finish.
    ShuttingDown,
}

/// One piece for one engine.
#[derive(Debug, Clone, PartialEq)]
pub struct Task<S> {
    pub job: JobId,
    pub index: usize,
    /// In samples of the job's audio.
    pub range: Range<u64>,
    pub source: S,
}

struct Job<S> {
    source: Option<S>,
    pieces: Vec<Range<u64>>,
    queued: VecDeque<usize>,
    running: usize,
    /// Seconds of audio queued or running.
    remaining_s: f64,
    results: Vec<Option<Recognized>>,
    failure: Option<JobError>,
    admitted: bool,
}

pub struct Scheduler<S> {
    engines: usize,
    cost: f64,
    next_id: JobId,
    jobs: HashMap<JobId, Job<S>>,
    interactive: VecDeque<JobId>,
    batch: VecDeque<JobId>,
    draining: bool,
}

fn seconds(range: &Range<u64>) -> f64 {
    (range.end - range.start) as f64 / RATE
}

impl<S: Clone> Scheduler<S> {
    pub fn new(engines: usize) -> Self {
        Scheduler {
            engines: engines.max(1),
            cost: SEED_COST,
            next_id: 1,
            jobs: HashMap::new(),
            interactive: VecDeque::new(),
            batch: VecDeque::new(),
            draining: false,
        }
    }

    /// Start a job as its request arrives, before its upload.
    pub fn open(&mut self) -> Result<JobId, Refusal> {
        if self.draining {
            return Err(Refusal::ShuttingDown);
        }
        if self.jobs.len() >= MAX_JOBS {
            return Err(Refusal::Busy {
                retry_after_s: self.wait_s(self.queued_seconds()),
            });
        }
        let id = self.next_id;
        self.next_id += 1;
        self.jobs.insert(
            id,
            Job {
                source: None,
                pieces: Vec::new(),
                queued: VecDeque::new(),
                running: 0,
                remaining_s: 0.0,
                results: Vec::new(),
                failure: None,
                admitted: false,
            },
        );
        Ok(id)
    }

    /// Queue a decoded job's pieces, if its budget can be kept.
    ///
    /// `elapsed_s` is what the request has already spent (upload and decode);
    /// `budget_s` is how long its caller waits in all.
    pub fn admit(
        &mut self,
        id: JobId,
        source: S,
        pieces: Vec<Range<u64>>,
        elapsed_s: f64,
        budget_s: f64,
    ) -> Result<Class, Refusal> {
        if self.jobs.get(&id).is_none_or(|job| job.failure.is_some()) {
            return Err(Refusal::ShuttingDown);
        }
        let mine: f64 = pieces.iter().map(seconds).sum();
        let class = if budget_s <= INTERACTIVE_BUDGET_S {
            Class::Interactive
        } else {
            Class::Batch
        };
        let queue = match class {
            Class::Interactive => &self.interactive,
            Class::Batch => &self.batch,
        };
        let ahead: f64 = queue
            .iter()
            .filter_map(|id| self.jobs.get(id))
            .map(|job| job.remaining_s)
            .sum();
        if elapsed_s + self.estimate_s(mine) > budget_s {
            return Err(Refusal::TooLongForDeadline);
        }
        if elapsed_s + self.estimate_s(ahead + mine) > budget_s {
            return Err(Refusal::Busy {
                retry_after_s: self.wait_s(ahead),
            });
        }
        let job = self.jobs.get_mut(&id).expect("checked above");
        job.queued = (0..pieces.len()).collect();
        job.results = vec![None; pieces.len()];
        job.remaining_s = mine;
        job.pieces = pieces;
        job.source = Some(source);
        job.admitted = true;
        if !job.queued.is_empty() {
            match class {
                Class::Interactive => self.interactive.push_back(id),
                Class::Batch => self.batch.push_back(id),
            }
        }
        Ok(class)
    }

    /// The next piece for a free engine.
    pub fn next_task(&mut self) -> Option<Task<S>> {
        for queue in [&mut self.interactive, &mut self.batch] {
            while let Some(&id) = queue.front() {
                let Some(job) = self.jobs.get_mut(&id) else {
                    queue.pop_front();
                    continue;
                };
                let Some(index) = job.queued.pop_front() else {
                    queue.pop_front();
                    continue;
                };
                if job.queued.is_empty() {
                    queue.pop_front();
                }
                job.running += 1;
                return Some(Task {
                    job: id,
                    index,
                    range: job.pieces[index].clone(),
                    source: job.source.clone().expect("admitted jobs have a source"),
                });
            }
        }
        None
    }

    /// An engine finished a piece in `compute_s` seconds.
    pub fn complete(
        &mut self,
        task: &Task<S>,
        outcome: Result<Recognized, String>,
        compute_s: f64,
    ) {
        let audio_s = seconds(&task.range);
        let Some(job) = self.jobs.get_mut(&task.job) else {
            // cancelled and closed while the piece ran: nobody wants it
            return;
        };
        job.running -= 1;
        job.remaining_s = (job.remaining_s - audio_s).max(0.0);
        if job.failure.is_some() {
            return;
        }
        match outcome {
            Ok(recognized) => {
                job.results[task.index] = Some(recognized);
                if audio_s > 0.0 {
                    self.cost = (1.0 - ALPHA) * self.cost + ALPHA * compute_s / audio_s;
                }
            }
            Err(message) => self.fail(task.job, JobError::Engine(message)),
        }
    }

    fn fail(&mut self, id: JobId, error: JobError) {
        if let Some(job) = self.jobs.get_mut(&id) {
            let dropped: f64 = job.queued.iter().map(|&i| seconds(&job.pieces[i])).sum();
            job.remaining_s = (job.remaining_s - dropped).max(0.0);
            job.queued.clear();
            job.failure.get_or_insert(error);
        }
    }

    /// The job's outcome once nothing of it is queued or running; results in
    /// file order.
    pub fn outcome(&self, id: JobId) -> Option<Result<Vec<Recognized>, JobError>> {
        let job = self.jobs.get(&id)?;
        if let Some(failure) = &job.failure {
            return Some(Err(failure.clone()));
        }
        if !job.admitted || !job.queued.is_empty() || job.running > 0 {
            return None;
        }
        Some(Ok(job.results.iter().flatten().cloned().collect()))
    }

    /// The request is over, however it ended: forget the job and drop its
    /// queued pieces. A piece still running finishes and is discarded.
    pub fn close(&mut self, id: JobId) {
        self.jobs.remove(&id);
    }

    /// Refuse new jobs; the open ones carry on.
    pub fn drain(&mut self) {
        self.draining = true;
    }

    pub fn draining(&self) -> bool {
        self.draining
    }

    /// End every open job with `ShuttingDown`.
    pub fn abort_all(&mut self) {
        let ids: Vec<JobId> = self.jobs.keys().copied().collect();
        for id in ids {
            self.fail(id, JobError::ShuttingDown);
        }
    }

    pub fn open_jobs(&self) -> usize {
        self.jobs.len()
    }

    /// Seconds of audio queued or running.
    pub fn queued_seconds(&self) -> f64 {
        // folded from +0.0: an empty f64 sum is -0.0, which /health would print
        self.jobs
            .values()
            .fold(0.0, |total, job| total + job.remaining_s)
    }

    pub fn cost(&self) -> f64 {
        self.cost
    }

    pub fn engines(&self) -> usize {
        self.engines
    }

    /// Wall seconds the engines need for this much audio.
    fn estimate_s(&self, audio_s: f64) -> f64 {
        MARGIN * audio_s * self.cost / self.engines as f64
    }

    fn wait_s(&self, audio_s: f64) -> u64 {
        (self.estimate_s(audio_s).ceil() as u64).max(MIN_RETRY_S)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: u64 = 16_000;

    /// `count` pieces of `each_s` seconds, back to back.
    fn pieces(count: u64, each_s: u64) -> Vec<Range<u64>> {
        (0..count)
            .map(|i| i * each_s * S..(i + 1) * each_s * S)
            .collect()
    }

    fn words(text: &str) -> Recognized {
        Recognized {
            text: text.into(),
            ..Default::default()
        }
    }

    fn admitted(scheduler: &mut Scheduler<char>, tag: char, list: Vec<Range<u64>>) -> JobId {
        let id = scheduler.open().unwrap();
        scheduler.admit(id, tag, list, 0.0, f64::INFINITY).unwrap();
        id
    }

    fn drain_order(scheduler: &mut Scheduler<char>) -> String {
        let mut order = String::new();
        while let Some(task) = scheduler.next_task() {
            order.push(task.source);
            scheduler.complete(&task, Ok(words("x")), 0.0);
        }
        order
    }

    #[test]
    fn interactive_pieces_go_before_queued_batch_pieces() {
        let mut scheduler = Scheduler::new(2);
        admitted(&mut scheduler, 'B', pieces(40, 16)); // a caller who waits hours
        let first = scheduler.next_task().unwrap();
        assert_eq!(first.source, 'B');
        let note = scheduler.open().unwrap();
        // a caller who waits three minutes
        scheduler
            .admit(note, 'i', pieces(3, 10), 0.0, 180.0)
            .unwrap();
        // the very next free engine takes the voice note
        assert_eq!(
            drain_order(&mut scheduler),
            format!("iii{}", "B".repeat(39))
        );
    }

    #[test]
    fn batch_jobs_run_in_admission_order_and_pieces_in_file_order() {
        let mut scheduler = Scheduler::new(1);
        let first_open = scheduler.open().unwrap();
        let second_open = scheduler.open().unwrap();
        // the second request finished its upload first, so it is admitted first
        scheduler
            .admit(second_open, 'b', pieces(40, 16), 0.0, f64::INFINITY)
            .unwrap();
        scheduler
            .admit(first_open, 'a', pieces(40, 16), 0.0, f64::INFINITY)
            .unwrap();
        let mut indices = Vec::new();
        let mut order = String::new();
        while let Some(task) = scheduler.next_task() {
            order.push(task.source);
            if task.source == 'b' {
                indices.push(task.index);
            }
            scheduler.complete(&task, Ok(words("x")), 0.0);
        }
        assert_eq!(order, format!("{}{}", "b".repeat(40), "a".repeat(40)));
        assert_eq!(indices, (0..40).collect::<Vec<_>>());
    }

    #[test]
    fn one_job_alone_feeds_every_engine() {
        let mut scheduler = Scheduler::new(4);
        admitted(&mut scheduler, 'a', pieces(6, 15));
        let running: Vec<_> = (0..4).map_while(|_| scheduler.next_task()).collect();
        assert_eq!(running.len(), 4);
        assert!(running.iter().all(|task| task.source == 'a'));
    }

    #[test]
    fn a_cancelled_job_loses_only_its_own_pieces_and_its_running_result() {
        let mut scheduler = Scheduler::new(1);
        let keep = admitted(&mut scheduler, 'k', pieces(2, 10));
        let gone = admitted(&mut scheduler, 'g', pieces(3, 10));
        let task = scheduler.next_task().unwrap();
        assert_eq!(task.source, 'k');
        let running = scheduler.next_task().unwrap();
        assert_eq!(running.source, 'k');
        let gone_running = {
            scheduler.complete(&task, Ok(words("one")), 1.0);
            scheduler.complete(&running, Ok(words("two")), 1.0);
            scheduler.next_task().unwrap()
        };
        assert_eq!(gone_running.job, gone);
        scheduler.close(gone);
        // its finished piece has nowhere to go and breaks nothing
        scheduler.complete(&gone_running, Ok(words("late")), 1.0);
        assert!(scheduler.next_task().is_none());
        let texts: Vec<String> = scheduler
            .outcome(keep)
            .unwrap()
            .unwrap()
            .into_iter()
            .map(|r| r.text)
            .collect();
        assert_eq!(texts, ["one", "two"]);
        assert_eq!(scheduler.queued_seconds(), 0.0);
    }

    #[test]
    fn an_engine_failure_fails_only_its_own_job() {
        let mut scheduler = Scheduler::new(1);
        let broken = admitted(&mut scheduler, 'x', pieces(3, 10));
        let fine = admitted(&mut scheduler, 'f', pieces(1, 10));
        let task = scheduler.next_task().unwrap();
        scheduler.complete(&task, Err("the recognition failed".into()), 1.0);
        assert_eq!(
            scheduler.outcome(broken),
            Some(Err(JobError::Engine("the recognition failed".into())))
        );
        // the broken job's other pieces are not run
        assert_eq!(drain_order(&mut scheduler), "f");
        assert_eq!(scheduler.outcome(fine).unwrap().unwrap().len(), 1);
    }

    #[test]
    fn a_batch_job_is_promised_only_what_the_queue_can_keep() {
        let mut scheduler = Scheduler::new(4);
        // 4000 s ahead at 0.45 compute s per audio s on 4 engines:
        // 1.15 * 4000 * 0.45 / 4 = 517.5 s of waiting
        let ahead = admitted(&mut scheduler, 'a', pieces(250, 16));
        let mine = pieces(100, 16); // 1600 s: 1.15 * 1600 * 0.45 / 4 = 207 s
        let id = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(id, 'm', mine.clone(), 10.0, 700.0),
            Err(Refusal::Busy { retry_after_s: 518 })
        );
        // the same job fits a caller who waits longer
        assert_eq!(
            scheduler.admit(id, 'm', mine.clone(), 10.0, 800.0),
            Ok(Class::Batch)
        );
        scheduler.close(id);

        // a job that could not finish even on an empty server is told so
        let id = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(id, 'm', pieces(400, 16), 10.0, 700.0),
            Err(Refusal::TooLongForDeadline)
        );
        // once the queue has drained the same request is accepted
        scheduler.close(ahead);
        assert_eq!(
            scheduler.admit(id, 'm', mine, 10.0, 700.0),
            Ok(Class::Batch)
        );
        // the meeting work queued is not ahead of a voice note
        let note = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(note, 'n', pieces(4, 15), 590.0, 600.0),
            Ok(Class::Interactive)
        );
    }

    /// `count` pieces of `each_ms` milliseconds, back to back.
    fn pieces_ms(count: u64, each_ms: u64) -> Vec<Range<u64>> {
        (0..count)
            .map(|i| i * each_ms * 16..(i + 1) * each_ms * 16)
            .collect()
    }

    #[test]
    fn a_meeting_track_with_little_speech_does_not_hold_up_a_voice_note() {
        // A 9.2-hour track from a participant who spoke 9.5 minutes: 36
        // pieces of 15.8 s, under 600 s of speech, from a caller who waits
        // four hours.
        let mut scheduler = Scheduler::new(4);
        let track = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(track, 'T', pieces_ms(36, 15_800), 0.0, 14_400.0),
            Ok(Class::Batch)
        );
        for _ in 0..4 {
            assert_eq!(scheduler.next_task().unwrap().source, 'T');
        }
        // a 30 s voice note from a caller who waits 170 s
        let note = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(note, 'n', pieces(2, 15), 1.0, 170.0),
            Ok(Class::Interactive)
        );
        assert_eq!(scheduler.next_task().unwrap().source, 'n');
        assert_eq!(scheduler.next_task().unwrap().source, 'n');
    }

    #[test]
    fn a_long_voice_note_still_goes_first_when_its_caller_waits_briefly() {
        let mut scheduler = Scheduler::new(4);
        let track = scheduler.open().unwrap();
        scheduler
            .admit(track, 'T', pieces(100, 16), 0.0, 14_400.0)
            .unwrap();
        scheduler.next_task().unwrap();
        // 11 minutes of speech: 1.15 * 660 * 0.45 / 4 = 85 s, within 170 s
        let note = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(note, 'n', pieces(44, 15), 1.0, 170.0),
            Ok(Class::Interactive)
        );
        assert_eq!(scheduler.next_task().unwrap().source, 'n');
    }

    #[test]
    fn a_voice_note_is_promised_only_what_the_notes_ahead_of_it_leave() {
        let mut scheduler = Scheduler::new(4);
        // a meeting track ahead does not count: notes go before its pieces
        let track = scheduler.open().unwrap();
        scheduler
            .admit(track, 'T', pieces(250, 16), 0.0, 14_400.0)
            .unwrap();
        // a 4-minute note: 1.15 * 240 * 0.45 / 4 = 31 s
        let first = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(first, 'a', pieces(16, 15), 0.0, 60.0),
            Ok(Class::Interactive)
        );
        // the second would finish after 62 s, past its caller's 60
        let second = scheduler.open().unwrap();
        assert_eq!(
            scheduler.admit(second, 'b', pieces(16, 15), 0.0, 60.0),
            Err(Refusal::Busy { retry_after_s: 32 })
        );
        // and one that could not finish even alone is told so
        assert_eq!(
            scheduler.admit(second, 'b', pieces(160, 15), 0.0, 60.0),
            Err(Refusal::TooLongForDeadline)
        );
    }

    #[test]
    fn the_measured_speed_is_a_running_average() {
        let mut scheduler = Scheduler::new(1);
        admitted(&mut scheduler, 'a', pieces(2, 10));
        assert_eq!(scheduler.cost(), SEED_COST);
        let task = scheduler.next_task().unwrap();
        scheduler.complete(&task, Ok(words("x")), 2.0);
        assert!((scheduler.cost() - (0.9 * 0.45 + 0.1 * 0.2)).abs() < 1e-12);
        // a failure measures nothing
        let task = scheduler.next_task().unwrap();
        let before = scheduler.cost();
        scheduler.complete(&task, Err("x".into()), 50.0);
        assert_eq!(scheduler.cost(), before);
    }

    #[test]
    fn results_come_back_in_file_order_whatever_order_they_finish() {
        let mut scheduler = Scheduler::new(3);
        let id = admitted(&mut scheduler, 'a', pieces(3, 10));
        let tasks: Vec<_> = (0..3).map_while(|_| scheduler.next_task()).collect();
        assert_eq!(scheduler.outcome(id), None);
        for (task, text) in tasks.iter().rev().zip(["c", "b", "a"]) {
            scheduler.complete(task, Ok(words(text)), 1.0);
        }
        let texts: Vec<String> = scheduler
            .outcome(id)
            .unwrap()
            .unwrap()
            .into_iter()
            .map(|r| r.text)
            .collect();
        assert_eq!(texts, ["a", "b", "c"]);
    }

    #[test]
    fn a_job_of_silence_is_done_without_an_engine() {
        let mut scheduler: Scheduler<char> = Scheduler::new(2);
        let id = admitted(&mut scheduler, 's', Vec::new());
        assert!(scheduler.next_task().is_none());
        assert_eq!(scheduler.outcome(id), Some(Ok(Vec::new())));
    }

    #[test]
    fn the_ninth_job_and_jobs_while_draining_are_refused() {
        let mut scheduler: Scheduler<char> = Scheduler::new(4);
        let ids: Vec<_> = (0..MAX_JOBS).map(|_| scheduler.open().unwrap()).collect();
        assert!(matches!(scheduler.open(), Err(Refusal::Busy { .. })));
        scheduler.close(ids[0]);
        let reopened = scheduler.open().unwrap();
        scheduler.drain();
        assert_eq!(scheduler.open(), Err(Refusal::ShuttingDown));
        // a job already open when the drain began still runs
        assert_eq!(
            scheduler.admit(reopened, 'a', pieces(1, 10), 0.0, 600.0),
            Ok(Class::Interactive)
        );
        // until the drain gives up on it
        scheduler.abort_all();
        assert_eq!(
            scheduler.outcome(reopened),
            Some(Err(JobError::ShuttingDown))
        );
        assert!(scheduler.next_task().is_none());
        assert_eq!(
            scheduler.admit(ids[1], 'b', pieces(1, 10), 0.0, 600.0),
            Err(Refusal::ShuttingDown)
        );
    }
}

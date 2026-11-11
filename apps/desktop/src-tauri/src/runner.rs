//! The dictation key, the take and the block, together.
//!
//! The gesture machine says what the key did; the dictation service runs the
//! take; the block says what is happening. This is where the three meet, and
//! it holds the one rule that belongs to none of them alone: what the key
//! means while words wait.
//!
//! Over waiting words a tap does what the block says, and the microphone
//! does not open for it. A hold is a new take: the waiting words are in
//! History already, and the new take is the news. Which of the two a press
//! is, its release decides, or `TAP_LIMIT` does. The same rule as the Mac's.

use crate::adapters::hotkey::Hotkey;
use crate::dictation::Dictation;
use crate::session::Outcome;
use crate::take::{Block, Mark, TakeBlock, TAP_LIMIT};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub struct Runner {
    dictation: Arc<Dictation>,
    block: Arc<TakeBlock>,
    hotkey: Hotkey,
    key: Mutex<Key>,
    /// Held by whoever is starting, finishing or dropping a take.
    ///
    /// A hold over waiting words starts its take from a timer, not from the
    /// key's own thread, so a release can arrive while the microphone is
    /// still opening. Finishing a take that has not started yet would find no
    /// microphone to stop, and the one that opened a moment later would stay
    /// live with nothing left to close it. One at a time rules that out.
    take: Mutex<()>,
}

/// Where the key is in its gesture.
#[derive(Default)]
struct Key {
    /// When the press that is still down happened.
    pressed_at: Option<Instant>,
    /// When the microphone opened for the take in progress.
    recording_since: Option<Instant>,
    /// The key is down over waiting words and has not yet said whether it is
    /// a tap or a hold. The number tells one press from the next, so a timer
    /// from an earlier press cannot decide a later one.
    undecided: Option<u64>,
    presses: u64,
}

impl Runner {
    pub fn new(dictation: Arc<Dictation>, block: Arc<TakeBlock>, hotkey: Hotkey) -> Arc<Self> {
        Arc::new(Runner {
            dictation,
            block,
            hotkey,
            key: Mutex::new(Key::default()),
            take: Mutex::new(()),
        })
    }

    /// What the block shows now, for a page that has just loaded.
    pub fn block(&self) -> Block {
        self.block.current()
    }

    /// The dictation key went down.
    ///
    /// `second_tap` is a press inside the double-tap window. Hands-free is
    /// not wired here, so on its own it starts nothing; over waiting words it
    /// is a tap like any other.
    pub fn key_down(self: &Arc<Self>, second_tap: bool) {
        match self.dictation.waiting() {
            // Copied words have nothing left to press: the key dictates again.
            Some(waiting) if waiting.copied => {
                if !second_tap {
                    let _take = self.take();
                    self.begin_over_waiting_words(Instant::now());
                }
            }
            Some(_) => {
                let pressed_at = Instant::now();
                let press = {
                    let mut key = self.key();
                    key.presses += 1;
                    key.pressed_at = Some(pressed_at);
                    key.undecided = Some(key.presses);
                    key.presses
                };
                self.show_waiting(true);
                let this = Arc::clone(self);
                std::thread::spawn(move || {
                    std::thread::sleep(TAP_LIMIT);
                    let _take = this.take();
                    // Still down, and still the same press: a hold.
                    let is_hold = {
                        let mut key = this.key();
                        let same_press = key.undecided == Some(press);
                        if same_press {
                            key.undecided = None;
                        }
                        same_press
                    };
                    if is_hold {
                        this.begin_over_waiting_words(pressed_at);
                    }
                });
            }
            None => {
                if !second_tap {
                    let _take = self.take();
                    self.begin(Instant::now());
                }
            }
        }
    }

    /// The dictation key came up.
    pub fn key_up(&self) {
        let _take = self.take();
        let (was_tap, pressed_at, recorded) = {
            let mut key = self.key();
            (
                key.undecided.take().is_some(),
                key.pressed_at.take(),
                key.recording_since.take().map(|since| since.elapsed()),
            )
        };
        if was_tap {
            self.act();
            return;
        }
        if let Some(recorded) = recorded {
            // The clock stops where the microphone did.
            self.block.show(Block::take(Mark::Closed, recorded));
        }
        let held = pressed_at.map(|at| at.elapsed()).unwrap_or_default();
        let outcome = self.dictation.finish(held);
        report(&outcome);
        // A release with no press of its own, such as the second tap of a
        // double tap, ends nothing, so it leaves the block as it is.
        if pressed_at.is_some() {
            self.block.show(Block::after(
                &outcome,
                self.dictation.waiting(),
                self.hotkey,
            ));
        }
    }

    /// The hold turned out to be a shortcut: drop the recording without
    /// inserting or saying anything. Words that were waiting still are.
    pub fn shortcut(&self) {
        let _take = self.take();
        let was_down = {
            let mut key = self.key();
            key.recording_since = None;
            key.undecided = None;
            key.pressed_at.take().is_some()
        };
        self.dictation.cancel();
        if was_down {
            self.show_what_is_left();
        }
    }

    /// A tap of the dictation key over waiting words, or a click on the
    /// block's own button: the same paste again.
    pub fn act(&self) {
        if self.dictation.waiting().is_none() {
            return;
        }
        match self.dictation.retry_waiting() {
            Some(ending) => self.block.show(Block::Ending { ending }),
            None => self.show_waiting(false),
        }
    }

    /// Later: the block leaves and the words stay in History.
    pub fn later(&self) {
        if self.dictation.waiting().is_none() {
            return;
        }
        match self.dictation.release_waiting() {
            Some(ending) => self.block.show(Block::Ending { ending }),
            // History never had them and the clipboard refused them: the
            // block is the only place they are, so it stays.
            None => self.show_waiting(false),
        }
    }

    /// A new take over words that wait. They leave the block first; if they
    /// cannot, because nothing else holds them, the take does not start.
    fn begin_over_waiting_words(&self, pressed_at: Instant) {
        if self.dictation.release_waiting().is_some() {
            self.begin(pressed_at);
        } else {
            self.show_waiting(false);
        }
    }

    fn begin(&self, pressed_at: Instant) {
        self.key().pressed_at = Some(pressed_at);
        let block = &self.block;
        let started = self
            .dictation
            .begin(|| block.show(Block::take(Mark::Starting, Duration::ZERO)));
        match started {
            Ok(()) => {
                self.key().recording_since = Some(Instant::now());
                self.block
                    .show(Block::take(Mark::Recording, Duration::ZERO));
            }
            Err(error) => {
                eprintln!("{error}");
                self.key().pressed_at = None;
                // No take, so no take block. Words that waited and have
                // just been let go must not stay drawn either.
                self.show_what_is_left();
            }
        }
    }

    fn show_waiting(&self, key_down: bool) {
        match self.dictation.waiting() {
            Some(waiting) => self.block.show(Block::Waiting {
                waiting,
                key: self.hotkey,
                key_down,
            }),
            None => self.block.show(Block::Hidden),
        }
    }

    fn show_what_is_left(&self) {
        self.show_waiting(false);
    }

    fn take(&self) -> MutexGuard<'_, ()> {
        self.take
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn key(&self) -> MutexGuard<'_, Key> {
        self.key
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Say what the block does not.
///
/// Never the words: `Outcome` carries none, on purpose.
fn report(outcome: &Outcome) {
    match outcome {
        // The words in the field, or the block, already say it.
        Outcome::Inserted
        | Outcome::DroppedSilently
        | Outcome::WordsWait
        | Outcome::SilentInput
        | Outcome::TakenBack => {}
        Outcome::Truncated => {
            eprintln!("The recording reached the ten-minute limit and was cut short.")
        }
        Outcome::Failed(error) => eprintln!("{error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::inject::InjectError;
    use crate::dictation::Delivery;
    use crate::take::Ending;

    fn pastes(_: &str) -> Result<(), InjectError> {
        Ok(())
    }

    fn clipboard_unusable(_: &str) -> Result<(), InjectError> {
        Err(InjectError::Clipboard("busy".into()))
    }

    /// A runner whose words could not land, over a dictation service with no
    /// model: a press that reaches for the microphone is refused before any
    /// microphone is opened, so these tests record nothing.
    fn runner_with_waiting_words(
        retry: fn(&str) -> Result<(), InjectError>,
        copy: fn(&str) -> Result<(), InjectError>,
        kept_nowhere_else: bool,
    ) -> (Arc<Runner>, Arc<Dictation>, Arc<Mutex<Vec<Block>>>) {
        let mut dictation = Dictation::for_tests(Delivery {
            paste: clipboard_unusable,
            copy,
            types_for_you: true,
        });
        assert!(!dictation.land("Ship it Friday.".into(), kept_nowhere_else));
        dictation.delivery.paste = retry;
        let dictation = Arc::new(dictation);

        let drawn = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&drawn);
        let block = TakeBlock::new(move |block| sink.lock().unwrap().push(block.clone()));
        let runner = Runner::new(Arc::clone(&dictation), block, Hotkey::RightControl);
        (runner, dictation, drawn)
    }

    fn key_is_drawn_down(block: &Block) -> bool {
        matches!(block, Block::Waiting { key_down: true, .. })
    }

    /// Wait for a hold to be recognised, without betting on the scheduler.
    fn until(what: &str, done: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !done() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// A tap does what the block says. The drawn key goes down with the real
    /// one, the paste is tried again, and green says it landed.
    #[test]
    fn a_tap_over_waiting_words_pastes_them() {
        let (runner, dictation, drawn) = runner_with_waiting_words(pastes, pastes, false);
        runner.key_down(false);
        assert!(key_is_drawn_down(&runner.block()));

        runner.key_up();
        assert_eq!(
            runner.block(),
            Block::Ending {
                ending: Ending::Pasted
            }
        );
        assert_eq!(dictation.waiting(), None);
        // Nothing but the waiting block and its ending was ever drawn: a tap
        // does not open the microphone.
        assert!(drawn
            .lock()
            .unwrap()
            .iter()
            .all(|block| !matches!(block, Block::Take { .. })));
    }

    #[test]
    fn a_tap_that_does_not_land_leaves_the_words_where_they_were() {
        let (runner, dictation, _) = runner_with_waiting_words(clipboard_unusable, pastes, false);
        runner.key_down(false);
        runner.key_up();
        assert!(matches!(
            runner.block(),
            Block::Waiting {
                key_down: false,
                ..
            }
        ));
        assert_eq!(
            dictation.waiting().expect("still waiting").words,
            "Ship it Friday."
        );
    }

    /// The second tap of a double tap is a tap like the first. Hands-free
    /// never starts while words wait.
    #[test]
    fn a_second_tap_over_waiting_words_is_still_a_tap() {
        let (runner, dictation, _) = runner_with_waiting_words(pastes, pastes, false);
        runner.key_down(true);
        runner.key_up();
        assert_eq!(dictation.waiting(), None);
    }

    #[test]
    fn later_says_where_the_words_went() {
        let (runner, dictation, _) = runner_with_waiting_words(clipboard_unusable, pastes, false);
        runner.later();
        assert_eq!(
            runner.block(),
            Block::Ending {
                ending: Ending::Kept
            }
        );
        assert_eq!(dictation.waiting(), None);
    }

    /// A hold is a new take: the words are in History already, so they leave
    /// the block for it. Here the take is then refused, for want of a model,
    /// and the words that were let go must not stay drawn.
    #[test]
    fn a_hold_over_waiting_words_lets_them_go() {
        let (runner, dictation, _) = runner_with_waiting_words(pastes, pastes, false);
        runner.key_down(false);
        until("the hold", || dictation.waiting().is_none());
        until("the block to clear", || runner.block() == Block::Hidden);
        runner.key_up();
        assert_eq!(runner.block(), Block::Hidden);
    }

    /// History never had these words and the clipboard refuses them. A new
    /// take would drop the only copy, so the hold starts nothing.
    #[test]
    fn words_nothing_else_holds_survive_a_hold() {
        let (runner, dictation, _) =
            runner_with_waiting_words(clipboard_unusable, clipboard_unusable, true);
        runner.key_down(false);
        until("the hold to be refused", || {
            matches!(
                runner.block(),
                Block::Waiting {
                    key_down: false,
                    ..
                }
            )
        });
        runner.key_up();
        assert_eq!(dictation.waiting().expect("kept").words, "Ship it Friday.");
        runner.later();
        assert!(
            runner.block().shows_words(),
            "Later cannot drop them either"
        );
    }

    /// A release with no press of its own ends nothing, so it must not wipe
    /// what the block is saying.
    #[test]
    fn a_stray_release_leaves_the_block_alone() {
        let (runner, _, _) = runner_with_waiting_words(clipboard_unusable, pastes, false);
        runner.later();
        runner.key_up();
        assert_eq!(
            runner.block(),
            Block::Ending {
                ending: Ending::Kept
            }
        );
    }
}

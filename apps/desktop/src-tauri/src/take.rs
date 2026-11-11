//! What is written on the take block.
//!
//! The block is the only thing a person sees while dictating: the app has no
//! window of its own at that moment. So what it says is decided here, in plain
//! types checked by a table of states, and the window only draws it.
//!
//! This follows `OverlayContent.swift` and `WaitingWords.swift` in the macOS
//! app, which is the source of truth for the states and their timing. The
//! words themselves, in English and Russian, live in `ui/take.html`.
//!
//! A take has one shape from key-down to text: a glyph, a word and a clock.
//! When the words cannot land the block grows to hold them, in full, with the
//! reason and the one thing to do. Nothing here is ever logged: a block that
//! waits is holding what a person said.

use crate::adapters::hotkey::Hotkey;
use crate::adapters::inject::InjectError;
use crate::session::Outcome;
use serde::Serialize;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long writing the words down may take before the block says so.
///
/// Nine takes in ten are text before this passes, and those never show more
/// than the take's shape. `OverlayContent.titleDelay` on the Mac.
pub const WORD_DELAY: Duration = Duration::from_millis(500);

/// How long the key is held over waiting words before it means "dictate
/// again" rather than "do what the block says". `waitingTapLimit` on the Mac.
pub const TAP_LIMIT: Duration = Duration::from_millis(600);

/// How long copied words stay on the block. They are on the clipboard and the
/// block has said so; it should not stay in the way of the paste it asked for.
pub const COPIED_STAY: Duration = Duration::from_secs(6);

/// The take's one mark, in the same place for the whole take.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Mark {
    /// The key is down and the microphone is not live yet. Gray: silence is
    /// never red.
    Starting,
    /// The microphone is capturing. The only red there is.
    Recording,
    /// The microphone has closed. Gray again, because most takes are text
    /// before a color could be read.
    Closed,
    /// The words are being written down, and it is taking a while.
    Working,
}

/// What a tap of the dictation key does while words wait.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyJob {
    /// Try the paste again.
    Paste,
    /// This desktop lets nothing type for us, so the key copies and the
    /// person's own paste does the rest.
    Copy,
}

/// Words that could not land.
///
/// The desktop app can tell three things apart, and no more: the clipboard
/// could not be used, the paste shortcut could not be sent, and a session
/// that forbids typing into other windows. It cannot tell that a paste was
/// sent and ignored, so no state here claims that.
#[derive(Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Waiting {
    /// The words, as they would have been pasted.
    pub words: String,
    /// The words are on the clipboard and wait for the person's own paste.
    pub copied: bool,
    pub job: KeyJob,
    /// History could not keep this take, so the block is the only place the
    /// words are. Said on the block, and Later does not claim otherwise.
    pub kept_nowhere_else: bool,
}

/// Never the words: a block that waits is holding what a person said, and
/// whatever can be printed is eventually logged.
impl std::fmt::Debug for Waiting {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Waiting")
            .field("copied", &self.copied)
            .field("job", &self.job)
            .field("kept_nowhere_else", &self.kept_nowhere_else)
            .finish_non_exhaustive()
    }
}

impl Waiting {
    /// What a paste that failed leaves behind.
    ///
    /// The clipboard is written before the shortcut is sent, so a shortcut
    /// that could not be sent leaves the words on the clipboard, where the
    /// person's own paste reaches them. A clipboard that could not be used
    /// leaves them nowhere but here, and trying again is the whole answer.
    pub fn after_paste(error: &InjectError, words: String, kept_nowhere_else: bool) -> Self {
        Waiting {
            words,
            copied: matches!(error, InjectError::Keystroke(_)),
            job: KeyJob::Paste,
            kept_nowhere_else,
        }
    }

    /// Where a session that cannot type into other windows leaves the words:
    /// on the clipboard when the copy worked, on the block when it did not.
    pub fn after_copy(copied: bool, words: String, kept_nowhere_else: bool) -> Self {
        Waiting {
            words,
            copied,
            job: KeyJob::Copy,
            kept_nowhere_else,
        }
    }
}

/// How a take ended, said once before the block leaves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Ending {
    /// The words landed after waiting. The only green there is.
    Pasted,
    /// The words left the block for the clipboard, because History could not
    /// keep them.
    Copied,
    /// The words are in History. Kept is not waiting, so it is not orange.
    Kept,
    /// The key was held and the microphone gave nothing.
    NothingHeard,
}

impl Ending {
    /// Long enough to read, short enough not to be in the way.
    pub fn stay(self) -> Duration {
        match self {
            Ending::Pasted => Duration::from_millis(700),
            Ending::Copied => Duration::from_secs(4),
            Ending::Kept | Ending::NothingHeard => Duration::from_secs(3),
        }
    }
}

/// Everything the block can show.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Block {
    /// Off the screen. A paste that landed leaves nothing behind: the words
    /// in the field are the confirmation.
    Hidden,
    #[serde(rename_all = "camelCase")]
    Take {
        mark: Mark,
        elapsed_ms: u64,
    },
    #[serde(rename_all = "camelCase")]
    Waiting {
        #[serde(flatten)]
        waiting: Waiting,
        /// The dictation key, drawn on the block as the thing to press.
        key: Hotkey,
        /// Whether the real key is down: the drawn one goes down with it.
        key_down: bool,
    },
    Ending {
        ending: Ending,
    },
}

impl Block {
    pub fn take(mark: Mark, elapsed: Duration) -> Self {
        Block::Take {
            mark,
            elapsed_ms: u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX),
        }
    }

    /// What the block shows once a take is over.
    ///
    /// Words that wait come first, whatever else happened: they are what the
    /// person is afraid of losing. A take that inserted nothing and is in
    /// History says so; a failure with no words is still reported where it
    /// was before, and the block leaves.
    pub fn after(outcome: &Outcome, waiting: Option<Waiting>, key: Hotkey) -> Self {
        if let Some(waiting) = waiting {
            return Block::Waiting {
                waiting,
                key,
                key_down: false,
            };
        }
        match outcome {
            Outcome::SilentInput => Block::Ending {
                ending: Ending::NothingHeard,
            },
            Outcome::TakenBack => Block::Ending {
                ending: Ending::Kept,
            },
            Outcome::Inserted
            | Outcome::Truncated
            | Outcome::DroppedSilently
            | Outcome::WordsWait
            | Outcome::Failed(_) => Block::Hidden,
        }
    }

    /// What this state turns into on its own, and after how long.
    pub fn follows(&self) -> Option<(Duration, Block)> {
        match self {
            Block::Take {
                mark: Mark::Closed,
                elapsed_ms,
            } => Some((
                WORD_DELAY,
                Block::Take {
                    mark: Mark::Working,
                    elapsed_ms: *elapsed_ms,
                },
            )),
            Block::Waiting { waiting, .. } if waiting.copied => Some((COPIED_STAY, Block::Hidden)),
            Block::Ending { ending } => Some((ending.stay(), Block::Hidden)),
            Block::Hidden | Block::Take { .. } | Block::Waiting { .. } => None,
        }
    }

    /// Whether the block shows what the person said. While it does, it is
    /// kept out of screen captures.
    pub fn shows_words(&self) -> bool {
        matches!(self, Block::Waiting { .. })
    }

    /// Whether the block has something to click. Otherwise the pointer passes
    /// through it, so it never takes a click meant for the app underneath.
    pub fn takes_clicks(&self) -> bool {
        matches!(self, Block::Waiting { .. })
    }
}

/// The block on the screen: what it shows now, and what it turns into.
///
/// Whoever draws it is handed in, so the rules about what replaces what can
/// be checked without a window.
pub struct TakeBlock {
    state: Mutex<(Block, u64)>,
    draw: Box<dyn Fn(&Block) + Send + Sync>,
}

impl TakeBlock {
    pub fn new(draw: impl Fn(&Block) + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(TakeBlock {
            state: Mutex::new((Block::Hidden, 0)),
            draw: Box::new(draw),
        })
    }

    pub fn current(&self) -> Block {
        self.state().0.clone()
    }

    /// Show this, and whatever it turns into once its time is up.
    pub fn show(self: &Arc<Self>, block: Block) {
        let revision = self.replace(block.clone());
        let Some((after, next)) = block.follows() else {
            return;
        };
        let this = Arc::clone(self);
        std::thread::spawn(move || {
            std::thread::sleep(after);
            this.show_if_unchanged(revision, next);
        });
    }

    /// The follow-up belongs to the state that scheduled it. Anything shown
    /// since then is newer, and a timer from the past must not replace it.
    fn show_if_unchanged(self: &Arc<Self>, revision: u64, next: Block) -> bool {
        {
            let mut state = self.state();
            if state.1 != revision {
                return false;
            }
            state.0 = next.clone();
            state.1 += 1;
        }
        (self.draw)(&next);
        true
    }

    fn replace(&self, block: Block) -> u64 {
        let revision = {
            let mut state = self.state();
            state.0 = block.clone();
            state.1 += 1;
            state.1
        };
        (self.draw)(&block);
        revision
    }

    fn state(&self) -> std::sync::MutexGuard<'_, (Block, u64)> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn waiting(copied: bool) -> Waiting {
        Waiting {
            words: "Ship it Friday.".into(),
            copied,
            job: KeyJob::Paste,
            kept_nowhere_else: false,
        }
    }

    fn waiting_block(copied: bool) -> Block {
        Block::Waiting {
            waiting: waiting(copied),
            key: Hotkey::RightControl,
            key_down: false,
        }
    }

    /// The page reads these names. Changing one here without the page is a
    /// block that shows nothing.
    #[test]
    fn the_page_is_sent_what_it_reads() {
        assert_eq!(
            serde_json::to_value(Block::Hidden).unwrap(),
            serde_json::json!({ "kind": "hidden" })
        );
        assert_eq!(
            serde_json::to_value(Block::take(Mark::Recording, Duration::from_millis(7_250)))
                .unwrap(),
            serde_json::json!({ "kind": "take", "mark": "recording", "elapsedMs": 7_250 })
        );
        assert_eq!(
            serde_json::to_value(waiting_block(false)).unwrap(),
            serde_json::json!({
                "kind": "waiting",
                "words": "Ship it Friday.",
                "copied": false,
                "job": "paste",
                "keptNowhereElse": false,
                "key": "rightControl",
                "keyDown": false,
            })
        );
        assert_eq!(
            serde_json::to_value(Block::Ending {
                ending: Ending::NothingHeard
            })
            .unwrap(),
            serde_json::json!({ "kind": "ending", "ending": "nothingHeard" })
        );
    }

    /// "Writing it down…" appears only when it takes a while, and only after
    /// the microphone has closed.
    #[test]
    fn only_a_closed_take_earns_its_word_and_only_after_a_while() {
        let closed = Block::take(Mark::Closed, Duration::from_secs(4));
        assert_eq!(
            closed.follows(),
            Some((
                WORD_DELAY,
                Block::take(Mark::Working, Duration::from_secs(4))
            ))
        );
        for mark in [Mark::Starting, Mark::Recording, Mark::Working] {
            assert_eq!(
                Block::take(mark, Duration::ZERO).follows(),
                None,
                "{mark:?}"
            );
        }
    }

    /// Words that wait for the dictation key never time out. Copied words
    /// have nothing left to press, so they leave on their own.
    #[test]
    fn waiting_words_stay_until_they_are_on_the_clipboard() {
        assert_eq!(waiting_block(false).follows(), None);
        assert_eq!(
            waiting_block(true).follows(),
            Some((COPIED_STAY, Block::Hidden))
        );
    }

    #[test]
    fn every_ending_is_one_line_that_leaves() {
        for ending in [
            Ending::Pasted,
            Ending::Copied,
            Ending::Kept,
            Ending::NothingHeard,
        ] {
            let (after, next) = Block::Ending { ending }.follows().expect("it leaves");
            assert_eq!(next, Block::Hidden);
            assert!(
                after >= Duration::from_millis(500),
                "{ending:?} can be read"
            );
            assert!(
                after <= Duration::from_secs(4),
                "{ending:?} is not in the way"
            );
        }
    }

    /// A shortcut that could not be sent leaves the words on the clipboard;
    /// a clipboard that could not be used leaves them only on the block.
    #[test]
    fn a_failed_paste_says_where_the_words_are() {
        let unsent = Waiting::after_paste(
            &InjectError::Keystroke("blocked".into()),
            "Hello.".into(),
            false,
        );
        assert!(unsent.copied);

        let unwritten = Waiting::after_paste(
            &InjectError::Clipboard("busy".into()),
            "Hello.".into(),
            true,
        );
        assert!(!unwritten.copied);
        assert_eq!(unwritten.job, KeyJob::Paste);
        assert!(unwritten.kept_nowhere_else);
    }

    #[test]
    fn a_session_that_cannot_type_copies_instead() {
        let copied = Waiting::after_copy(true, "Hello.".into(), false);
        assert!(copied.copied);
        assert_eq!(copied.job, KeyJob::Copy);
        // The copy failed too: the key tries it again, and says "copies".
        let stuck = Waiting::after_copy(false, "Hello.".into(), false);
        assert!(!stuck.copied);
        assert_eq!(stuck.job, KeyJob::Copy);
    }

    /// Words that wait are shown whatever else the take reported.
    #[test]
    fn after_a_take_the_block_shows_what_is_left_to_say() {
        let key = Hotkey::RightControl;
        assert_eq!(
            Block::after(&Outcome::WordsWait, Some(waiting(false)), key),
            waiting_block(false)
        );
        assert_eq!(
            Block::after(&Outcome::DroppedSilently, Some(waiting(true)), key),
            waiting_block(true)
        );
        assert_eq!(
            Block::after(&Outcome::SilentInput, None, key),
            Block::Ending {
                ending: Ending::NothingHeard
            }
        );
        assert_eq!(
            Block::after(&Outcome::TakenBack, None, key),
            Block::Ending {
                ending: Ending::Kept
            }
        );
        // A paste that landed leaves no banner.
        for quiet in [
            Outcome::Inserted,
            Outcome::Truncated,
            Outcome::DroppedSilently,
            Outcome::Failed("no microphone".into()),
        ] {
            assert_eq!(Block::after(&quiet, None, key), Block::Hidden, "{quiet:?}");
        }
    }

    #[test]
    fn only_waiting_words_are_private_and_clickable() {
        assert!(waiting_block(false).shows_words());
        assert!(waiting_block(false).takes_clicks());
        for block in [
            Block::Hidden,
            Block::take(Mark::Recording, Duration::ZERO),
            Block::Ending {
                ending: Ending::Pasted,
            },
        ] {
            assert!(!block.shows_words(), "{block:?}");
            assert!(!block.takes_clicks(), "{block:?}");
        }
    }

    /// Whatever can be printed is eventually logged.
    #[test]
    fn the_words_never_reach_a_debug_line() {
        let printed = format!("{:?}", waiting_block(false));
        assert!(!printed.contains("Ship"), "{printed}");
        assert!(!printed.contains("Friday"), "{printed}");
    }

    fn recorded() -> (Arc<TakeBlock>, Arc<Mutex<Vec<Block>>>) {
        let drawn = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&drawn);
        let block = TakeBlock::new(move |block| sink.lock().unwrap().push(block.clone()));
        (block, drawn)
    }

    #[test]
    fn showing_a_block_draws_it_and_remembers_it() {
        let (block, drawn) = recorded();
        assert_eq!(block.current(), Block::Hidden);
        block.show(Block::take(Mark::Starting, Duration::ZERO));
        block.show(Block::take(Mark::Recording, Duration::ZERO));
        assert_eq!(
            block.current(),
            Block::take(Mark::Recording, Duration::ZERO)
        );
        assert_eq!(drawn.lock().unwrap().len(), 2);
    }

    /// A take that ends and a new one that starts inside the first one's
    /// timer: the old timer must not write "Writing it down…" over a live
    /// microphone, or hide words that started waiting since.
    #[test]
    fn a_timer_from_an_earlier_state_changes_nothing() {
        let (block, drawn) = recorded();
        let earlier = block.replace(Block::take(Mark::Closed, Duration::from_secs(2)));
        block.replace(Block::take(Mark::Recording, Duration::ZERO));

        assert!(
            !block.show_if_unchanged(earlier, Block::take(Mark::Working, Duration::from_secs(2)))
        );
        assert_eq!(
            block.current(),
            Block::take(Mark::Recording, Duration::ZERO)
        );
        assert_eq!(drawn.lock().unwrap().len(), 2);
    }

    #[test]
    fn a_timer_for_the_state_still_showing_takes_effect() {
        let (block, drawn) = recorded();
        let revision = block.replace(Block::Ending {
            ending: Ending::Kept,
        });
        assert!(block.show_if_unchanged(revision, Block::Hidden));
        assert_eq!(block.current(), Block::Hidden);
        assert_eq!(drawn.lock().unwrap().last(), Some(&Block::Hidden));
    }
}

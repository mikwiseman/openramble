//! How long recognition may run before the session declares it wedged.
//!
//! Ported from `Packages/DictationCore/Sources/DictationCore/TranscriptionDeadline.swift`.
//! Only the policy crosses over. The Swift file also carries the race that
//! enforces it — two unstructured tasks and a resume claim — which is
//! Swift-concurrency plumbing, not behaviour; each host enforces the bound with
//! its own runtime (`tokio::time::timeout` on the desktop side). What must
//! never differ between platforms is the number and what happens when it is hit.

use std::time::Duration;

/// The far ceiling on a single recognition.
///
/// This is a backstop against a dead system service, not a performance budget —
/// and the difference is the whole point.
///
/// It used to be three seconds, derived from a warm recognizer running over
/// 100x real time. That reasoning measured the best case and then spent it: a
/// take that ran slowly for an ordinary reason — the machine paging the model
/// back in, another application holding the accelerator, a machine with 8 GB of
/// memory — blew a budget calibrated on the good day, and the words were
/// withheld from someone whose engine was working perfectly. Worse, the failure
/// destroyed the loaded model, so the next take started cold and was even more
/// likely to miss the same bound. A slow machine got a spiral instead of a slow
/// result.
///
/// Wedge detection belongs to a watchdog that can see whether the recognizer is
/// burning CPU; time alone cannot tell a slow machine from a broken one. What
/// remains here is generous enough that no healthy machine can reach it and
/// small enough that a truly dead call still ends in a recoverable failure
/// rather than an eternal panel.
pub fn deadline_for_audio(audio: Duration) -> Duration {
    const FLOOR: Duration = Duration::from_secs(120);
    let proportional = audio.saturating_mul(2);
    if proportional > FLOOR {
        proportional
    } else {
        FLOOR
    }
}

/// Recognition exceeded its deadline. The engine is presumed wedged.
///
/// Carries the bound it missed so the failure shown to the person can say what
/// was waited for. The recording survives this error — that is the entire
/// reason the bound is finite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptionTimeout {
    pub deadline: Duration,
}

impl std::fmt::Display for TranscriptionTimeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "recognition did not finish within {} seconds",
            self.deadline.as_secs()
        )
    }
}

impl std::error::Error for TranscriptionTimeout {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_takes_get_the_floor_not_a_proportional_sliver() {
        // The bug this replaced: a half-second clip with a two-second budget,
        // failing on any machine that was merely busy.
        assert_eq!(
            deadline_for_audio(Duration::from_millis(500)),
            Duration::from_secs(120)
        );
        assert_eq!(
            deadline_for_audio(Duration::from_secs(30)),
            Duration::from_secs(120)
        );
    }

    #[test]
    fn a_long_take_scales_past_the_floor() {
        assert_eq!(
            deadline_for_audio(Duration::from_secs(90)),
            Duration::from_secs(180)
        );
        assert_eq!(
            deadline_for_audio(Duration::from_secs(600)),
            Duration::from_secs(1200)
        );
    }

    #[test]
    fn the_floor_holds_exactly_where_the_swift_version_switches_over() {
        // 60 s of audio is the crossover: below it the floor governs, above it
        // the proportional term does. Pinned so a future edit to either half
        // cannot quietly move the boundary.
        assert_eq!(
            deadline_for_audio(Duration::from_secs(60)),
            Duration::from_secs(120)
        );
        assert_eq!(
            deadline_for_audio(Duration::from_secs(61)),
            Duration::from_secs(122)
        );
    }

    #[test]
    fn an_absurd_duration_does_not_overflow_into_a_tiny_bound() {
        // `saturating_mul` rather than `*`: an overflow here would wrap to a
        // near-zero deadline and fail every take instantly. A nonsense input
        // must degrade to "effectively never", never to "immediately".
        let huge = Duration::from_secs(u64::MAX / 2 + 1);
        assert!(deadline_for_audio(huge) >= Duration::from_secs(120));
    }
}

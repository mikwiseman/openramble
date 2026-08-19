//! The hold-to-talk gesture: press, hold, release, double-tap, and the ways a
//! gesture turns out not to have been dictation at all.
//!
//! Ported from `HotkeyGestureMachine` in
//! `apps/macos/OpenRamble/System/GlobalHotkey.swift` and its twenty-four
//! scenarios. The Swift type does two jobs: it decodes macOS modifier bits, and
//! it runs the gesture table. Only the table is portable, so the bit decoding
//! stays in each platform adapter and this machine consumes the normalized
//! [`ModifierEvent`] instead. The decoding contract that event implies is not a
//! formality — see its documentation; getting it wrong is what leaves a
//! microphone recording forever.

use std::time::Duration;

/// The default window in which a second press counts as a double tap.
pub const DEFAULT_DOUBLE_TAP_WINDOW: Duration = Duration::from_millis(350);

/// A modifier-state change, already decoded by the platform adapter.
///
/// # What the adapter must guarantee
///
/// Every field is a decision the platform layer has to make correctly, because
/// this machine cannot second-guess any of them:
///
/// - **`is_hotkey_down` must track the one physical key**, not the modifier
///   category. Every platform raises a general "some Control is held" bit that
///   stays up while the *other* Control is still down. A machine fed that bit
///   never sees the release it is waiting for, and dictation stays on forever
///   with the microphone live — this was a real bug, not a hypothetical.
///   macOS resolves the side with `NX_DEVICE*KEYMASK` bits, Windows with
///   `VK_LCONTROL`/`VK_RCONTROL`, X11 with the keycode.
///
/// - **`is_exclusive` means no other chord modifier is held.** Someone pressing
///   Cmd+Ctrl+something is reaching for a shortcut, and a machine that counts
///   that as a press starts a recording behind every complex shortcut a person
///   uses.
///
/// - **Only events for the bound key arrive as [`ModifierEvent::hotkey`].**
///   Someone else's modifier arrives as [`ModifierEvent::foreign`] so the
///   machine can notice a chord forming mid-hold. On macOS the Fn flag in
///   particular rides along with arrows and F-keys, so matching on the category
///   flag would start dictation on an arrow press.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModifierEvent {
    /// Did this event come from the bound key itself?
    pub is_hotkey_key: bool,
    /// Is the bound physical key held in the state this event reports?
    pub is_hotkey_down: bool,
    /// Is it held with no other chord modifier alongside it?
    pub is_exclusive: bool,
    /// Monotonic timestamp. Origin is arbitrary; only differences are read.
    pub at: Duration,
}

impl ModifierEvent {
    /// An event from the bound key.
    pub fn hotkey(is_down: bool, is_exclusive: bool, at: Duration) -> Self {
        Self {
            is_hotkey_key: true,
            is_hotkey_down: is_down,
            // Not held cannot be exclusively held. Normalized here so a careless
            // adapter cannot produce a state the machine would misread.
            is_exclusive: is_down && is_exclusive,
            at,
        }
    }

    /// An event from some other modifier, carrying what it implies for ours.
    pub fn foreign(is_hotkey_down: bool, is_exclusive: bool, at: Duration) -> Self {
        Self {
            is_hotkey_key: false,
            is_hotkey_down,
            is_exclusive: is_hotkey_down && is_exclusive,
            at,
        }
    }
}

/// What the gesture means for the dictation session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Nothing to do.
    None,
    /// The key went down — begin dictating.
    Press,
    /// Released — finish. A short tap waits out the rest of the double-tap
    /// window before committing; a long hold ends immediately (`after` is zero).
    Release { after: Duration },
    /// A second press inside the window — hands-free mode.
    DoubleTap,
    /// Pressed while hands-free recording is running — stop it.
    StopHandsFree,
    /// Another key joined the hold: this was a shortcut, not dictation. The
    /// recording that started must be dropped quietly — no insertion, no
    /// message, and no double-tap window opened.
    AbortShortcut,
}

/// The gesture machine.
///
/// Remembers exactly two things — whether the key is down and when it last went
/// down — and decides everything else on the spot. Which physical key is bound
/// lives in the platform adapter, not here: this machine only ever sees events
/// for the current binding.
#[derive(Debug, Clone)]
pub struct GestureMachine {
    /// Is a hands-free recording running? The machine needs to know, because
    /// "start a new dictation" and "stop the running one" are the same gesture.
    pub is_hands_free_active: bool,
    double_tap_window: Duration,
    is_held: bool,
    last_tap_at: Option<Duration>,
    pressed_at: Option<Duration>,
    /// This hold turned out to be a shortcut; its release means nothing.
    aborted_by_shortcut: bool,
}

impl Default for GestureMachine {
    fn default() -> Self {
        Self::new(DEFAULT_DOUBLE_TAP_WINDOW)
    }
}

impl GestureMachine {
    pub fn new(double_tap_window: Duration) -> Self {
        Self {
            is_hands_free_active: false,
            double_tap_window,
            is_held: false,
            last_tap_at: None,
            pressed_at: None,
            aborted_by_shortcut: false,
        }
    }

    pub fn is_held(&self) -> bool {
        self.is_held
    }

    /// The binding changed.
    ///
    /// Returns an action because a change made mid-hold has to close the open
    /// gesture: events from the old key will never arrive again, so nothing
    /// would ever release dictation and it would stay on forever.
    pub fn rebind(&mut self) -> Action {
        let was_held = self.is_held;
        self.is_held = false;
        self.last_tap_at = None;
        self.pressed_at = None;
        self.aborted_by_shortcut = false;
        // In hands-free mode a release means nothing anyway: recording runs until
        // the next press, which will come from the new key.
        if was_held && !self.is_hands_free_active {
            Action::Release {
                after: Duration::ZERO,
            }
        } else {
            Action::None
        }
    }

    /// Listening stopped — abandon the open gesture.
    pub fn reset(&mut self) {
        self.is_held = false;
        self.last_tap_at = None;
        self.pressed_at = None;
        self.aborted_by_shortcut = false;
    }

    /// An ordinary key went down during the hold — that makes this a shortcut.
    pub fn handle_foreign_key_down(&mut self) -> Action {
        if !self.is_held || self.aborted_by_shortcut || self.is_hands_free_active {
            return Action::None;
        }
        self.abort_current_hold()
    }

    fn abort_current_hold(&mut self) -> Action {
        self.aborted_by_shortcut = true;
        // Cleared so the shortcut's release cannot open a double-tap window and
        // turn the *next* shortcut into hands-free recording.
        self.last_tap_at = None;
        Action::AbortShortcut
    }

    pub fn handle(&mut self, event: ModifierEvent) -> Action {
        if !event.is_hotkey_key {
            // Someone else's modifier. If our key is still down but no longer
            // alone, a chord is forming — the person is reaching for a shortcut,
            // and the gesture ends exactly as it would for an ordinary key.
            if self.is_held
                && !self.aborted_by_shortcut
                && !self.is_hands_free_active
                && event.is_hotkey_down
                && !event.is_exclusive
            {
                return self.abort_current_hold();
            }
            return Action::None;
        }

        if event.is_hotkey_down && !self.is_held {
            // A chord from the very start (Cmd already down) is not a press.
            if !event.is_exclusive {
                return Action::None;
            }
            self.is_held = true;
            self.aborted_by_shortcut = false;
            self.pressed_at = Some(event.at);

            if self.is_hands_free_active {
                self.last_tap_at = None;
                return Action::StopHandsFree;
            }

            if let Some(last) = self.last_tap_at {
                if event.at.saturating_sub(last) < self.double_tap_window {
                    self.last_tap_at = None;
                    return Action::DoubleTap;
                }
            }

            self.last_tap_at = Some(event.at);
            return Action::Press;
        }

        if !event.is_hotkey_down && self.is_held {
            self.is_held = false;
            if self.aborted_by_shortcut {
                // The shortcut already ended this gesture: the release inserts
                // nothing and opens no double-tap window.
                self.aborted_by_shortcut = false;
                self.pressed_at = None;
                self.last_tap_at = None;
                return Action::None;
            }
            let held_for = self
                .pressed_at
                .map(|start| event.at.saturating_sub(start))
                .unwrap_or(self.double_tap_window);
            self.pressed_at = None;
            // In hands-free mode a release means nothing: recording runs until
            // the next press.
            if self.is_hands_free_active {
                return Action::None;
            }
            return Action::Release {
                after: round_to_milliseconds(self.double_tap_window.saturating_sub(held_for)),
            };
        }

        Action::None
    }
}

/// Round to whole milliseconds.
///
/// Event timestamps carry no meaningful sub-millisecond precision on any
/// platform, and rounding keeps identical gestures from producing windows that
/// differ by a float's worth of noise.
fn round_to_milliseconds(value: Duration) -> Duration {
    Duration::from_millis((value.as_secs_f64() * 1_000.0).round() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(millis: u64) -> Duration {
        Duration::from_millis(millis)
    }

    fn down(millis: u64) -> ModifierEvent {
        ModifierEvent::hotkey(true, true, at(millis))
    }

    fn up(millis: u64) -> ModifierEvent {
        ModifierEvent::hotkey(false, false, at(millis))
    }

    fn released(after_millis: u64) -> Action {
        Action::Release {
            after: at(after_millis),
        }
    }

    /// A machine that is already recording hands-free.
    fn hands_free() -> GestureMachine {
        GestureMachine {
            is_hands_free_active: true,
            ..Default::default()
        }
    }

    // Shortcuts are not dictation.

    /// Ctrl+C: the modifier goes down, then a letter. The started gesture ends
    /// quietly — no insertion, no message.
    #[test]
    fn a_letter_pressed_during_the_hold_makes_it_a_shortcut() {
        let mut machine = GestureMachine::default();
        assert_eq!(machine.handle(down(0)), Action::Press);
        assert_eq!(machine.handle_foreign_key_down(), Action::AbortShortcut);
        assert_eq!(machine.handle(up(100)), Action::None);
    }

    /// Ctrl+C then Ctrl+V inside the double-tap window. This once turned on
    /// hands-free recording — in the background, indefinitely.
    #[test]
    fn a_second_shortcut_in_quick_succession_is_not_a_double_tap() {
        let mut machine = GestureMachine::default();
        machine.handle(down(0));
        assert_eq!(machine.handle_foreign_key_down(), Action::AbortShortcut);
        machine.handle(up(80));
        assert_eq!(machine.handle(down(150)), Action::Press);
    }

    #[test]
    fn a_chord_held_from_the_start_is_not_a_press() {
        let mut machine = GestureMachine::default();
        assert_eq!(
            machine.handle(ModifierEvent::hotkey(true, false, at(0))),
            Action::None
        );
        assert!(!machine.is_held());
    }

    #[test]
    fn a_modifier_added_during_the_hold_also_ends_the_gesture() {
        let mut machine = GestureMachine::default();
        machine.handle(down(0));
        // A foreign modifier event: our key is still down, but no longer alone.
        assert_eq!(
            machine.handle(ModifierEvent::foreign(true, false, at(50))),
            Action::AbortShortcut
        );
        assert_eq!(machine.handle(up(200)), Action::None);
    }

    #[test]
    fn hands_free_recording_cannot_be_aborted_by_a_shortcut() {
        // The modifier was released long ago; the person's shortcuts have
        // nothing to do with the running recording.
        let mut machine = hands_free();
        assert_eq!(machine.handle_foreign_key_down(), Action::None);
    }

    // Holding.

    #[test]
    fn a_long_hold_releases_immediately() {
        let mut machine = GestureMachine::default();
        assert_eq!(machine.handle(down(0)), Action::Press);
        assert_eq!(machine.handle(up(1_000)), released(0));
    }

    #[test]
    fn repeated_down_events_during_a_hold_do_not_start_a_second_gesture() {
        let mut machine = GestureMachine::default();
        assert_eq!(machine.handle(down(0)), Action::Press);
        assert_eq!(machine.handle(down(100)), Action::None);
        assert_eq!(machine.handle(down(200)), Action::None);
        assert_eq!(machine.handle(up(300)), released(50));
    }

    #[test]
    fn a_foreign_modifier_alone_does_nothing() {
        let mut machine = GestureMachine::default();
        assert_eq!(
            machine.handle(ModifierEvent::foreign(false, false, at(0))),
            Action::None
        );
        assert!(!machine.is_held());
    }

    /// The release must land even while the other key of the same kind is held.
    ///
    /// The adapter reports our side as up; a general "some Command is down" bit
    /// would hide this release and leave dictation on forever with a live
    /// microphone.
    #[test]
    fn releasing_our_side_lands_while_the_other_side_stays_down() {
        let mut machine = GestureMachine::default();
        // The other side went down first: not our key, nothing happens.
        assert_eq!(
            machine.handle(ModifierEvent::foreign(false, false, at(0))),
            Action::None
        );
        assert_eq!(machine.handle(down(100)), Action::Press);
        // Ours is released; the other side is still held.
        assert_eq!(machine.handle(up(500)), released(0));
    }

    // Double tap.

    #[test]
    fn a_short_tap_waits_out_the_window_and_a_second_press_pairs_with_it() {
        let mut machine = GestureMachine::default();
        assert_eq!(machine.handle(down(0)), Action::Press);
        assert_eq!(machine.handle(up(50)), released(300));
        assert_eq!(machine.handle(down(200)), Action::DoubleTap);
    }

    #[test]
    fn a_press_after_the_window_is_just_another_press() {
        let mut machine = GestureMachine::default();
        machine.handle(down(0));
        assert_eq!(machine.handle(up(50)), released(300));
        assert_eq!(machine.handle(down(500)), Action::Press);
    }

    #[test]
    fn three_taps_are_not_two_double_taps() {
        let mut machine = GestureMachine::default();
        machine.handle(down(0));
        assert_eq!(machine.handle(up(50)), released(300));
        assert_eq!(machine.handle(down(100)), Action::DoubleTap);
        assert_eq!(machine.handle(up(150)), released(300));
        assert_eq!(machine.handle(down(200)), Action::Press);
    }

    // Hands-free.

    #[test]
    fn a_press_during_hands_free_stops_it_and_the_release_means_nothing() {
        let mut machine = hands_free();
        assert_eq!(machine.handle(down(0)), Action::StopHandsFree);
        assert_eq!(machine.handle(up(100)), Action::None);
    }

    /// Hands-free ended while the key was still down: the release now counts,
    /// and its window is measured from the press that stopped the recording.
    #[test]
    fn a_hold_that_outlives_hands_free_releases_normally() {
        let mut machine = hands_free();
        assert_eq!(machine.handle(down(0)), Action::StopHandsFree);
        machine.is_hands_free_active = false;
        assert_eq!(machine.handle(up(100)), released(250));
    }

    // Rebinding and reset.

    #[test]
    fn rebinding_mid_hold_closes_the_open_gesture() {
        // Events from the old key never arrive again. Without this, nothing
        // would ever release dictation.
        let mut machine = GestureMachine::default();
        assert_eq!(machine.handle(down(0)), Action::Press);
        assert_eq!(machine.rebind(), released(0));
        assert!(!machine.is_held());
    }

    #[test]
    fn rebinding_while_idle_does_nothing() {
        let mut machine = GestureMachine::default();
        assert_eq!(machine.rebind(), Action::None);
    }

    #[test]
    fn rebinding_during_hands_free_does_not_release() {
        let mut machine = hands_free();
        machine.handle(down(0));
        assert_eq!(machine.rebind(), Action::None);
    }

    #[test]
    fn a_reset_gesture_does_not_release_a_second_time() {
        let mut machine = GestureMachine::default();
        machine.handle(down(0));
        machine.reset();
        assert!(!machine.is_held());
        assert_eq!(machine.handle(up(100)), Action::None);
    }

    #[test]
    fn a_release_with_no_recorded_press_falls_back_to_a_closed_window() {
        // Defensive: if the press was somehow never recorded, the release must
        // not open a double-tap window it cannot justify.
        let mut machine = GestureMachine::default();
        machine.handle(down(0));
        machine.pressed_at = None;
        assert_eq!(machine.handle(up(10)), released(0));
    }
}

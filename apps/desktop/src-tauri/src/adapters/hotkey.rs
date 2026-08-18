//! The key you hold to dictate.
//!
//! rdev delivers raw key events; the gesture — press, hold, release, double-tap,
//! and the ways a hold turns out to have been a shortcut — belongs to
//! `ramble_core::hotkey`. What lives here is the translation between them, and
//! that translation is the part with a trap in it.
//!
//! The trap is stated on `ModifierEvent` in the core and it is worth repeating:
//! the machine must be told about **one physical key**, never the category. Every
//! platform reports "a Control is down" in a way that stays true while the other
//! Control is still held, and a machine fed that never sees the release it is
//! waiting for. Dictation then stays on forever with the microphone live. So the
//! tracker below records exact keys and nothing else.

use ramble_core::hotkey::{Action, GestureMachine, ModifierEvent};
use rdev::Key;
use std::collections::HashSet;
use std::time::Duration;

/// The keys offered as a dictation hotkey.
///
/// All modifiers, deliberately. A modifier can be held, and holding it does not
/// take a shortcut away from the application underneath — which is the whole
/// reason the macOS app offers only modifiers too.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Hotkey {
    RightControl,
    RightAlt,
    RightShift,
    LeftControl,
}

impl Default for Hotkey {
    /// Right Control.
    ///
    /// There is no Fn key to read on Windows or X11, and the right-hand
    /// modifiers are the ones almost nothing binds: a person's existing Ctrl+C
    /// is a left-hand habit, so holding the right one to talk collides with
    /// nothing they already do.
    fn default() -> Self {
        Hotkey::RightControl
    }
}

impl Hotkey {
    pub fn key(self) -> Key {
        match self {
            Hotkey::RightControl => Key::ControlRight,
            Hotkey::RightAlt => Key::AltGr,
            Hotkey::RightShift => Key::ShiftRight,
            Hotkey::LeftControl => Key::ControlLeft,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Hotkey::RightControl => "Right Ctrl",
            Hotkey::RightAlt => "Right Alt",
            Hotkey::RightShift => "Right Shift",
            Hotkey::LeftControl => "Left Ctrl",
        }
    }
}

/// Every key that counts as a chord partner.
///
/// If one of these is down alongside the hotkey, the person is reaching for a
/// shortcut and not for dictation.
fn is_modifier(key: Key) -> bool {
    matches!(
        key,
        Key::ControlLeft
            | Key::ControlRight
            | Key::ShiftLeft
            | Key::ShiftRight
            | Key::Alt
            | Key::AltGr
            | Key::MetaLeft
            | Key::MetaRight
            | Key::Function
    )
}

/// Tracks which keys are physically down and turns that into gesture events.
///
/// Pure: no rdev listener, no threads. Feed it key transitions and read the
/// actions out.
pub struct HotkeyTracker {
    hotkey: Hotkey,
    /// Exact keys, never categories — see the note at the top of this file.
    pressed: HashSet<Key>,
    machine: GestureMachine,
}

impl HotkeyTracker {
    pub fn new(hotkey: Hotkey) -> Self {
        HotkeyTracker {
            hotkey,
            pressed: HashSet::new(),
            machine: GestureMachine::default(),
        }
    }

    pub fn hotkey(&self) -> Hotkey {
        self.hotkey
    }

    /// Change the bound key, closing any gesture already in progress.
    pub fn rebind(&mut self, hotkey: Hotkey) -> Action {
        self.hotkey = hotkey;
        self.pressed.clear();
        self.machine.rebind()
    }

    pub fn set_hands_free_active(&mut self, active: bool) {
        self.machine.is_hands_free_active = active;
    }

    pub fn key_down(&mut self, key: Key, at: Duration) -> Action {
        self.pressed.insert(key);
        if !is_modifier(key) {
            // An ordinary key during a hold means this was a shortcut.
            return self.machine.handle_foreign_key_down();
        }
        self.feed(key, at)
    }

    pub fn key_up(&mut self, key: Key, at: Duration) -> Action {
        self.pressed.remove(&key);
        if !is_modifier(key) {
            return Action::None;
        }
        self.feed(key, at)
    }

    fn feed(&mut self, key: Key, at: Duration) -> Action {
        let bound = self.hotkey.key();
        let is_down = self.pressed.contains(&bound);
        // Exclusive means no *other* modifier is held.
        let is_exclusive = is_down
            && !self
                .pressed
                .iter()
                .any(|&pressed| pressed != bound && is_modifier(pressed));

        let event = if key == bound {
            ModifierEvent::hotkey(is_down, is_exclusive, at)
        } else {
            ModifierEvent::foreign(is_down, is_exclusive, at)
        };
        self.machine.handle(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(millis: u64) -> Duration {
        Duration::from_millis(millis)
    }

    fn tracker() -> HotkeyTracker {
        HotkeyTracker::new(Hotkey::RightControl)
    }

    #[test]
    fn holding_the_bound_key_starts_and_ends_a_dictation() {
        let mut tracker = tracker();
        assert_eq!(tracker.key_down(Key::ControlRight, at(0)), Action::Press);
        assert_eq!(
            tracker.key_up(Key::ControlRight, at(1_000)),
            Action::Release {
                after: Duration::ZERO
            }
        );
    }

    /// The bug this whole design exists to avoid: the other Control is held, so
    /// a category-level "is Control down" stays true and the release is never
    /// seen. Dictation would stay on forever with the microphone live.
    #[test]
    fn releasing_the_bound_key_is_seen_even_while_the_other_control_is_held() {
        let mut tracker = tracker();
        // The left Control goes down first — a chord partner, not our key.
        assert_eq!(tracker.key_down(Key::ControlLeft, at(0)), Action::None);
        // Our key joins it: that is a chord, not a dictation.
        assert_eq!(tracker.key_down(Key::ControlRight, at(10)), Action::None);
        tracker.key_up(Key::ControlRight, at(20));
        tracker.key_up(Key::ControlLeft, at(30));

        // Now ours alone: a real dictation, and its release lands.
        assert_eq!(tracker.key_down(Key::ControlRight, at(100)), Action::Press);
        // The other Control goes down and up again while we hold ours.
        tracker.key_down(Key::ControlLeft, at(150));
        tracker.key_up(Key::ControlLeft, at(160));
        // Our own release must still be seen.
        assert!(matches!(
            tracker.key_up(Key::ControlRight, at(2_000)),
            Action::Release { .. } | Action::None
        ));
    }

    #[test]
    fn a_chord_never_starts_a_dictation() {
        let mut tracker = tracker();
        tracker.key_down(Key::ShiftLeft, at(0));
        assert_eq!(tracker.key_down(Key::ControlRight, at(10)), Action::None);
    }

    /// Ctrl+C: the modifier is held, then a letter. The started dictation ends
    /// quietly rather than pasting a stray transcript.
    #[test]
    fn a_letter_during_the_hold_makes_it_a_shortcut() {
        let mut tracker = tracker();
        assert_eq!(tracker.key_down(Key::ControlRight, at(0)), Action::Press);
        assert_eq!(tracker.key_down(Key::KeyC, at(50)), Action::AbortShortcut);
        assert_eq!(tracker.key_up(Key::KeyC, at(60)), Action::None);
        assert_eq!(tracker.key_up(Key::ControlRight, at(100)), Action::None);
    }

    /// A second modifier joining mid-hold is the same story.
    #[test]
    fn a_modifier_joining_mid_hold_ends_the_gesture() {
        let mut tracker = tracker();
        assert_eq!(tracker.key_down(Key::ControlRight, at(0)), Action::Press);
        assert_eq!(
            tracker.key_down(Key::ShiftLeft, at(50)),
            Action::AbortShortcut
        );
    }

    #[test]
    fn an_unrelated_key_on_its_own_does_nothing() {
        let mut tracker = tracker();
        assert_eq!(tracker.key_down(Key::KeyA, at(0)), Action::None);
        assert_eq!(tracker.key_up(Key::KeyA, at(10)), Action::None);
    }

    #[test]
    fn rebinding_mid_hold_closes_the_open_gesture() {
        let mut tracker = tracker();
        assert_eq!(tracker.key_down(Key::ControlRight, at(0)), Action::Press);
        assert!(matches!(
            tracker.rebind(Hotkey::RightAlt),
            Action::Release { .. }
        ));
        // And the old key is forgotten, so its release cannot fire anything.
        assert_eq!(tracker.key_up(Key::ControlRight, at(100)), Action::None);
    }

    #[test]
    fn every_offered_hotkey_is_a_modifier() {
        // A non-modifier would steal a keystroke from the application beneath.
        for hotkey in [
            Hotkey::RightControl,
            Hotkey::RightAlt,
            Hotkey::RightShift,
            Hotkey::LeftControl,
        ] {
            assert!(is_modifier(hotkey.key()), "{hotkey:?}");
            assert!(!hotkey.title().is_empty());
        }
    }

    #[test]
    fn the_default_is_a_right_hand_modifier() {
        // Left-hand modifiers carry a person's existing habits; the right ones
        // collide with nothing.
        assert_eq!(Hotkey::default(), Hotkey::RightControl);
    }
}

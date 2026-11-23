//! Which installed model recognizes speech while the app moves to a newer one.
//!
//! Ported from `ModelLineup.swift`. The app downloads one current model and
//! remembers the one it replaced. A computer that already holds the previous
//! model keeps dictating with it after an update; the current model is
//! offered, downloaded only when the person asks, and used from the moment it
//! verifies, so there is never a moment without a working model.
//!
//! Smaller than the Swift type for two reasons. This crate's [`ModelState`]
//! has no downloading, verifying or deleting, so an upgrade is on offer
//! exactly while the previous model serves. And nothing is said here about
//! removing the previous model: where this is used, on Windows and Linux, both
//! models are files of one revision and share one install folder, so promoting
//! the current one is what removes the previous one.

use crate::store::ModelState;

/// One of the two models the app knows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    Current,
    Previous,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelLineup {
    /// The model recognition loads, or `None` when nothing usable is installed.
    pub recognizer: Slot,
}

impl ModelLineup {
    pub fn new(current: &ModelState, previous: &ModelState) -> Self {
        let recognizer = if *current == ModelState::Ready {
            Slot::Current
        } else if *previous == ModelState::Ready {
            Slot::Previous
        } else {
            Slot::None
        };
        ModelLineup { recognizer }
    }

    /// Whether to show the current model as an available upgrade.
    ///
    /// An upgrade is only an offer while the old model still works; without
    /// one, installing the current model is the ordinary first-run path.
    pub fn offers_upgrade(&self) -> bool {
        self.recognizer == Slot::Previous
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn damaged() -> ModelState {
        ModelState::NeedsRepair("missing file".into())
    }

    #[test]
    fn a_fresh_computer_has_no_recognizer_and_no_upgrade_to_offer() {
        let lineup = ModelLineup::new(&ModelState::NotInstalled, &ModelState::NotInstalled);
        assert_eq!(lineup.recognizer, Slot::None);
        assert!(!lineup.offers_upgrade());
    }

    #[test]
    fn the_previous_model_keeps_dictating_until_the_current_one_is_installed() {
        // The current model's state on a computer that holds the previous
        // file is "needs repair" where the two share a folder, and "not
        // installed" where they do not.
        for current in [ModelState::NotInstalled, damaged()] {
            let lineup = ModelLineup::new(&current, &ModelState::Ready);
            assert_eq!(lineup.recognizer, Slot::Previous, "{current:?}");
            assert!(lineup.offers_upgrade(), "{current:?}");
        }
    }

    #[test]
    fn the_current_model_takes_over_once_it_is_ready() {
        for previous in [ModelState::Ready, ModelState::NotInstalled, damaged()] {
            let lineup = ModelLineup::new(&ModelState::Ready, &previous);
            assert_eq!(lineup.recognizer, Slot::Current, "{previous:?}");
            assert!(!lineup.offers_upgrade(), "{previous:?}");
        }
    }

    #[test]
    fn a_damaged_previous_model_is_never_used() {
        for current in [ModelState::NotInstalled, damaged()] {
            let lineup = ModelLineup::new(&current, &damaged());
            assert_eq!(lineup.recognizer, Slot::None, "{current:?}");
            assert!(!lineup.offers_upgrade(), "{current:?}");
        }
    }
}

//! Lock-free admission for global hotkey gestures.
//!
//! The operating-system keyboard callback may never wait for capture, model
//! loading, recognition, disk I/O, or paste. It only changes this tiny state and
//! sends work to the lifecycle thread. A press that arrives while the previous
//! take is being processed is rejected here, at the time it happens, rather
//! than sitting in a queue and unexpectedly starting a recording later.

use std::sync::atomic::{AtomicU8, Ordering};

const IDLE: u8 = 0;
const CAPTURING: u8 = 1;
const PROCESSING: u8 = 2;

pub struct Gate {
    state: AtomicU8,
}

impl Gate {
    pub const fn new() -> Self {
        Self {
            state: AtomicU8::new(IDLE),
        }
    }

    pub fn admit_press(&self) -> bool {
        self.state
            .compare_exchange(IDLE, CAPTURING, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub fn admit_release(&self) -> bool {
        self.state
            .compare_exchange(CAPTURING, PROCESSING, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
    }

    pub fn admit_cancel(&self) -> bool {
        self.admit_release()
    }

    pub fn finish(&self) {
        self.state.store(IDLE, Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_press_during_recognition_is_rejected_instead_of_queued() {
        let gate = Gate::new();
        assert!(gate.admit_press());
        assert!(gate.admit_release());
        assert!(!gate.admit_press());
        gate.finish();
        assert!(gate.admit_press());
    }

    #[test]
    fn a_failed_start_and_a_cancel_both_reopen_admission() {
        let gate = Gate::new();
        assert!(gate.admit_press());
        gate.finish();
        assert!(gate.admit_press());
        assert!(gate.admit_cancel());
        gate.finish();
        assert!(gate.admit_press());
    }

    #[test]
    fn release_and_cancel_are_only_admitted_for_a_live_take() {
        let gate = Gate::new();
        assert!(!gate.admit_release());
        assert!(!gate.admit_cancel());
        assert!(gate.admit_press());
        assert!(gate.admit_release());
        assert!(!gate.admit_release());
        assert!(!gate.admit_cancel());
    }
}

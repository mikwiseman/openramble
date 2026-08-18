//! What the recognizer is running on, in words a person can act on.
//!
//! A fallback to the CPU is the difference between a two-second transcription
//! and a twenty-second one. Discovering that by feel, over weeks, is exactly the
//! experience this product exists to avoid — so when it happens it is stated.

use transcribe_cpp::{Backend, Model};

/// Which accelerators this build could use at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Compiled {
    pub metal: bool,
    pub vulkan: bool,
}

impl Compiled {
    pub fn current() -> Self {
        Compiled {
            metal: cfg!(target_os = "macos"),
            vulkan: !cfg!(target_os = "macos"),
        }
    }
}

/// What was asked for, what was got, and why they differ.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendReport {
    pub compiled: Compiled,
    pub requested: Backend,
    pub active: Backend,
    /// The device the runtime actually chose, as it names it — "Metal",
    /// "Vulkan0", "CPU".
    pub device: String,
}

impl BackendReport {
    pub(crate) fn new(requested: Backend, model: &Model, active: Backend) -> Self {
        BackendReport {
            compiled: Compiled::current(),
            requested,
            active,
            device: model.backend(),
        }
    }

    /// Did the recognizer end up somewhere other than where it was sent?
    pub fn is_fallback(&self) -> bool {
        self.requested != self.active
    }

    /// One line for the interface. `None` when everything is as intended —
    /// a message that appears when nothing is wrong stops being read.
    pub fn notice(&self) -> Option<String> {
        if !self.is_fallback() {
            return None;
        }
        Some(format!(
            "Running on the processor rather than the graphics card ({}). \
             Dictation still works, but it will be slower.",
            self.device
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(requested: Backend, active: Backend) -> BackendReport {
        BackendReport {
            compiled: Compiled::current(),
            requested,
            active,
            device: "CPU".into(),
        }
    }

    #[test]
    fn the_expected_case_says_nothing() {
        // A notice shown when nothing is wrong is a notice nobody reads.
        let fine = report(Backend::Metal, Backend::Metal);
        assert!(!fine.is_fallback());
        assert!(fine.notice().is_none());
    }

    #[test]
    fn a_demotion_to_the_processor_is_stated_plainly() {
        let fell_back = report(Backend::Vulkan, Backend::Cpu);
        assert!(fell_back.is_fallback());
        let notice = fell_back.notice().expect("a fallback must be announced");
        assert!(notice.contains("slower"), "{notice}");
        // Plain language: no backend jargon in the sentence a person reads.
        assert!(!notice.contains("Vulkan"), "{notice}");
    }

    #[test]
    fn each_platform_compiles_the_accelerator_it_can_use() {
        let compiled = Compiled::current();
        assert_eq!(compiled.metal, cfg!(target_os = "macos"));
        assert_eq!(compiled.vulkan, !cfg!(target_os = "macos"));
    }
}

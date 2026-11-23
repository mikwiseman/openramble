//! What the recognizer is running on, in words a person can act on.
//!
//! The engine picks its kernels for the processor it finds. On a processor
//! without the instructions the fast ones need it still recognizes, several
//! times more slowly. Discovering that by feel, over weeks, is exactly the
//! experience this product exists to avoid — so when it happens it is stated.

/// The processor kernels the engine chose, and how many threads it runs on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackendReport {
    /// The engine's own name for its kernel set: "avx2", "avx512",
    /// "avx512+avx2" or "neon" for the fast ones, "sse" or "generic" for a
    /// processor that has none of them.
    pub kernels: String,
    pub threads: usize,
}

impl BackendReport {
    /// Is this processor one the fast kernels cannot run on?
    pub fn is_slow_path(&self) -> bool {
        matches!(self.kernels.as_str(), "sse" | "generic")
    }

    /// One line for the interface. `None` when everything is as intended —
    /// a message that appears when nothing is wrong stops being read.
    pub fn notice(&self) -> Option<String> {
        self.is_slow_path().then(|| {
            "This processor is older than the ones the recognizer is tuned for. \
             Dictation still works, but it will be slower."
                .to_string()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(kernels: &str) -> BackendReport {
        BackendReport {
            kernels: kernels.into(),
            threads: 4,
        }
    }

    #[test]
    fn the_expected_case_says_nothing() {
        // A notice shown when nothing is wrong is a notice nobody reads.
        for kernels in ["avx2", "avx512", "avx512+avx2", "neon"] {
            assert!(report(kernels).notice().is_none(), "{kernels}");
        }
    }

    #[test]
    fn a_processor_without_the_fast_kernels_is_stated_plainly() {
        for kernels in ["sse", "generic"] {
            let notice = report(kernels)
                .notice()
                .expect("the slow path must be announced");
            assert!(notice.contains("slower"), "{notice}");
            // Plain language: no kernel names in the sentence a person reads.
            assert!(!notice.contains(kernels), "{notice}");
        }
    }
}

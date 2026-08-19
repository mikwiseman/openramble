//! One dictation, from the key going down to the text landing.
//!
//! The order of the steps and the decisions between them belong to `ramble-core`
//! and `ramble-text`; this is the part that calls a microphone and a keyboard.
//! Keeping the sequence here readable matters more than keeping it short — this
//! is where a person's words can be dropped.

/// What a finished dictation produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// The text was inserted.
    ///
    /// Carries nothing. No consumer needs the transcript, and a payload that
    /// exists is a payload something will eventually log — which is the one
    /// thing this product must never do with what a person said.
    Inserted,
    /// The key was brushed and nothing was said. Nothing is shown: the person
    /// changed their mind, and an error would only alarm them.
    DroppedSilently,
    /// The key was held but the microphone gave nothing. Worth saying — the
    /// input is muted, dead, or held by another application.
    SilentInput,
    /// The text was inserted, but the recording had hit the ceiling and was cut
    /// short. Worth saying, because the person's last words are missing.
    Truncated,
    /// Something failed, in words a person can act on.
    Failed(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The outcomes are what the runner reports; the decisions behind them live
    /// in `ramble_core::session::SessionMachine`, tested there. This file used
    /// to duplicate those rules, which meant two places to change and one to
    /// forget.
    #[test]
    fn every_outcome_is_distinguishable() {
        assert_ne!(Outcome::Inserted, Outcome::Truncated);
        assert_ne!(Outcome::DroppedSilently, Outcome::SilentInput);
        assert_ne!(Outcome::Failed("a".into()), Outcome::Failed("b".into()));
    }
}

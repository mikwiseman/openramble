//! The text pipeline: everything between what the recognizer heard and what the
//! person sees appear in their application.
//!
//! Ported from `Packages/DictationCore`. Pure functions throughout — no I/O, no
//! clock, no platform. The Swift sources and their tests are the specification;
//! where this port departs from them, the reason is written at the departure.

pub mod dictionary;
pub mod phonetic;
pub mod pipeline;
pub mod polish;
pub mod span;
pub mod typography;

pub use pipeline::{Output, Provenance, Run, TextPipeline, TrailingCommand};
pub use span::{detect, ProtectedSpan, SpanKind};

//! Turning what the microphone gave us into what the recognizer needs.
//!
//! Recording devices hand back whatever rate and channel count they like; the
//! engine wants 16 kHz mono. This crate owns that conversion, the WAV file the
//! history keeps, and the two containment rules that stop a recording from
//! becoming a problem — a cap on how long one take may run, and a floor on how
//! short a clip may be before the engine sees it.
//!
//! No device access here. Samples arrive as slices from whichever platform
//! adapter captured them, which is what makes all of this testable without a
//! microphone attached.

pub mod prepare;
pub mod resample;
pub mod wav;

pub use prepare::{prepare_for_engine, ENGINE_SAMPLE_RATE, MINIMUM_ENGINE_SAMPLES};
pub use resample::{resample, ResampleError};
pub use wav::{read_wav, write_wav, WavError};

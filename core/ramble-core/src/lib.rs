//! Platform-independent dictation logic shared by every OpenRamble app.
//!
//! This crate is the one place a behavioural rule is written down. macOS reaches
//! it through UniFFI, the Tauri desktop app links it directly, and the
//! conformance fixtures in `core/conformance/` are run against both so neither
//! can drift from the other.
//!
//! Nothing here performs I/O: no files, no audio devices, no network, no clock
//! of its own. Time arrives as a parameter and effects leave as values, which is
//! what makes the whole thing testable without a machine attached.

pub mod hotkey;
pub mod session;

//! Installing a model, and knowing whether one is installed.
//!
//! This crate owns the rules — the on-disk layout, verification, crash-safe
//! promotion — and no network code whatsoever. Bytes arrive in a staging
//! directory that somebody else filled, which is what lets a Tauri shell using
//! reqwest and a Swift shell using URLSession share one definition of what an
//! install is.

pub mod layout;
pub mod manifest;
pub mod marker;
pub mod store;

pub use layout::InstallLayout;
pub use manifest::{Manifest, ManifestFile, Source};
pub use marker::{ReadyMarker, ReferenceDate};
pub use store::{ModelState, ModelStore, StoreError};

//! Everything that touches a specific operating system.
//!
//! Each module keeps its platform code at the edge and its decisions in a plain
//! type that can be tested without the platform present.

pub mod capture;
pub mod hotkey;
pub mod inject;

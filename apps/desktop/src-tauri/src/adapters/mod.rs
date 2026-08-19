//! Everything that touches a specific operating system.
//!
//! Each module keeps its platform code at the edge and its decisions in a plain
//! type that can be tested without the platform present.

pub mod capture;
pub mod download;
pub mod hotkey;
pub mod inject;

// Compiled everywhere, not just on Linux. The decisions in it are pure and the
// tests are the point — gating the module would mean the table that decides
// whether a person can dictate at all is only ever checked on one runner. That
// is the mistake the Windows clipboard code already made once.
pub mod linux_session;

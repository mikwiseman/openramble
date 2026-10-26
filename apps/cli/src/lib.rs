//! The Linux tool and transcription server on the shared Rust core.
//!
//! One decoder, one planner and one engine pool, shared by file mode
//! (`openramble FILE…`) and the server (`openramble serve`).

// No raw system calls: a socket can only be the listener in listen.rs.
#![forbid(unsafe_code)]

pub mod decode;
pub mod engines;
pub mod http;
pub mod listen;
pub mod model;
pub mod output;
pub mod plan;
pub mod pool;
pub mod schedule;
pub mod scribe;
pub mod serve;
pub mod verbatim;

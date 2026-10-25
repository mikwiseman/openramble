//! The Linux tool and transcription server on the shared Rust core.
//!
//! One decoder, one planner and one engine pool, shared by file mode
//! (`openramble FILE…`) and the server (`openramble serve`).

pub mod decode;
pub mod plan;
pub mod pool;
pub mod schedule;

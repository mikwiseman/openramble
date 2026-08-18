//! The hold-to-talk gesture, independent of how any platform reports keys.

pub mod gesture;

pub use gesture::{Action, GestureMachine, ModifierEvent, DEFAULT_DOUBLE_TAP_WINDOW};

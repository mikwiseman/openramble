//! What the Windows and Linux app tells the person on this computer, without
//! the window: the sentence the settings window shows about the processor, and
//! what a press of the dictation key does.
//!
//! Proof-only: lives on the proof branch for the processor check, not in the
//! product.

use openramble_desktop_lib::dictation::{processor_notice, Dictation};

fn main() {
    let dictation = Dictation::new().expect("a place to keep files");
    match dictation.unsupported_processor() {
        Some(unsupported) => println!("settings window: {}", processor_notice(unsupported)),
        None => println!("settings window: nothing about the processor"),
    }
    match dictation.begin(|| println!("dictation key: a take starts")) {
        Ok(()) => dictation.cancel(),
        Err(reason) => println!("dictation key: no take. {reason}"),
    }
    dictation.shutdown();
}

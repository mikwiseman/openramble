//! OpenRamble on Windows and Linux.
//!
//! The shell. Every rule it follows comes from the `ramble-*` crates, which the
//! macOS app shares; what lives here is the wiring to one platform's microphone,
//! keyboard and clipboard.

pub mod adapters;
pub mod session;

/// Start the application.
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .run(tauri::generate_context!())
        .expect("the application could not start");
}

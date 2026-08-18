// A dictation tool has no business opening a console window on Windows every
// time it starts.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    openramble_desktop_lib::run()
}

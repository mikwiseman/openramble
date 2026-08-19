//! OpenRamble on Windows and Linux.
//!
//! The shell. Every rule it follows comes from the `ramble-*` crates that the
//! macOS app will share; what lives here is the wiring to one platform's
//! microphone, keyboard and clipboard.

pub mod adapters;
pub mod commands;
pub mod dictation;
pub mod session;

use adapters::hotkey::{Hotkey, HotkeyTracker};
use dictation::Dictation;
use ramble_core::hotkey::Action;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

/// Listen for the dictation key and run a take for each gesture.
///
/// rdev's listener never returns, so it owns a thread of its own. Everything it
/// decides comes from [`HotkeyTracker`]; this closure only turns an action into
/// a call.
fn spawn_hotkey_listener(dictation: Arc<Dictation>, hotkey: Hotkey) {
    std::thread::spawn(move || {
        let origin = Instant::now();
        let tracker = Mutex::new(HotkeyTracker::new(hotkey));
        // When the press happened, so a release can say how long the key was
        // held — which is what separates "brushed the key" from "held it and the
        // microphone gave nothing".
        let pressed_at = Mutex::new(None::<Instant>);

        let result = rdev::listen(move |event| {
            let at = origin.elapsed();
            let action = {
                let mut tracker = tracker
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                match event.event_type {
                    rdev::EventType::KeyPress(key) => tracker.key_down(key, at),
                    rdev::EventType::KeyRelease(key) => tracker.key_up(key, at),
                    _ => Action::None,
                }
            };

            let mut held_since = pressed_at
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());

            match action {
                Action::Press => {
                    *held_since = Some(Instant::now());
                    if let Err(error) = dictation.begin() {
                        eprintln!("{error}");
                        *held_since = None;
                    }
                }
                Action::Release { .. } => {
                    // `after` is the double-tap window a short tap should wait
                    // out before committing. Hands-free is not wired yet, so the
                    // take finishes immediately and the window is unused —
                    // stated rather than silently dropped, because a release
                    // that quietly did nothing is the bug this whole gesture
                    // machine exists to prevent.
                    let held = held_since.take().map(|at| at.elapsed()).unwrap_or_default();
                    let outcome = dictation.finish(held);
                    report(&outcome);
                }
                Action::AbortShortcut => {
                    // The hold turned out to be a shortcut. Drop the recording
                    // without inserting or announcing anything.
                    *held_since = None;
                    dictation.cancel();
                }
                Action::DoubleTap | Action::StopHandsFree | Action::None => {}
            }
        });

        if let Err(error) = result {
            // Almost always a missing permission: Accessibility on macOS, or an
            // X11 display the process cannot reach. Without this the app looks
            // installed and simply never responds to the key.
            eprintln!(
                "The dictation key cannot be watched ({error:?}). \
                 Check that OpenRamble is allowed to monitor input."
            );
        }
    });
}

fn report(outcome: &session::Outcome) {
    match outcome {
        session::Outcome::Inserted => {}
        session::Outcome::Truncated => {
            eprintln!("The recording reached the ten-minute limit and was cut short.")
        }
        session::Outcome::SilentInput => eprintln!(
            "Nothing was recorded. The microphone may be muted or in use by another application."
        ),
        session::Outcome::DroppedSilently => {}
        session::Outcome::Failed(error) => eprintln!("{error}"),
    }
}

/// Start the application.
pub fn run() {
    let Some(dictation) = Dictation::new() else {
        eprintln!("OpenRamble could not find a place to keep its files.");
        return;
    };
    let dictation = Arc::new(dictation);

    spawn_hotkey_listener(Arc::clone(&dictation), Hotkey::default());

    let for_setup = Arc::clone(&dictation);
    let for_exit = Arc::clone(&dictation);

    tauri::Builder::default()
        // First, before anything else registers: a second copy must not get as
        // far as opening a microphone.
        //
        // Two instances of a tray application is not a cosmetic problem. Each
        // one watches the dictation key, so a single press starts two
        // recordings; each loads its own copy of the model, which is about
        // 1.5 GB between them; and both race to write the clipboard, so what
        // gets pasted is whichever finished last. Launching a second time now
        // surfaces the window of the copy already running, which is what a
        // person meant by launching it anyway.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            present_settings(app);
        }))
        // Off by default. A dictation tool that installs itself into startup
        // without being asked is the kind of thing people uninstall.
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(tauri_plugin_opener::init())
        .manage(Arc::clone(&dictation))
        .invoke_handler(tauri::generate_handler![
            commands::model_report,
            commands::dictation_hotkey,
            commands::session_notices,
            commands::dictation_history,
            commands::delete_history_entry,
            commands::clear_history,
            commands::dictionary,
            commands::set_dictionary,
            commands::start_at_login,
            commands::set_start_at_login,
            commands::install_model,
            commands::cancel_install,
        ])
        .setup(move |app| {
            let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit OpenRamble", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;

            let handle = app.handle().clone();
            let dictation = Arc::clone(&for_setup);
            TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().unwrap().clone())
                .icon_as_template(true)
                .tooltip(tray_tooltip(&dictation))
                .menu(&menu)
                // The menu opens on a left click, and it holds the only route
                // to settings. On a platform where showing a window from a
                // background process is restricted, that route has to exist
                // more than one way.
                .show_menu_on_left_click(true)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "settings" => present_settings(app),
                    "quit" => {
                        // Explicitly, before Tauri tears the process down: ggml
                        // aborts at exit() with a model still loaded.
                        dictation.shutdown();
                        app.exit(0);
                    }
                    _ => {}
                })
                .build(&handle)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the settings window hides it. This is a tray application;
            // quitting is done from the tray, and a stray window close must not
            // take dictation away with it.
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .build(tauri::generate_context!())
        .expect("the application could not start")
        .run(move |_app, event| {
            if let tauri::RunEvent::Exit = event {
                for_exit.shutdown();
            }
        });
}

/// Bring the settings window in front of the person.
///
/// Three steps, not one. A window can be hidden, minimised, or merely behind
/// something, and Windows in particular treats those as separate states — asking
/// only for `show` leaves a minimised window minimised, which looks exactly like
/// a menu item that does nothing.
///
/// Failures are reported rather than discarded. This is the only way to reach
/// settings, so if it cannot be done the person needs to know that rather than
/// clicking a dead menu item twice and giving up.
fn present_settings(app: &tauri::AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        eprintln!("The settings window is missing and cannot be shown.");
        return;
    };
    if let Err(error) = window
        .unminimize()
        .and_then(|()| window.show())
        .and_then(|()| window.set_focus())
    {
        eprintln!("The settings window could not be shown: {error}");
    }
}

/// What the tray says about itself.
fn tray_tooltip(dictation: &Dictation) -> String {
    if dictation.model_is_ready() {
        format!("OpenRamble — hold {} to dictate", Hotkey::default().title())
    } else {
        "OpenRamble — the speech model is not installed yet".into()
    }
}

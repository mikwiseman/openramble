//! OpenRamble on Windows and Linux.
//!
//! The shell. Every rule it follows comes from the `ramble-*` crates that the
//! macOS app will share; what lives here is the wiring to one platform's
//! microphone, keyboard and clipboard.

pub mod adapters;
pub mod commands;
pub mod dictation;
mod lifecycle;
pub mod session;

use adapters::hotkey::{Hotkey, HotkeyTracker};
use dictation::Dictation;
use lifecycle::Gate;
use ramble_core::hotkey::Action;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Instant;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

/// Listen for the dictation key and run a take for each gesture.
///
/// rdev's listener never returns, so it owns a thread of its own. Everything it
/// decides comes from [`HotkeyTracker`]; this closure only turns an action into
/// a call.
enum LifecycleCommand {
    Begin,
    Finish(std::time::Duration),
    Cancel,
}

struct ReopenOnDrop(Arc<Gate>);

impl Drop for ReopenOnDrop {
    fn drop(&mut self) {
        self.0.finish();
    }
}

fn spawn_hotkey_listener(app: tauri::AppHandle, dictation: Arc<Dictation>, hotkey: Hotkey) {
    let gate = Arc::new(Gate::new());
    let (commands, work) = mpsc::sync_channel(8);

    let worker_gate = Arc::clone(&gate);
    std::thread::Builder::new()
        .name("openramble-lifecycle".into())
        .spawn(move || {
            while let Ok(command) = work.recv() {
                match command {
                    LifecycleCommand::Begin => {
                        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            dictation.begin()
                        })) {
                            Ok(Ok(())) => {}
                            Ok(Err(error)) => {
                                eprintln!("{error}");
                                worker_gate.finish();
                            }
                            Err(_) => {
                                eprintln!("The dictation start task stopped unexpectedly.");
                                worker_gate.finish();
                            }
                        }
                    }
                    LifecycleCommand::Finish(held) => {
                        let _reopen = ReopenOnDrop(Arc::clone(&worker_gate));
                        let app = app.clone();
                        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            dictation.finish_with(held, move |text| {
                                insert_on_main_thread(&app, text.to_owned())
                            })
                        })) {
                            Ok(outcome) => report(&outcome),
                            Err(_) => {
                                eprintln!("The dictation processing task stopped unexpectedly.")
                            }
                        }
                    }
                    LifecycleCommand::Cancel => {
                        let _reopen = ReopenOnDrop(Arc::clone(&worker_gate));
                        if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            dictation.cancel()
                        }))
                        .is_err()
                        {
                            eprintln!("The dictation cancellation task stopped unexpectedly.");
                        }
                    }
                }
            }
        })
        .expect("the dictation lifecycle thread could not start");

    if let Err(error) = std::thread::Builder::new()
        .name("openramble-hotkey".into())
        .spawn(move || {
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
                        if gate.admit_press() {
                            *held_since = Some(Instant::now());
                            if commands.try_send(LifecycleCommand::Begin).is_err() {
                                *held_since = None;
                                gate.finish();
                                eprintln!("The dictation lifecycle queue is unavailable.");
                            }
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
                        if gate.admit_release()
                            && commands.try_send(LifecycleCommand::Finish(held)).is_err()
                        {
                            gate.finish();
                            eprintln!("The dictation lifecycle queue is unavailable.");
                        }
                    }
                    Action::AbortShortcut => {
                        // The hold turned out to be a shortcut. Drop the recording
                        // without inserting or announcing anything.
                        *held_since = None;
                        if gate.admit_cancel()
                            && commands.try_send(LifecycleCommand::Cancel).is_err()
                        {
                            gate.finish();
                            eprintln!("The dictation lifecycle queue is unavailable.");
                        }
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
        })
    {
        eprintln!("The dictation hotkey listener could not start: {error}");
    }
}

/// Clipboard and synthetic keyboard APIs are AppKit work on macOS. Schedule
/// them on Tauri's main thread and carry the exact result back to the lifecycle
/// worker; recognition never occupies the UI thread, and paste failures are not
/// hidden.
fn insert_on_main_thread(app: &tauri::AppHandle, text: String) -> Result<(), String> {
    let (result_tx, result_rx) = mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let result = adapters::inject::insert(&text).map_err(|error| error.to_string());
        if result_tx.send(result).is_err() {
            eprintln!("The insertion result receiver stopped before paste completed.");
        }
    })
    .map_err(|error| format!("The text could not be scheduled for insertion: {error}"))?;
    result_rx
        .recv()
        .map_err(|_| "The insertion result was lost before it could be reported.".to_string())?
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
    let dictation = match Dictation::new() {
        Ok(dictation) => dictation,
        Err(error) => {
            eprintln!("OpenRamble could not start: {error}");
            return;
        }
    };
    let dictation = Arc::new(dictation);

    let for_setup = Arc::clone(&dictation);
    let for_exit = Arc::clone(&dictation);

    let builder = tauri::Builder::default();
    #[cfg(target_os = "macos")]
    let builder = builder.plugin(tauri_plugin_sparkle_updater::init());

    builder
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
            commands::copy_history_text,
            commands::dictionary,
            commands::set_dictionary,
            commands::start_at_login,
            commands::set_start_at_login,
            commands::install_model,
            commands::cancel_install,
            commands::check_for_updates,
        ])
        .setup(move |app| {
            spawn_hotkey_listener(
                app.handle().clone(),
                Arc::clone(&for_setup),
                Hotkey::default(),
            );
            let settings = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit OpenRamble", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&settings, &quit])?;

            // The system's own blur behind the window. Painting a picture of
            // glass onto an opaque background reads as flat the instant
            // anything moves behind it; this is the real thing, sampled live
            // from whatever is underneath.
            if let Some(window) = app.get_webview_window("main") {
                apply_glass(&window);
            }

            let handle = app.handle().clone();
            let dictation = Arc::clone(&for_setup);
            let icon = app
                .default_window_icon()
                .ok_or("The packaged application icon is missing.")?
                .clone();
            TrayIconBuilder::with_id("main")
                .icon(icon)
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
                if let Err(error) = window.hide() {
                    eprintln!("The settings window could not be hidden: {error}");
                }
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

/// Put real material behind the window.
///
/// Each platform has its own, and they are not interchangeable: macOS has
/// vibrancy that samples the desktop continuously, Windows 11 has Mica and
/// Acrylic. Where none is available the window simply stays solid — the page
/// below is legible either way, because a design that becomes unreadable
/// without an effect is a design that fails on the machines that lack it.
fn apply_glass(window: &tauri::WebviewWindow) {
    #[cfg(target_os = "macos")]
    {
        use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};
        // Sidebar, and only Sidebar.
        //
        // UnderWindowBackground and HudWindow both sound like better choices for
        // a window background, and both prevent the window from being created at
        // all in this version of the crate — the app runs with no interface.
        // Recorded because the names are tempting and the failure is silent.
        //
        // Active rather than following the window's state, so the material keeps
        // sampling the desktop when the window is not frontmost instead of
        // freezing into a still image the moment somebody clicks away.
        if let Err(error) = apply_vibrancy(
            window,
            NSVisualEffectMaterial::Sidebar,
            Some(NSVisualEffectState::Active),
            Some(18.0),
        ) {
            eprintln!("The macOS window material could not be applied: {error}");
        }
    }

    #[cfg(target_os = "windows")]
    {
        use window_vibrancy::{apply_acrylic, apply_mica};
        // Mica is the Windows 11 material and the cheaper of the two; acrylic is
        // the fallback for builds without it.
        if apply_mica(window, None).is_err() {
            if let Err(error) = apply_acrylic(window, Some((18, 18, 20, 125))) {
                eprintln!("The Windows window material could not be applied: {error}");
            }
        }
    }
    #[cfg(target_os = "linux")]
    {
        // No portable equivalent: compositors differ and several offer nothing.
        // The page's own translucency carries the look there.
        let _ = window;
    }
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

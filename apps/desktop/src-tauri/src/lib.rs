//! OpenRamble on Windows and Linux.
//!
//! The shell. Every rule it follows comes from the `ramble-*` crates that the
//! macOS app will share; what lives here is the wiring to one platform's
//! microphone, keyboard and clipboard.

pub mod adapters;
pub mod commands;
pub mod dictation;
pub mod runner;
pub mod session;
pub mod take;

use adapters::block_window;
use adapters::hotkey::{Hotkey, HotkeyTracker};
use dictation::Dictation;
use ramble_core::hotkey::Action;
use runner::Runner;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use take::TakeBlock;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

/// Listen for the dictation key and run a take for each gesture.
///
/// rdev's listener never returns, so it owns a thread of its own. Everything it
/// decides comes from [`HotkeyTracker`]; this closure only turns an action into
/// a call.
fn spawn_hotkey_listener(runner: Arc<Runner>, hotkey: Hotkey) {
    std::thread::spawn(move || {
        let origin = Instant::now();
        let tracker = Mutex::new(HotkeyTracker::new(hotkey));

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

            match action {
                Action::Press => runner.key_down(false),
                // Hands-free is not wired yet, so a second tap starts
                // nothing. Over waiting words it is a tap like the first.
                Action::DoubleTap => runner.key_down(true),
                // `after` is the double-tap window a short tap should wait
                // out before committing. With no hands-free the take finishes
                // immediately and the window is unused — stated rather than
                // silently dropped, because a release that quietly did nothing
                // is the bug this whole gesture machine exists to prevent.
                Action::Release { .. } => runner.key_up(),
                // The hold turned out to be a shortcut.
                Action::AbortShortcut => runner.shortcut(),
                Action::StopHandsFree | Action::None => {}
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

/// Start the application.
pub fn run() {
    let Some(dictation) = Dictation::new() else {
        eprintln!("OpenRamble could not find a place to keep its files.");
        return;
    };
    let dictation = Arc::new(dictation);

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
            commands::take_block,
            commands::take_block_fits,
            commands::take_block_act,
            commands::take_block_later,
        ])
        .setup(move |app| {
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

            // The take block, and the key that drives it. The window is made
            // before the key is watched, so the first take has somewhere to
            // be shown. If it cannot be made, dictation still works: the
            // words land as they did before there was a block.
            if let Err(error) = block_window::create(app.handle()) {
                eprintln!("The take block could not be created: {error}");
            }
            let for_block = app.handle().clone();
            let block = TakeBlock::new(move |block| block_window::draw(&for_block, block));
            let runner = Runner::new(Arc::clone(&for_setup), block, Hotkey::default());
            app.manage(Arc::clone(&runner));
            spawn_hotkey_listener(runner, Hotkey::default());

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
        let _ = apply_vibrancy(
            window,
            NSVisualEffectMaterial::Sidebar,
            Some(NSVisualEffectState::Active),
            Some(18.0),
        );
    }

    #[cfg(target_os = "windows")]
    {
        use window_vibrancy::{apply_acrylic, apply_mica};
        // Mica is the Windows 11 material and the cheaper of the two; acrylic is
        // the fallback for builds without it.
        if apply_mica(window, None).is_err() {
            let _ = apply_acrylic(window, Some((18, 18, 20, 125)));
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

//! What the settings window can ask for.
//!
//! Kept small on purpose. Every command here is a question a person asked by
//! clicking something; nothing polls, and nothing runs on its own.

use crate::adapters::download;
use crate::adapters::hotkey::Hotkey;
use crate::adapters::inject;
use crate::dictation::Dictation;
use ramble_model::ModelState;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::{Emitter, State};

/// How the model looks to the settings window.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelReport {
    pub ready: bool,
    /// A sentence a person can act on, or nothing when all is well.
    pub detail: Option<String>,
    /// Is something actually wrong?
    ///
    /// Distinct from `!ready`, because on a first run nothing is wrong: no model
    /// yet is simply where everyone starts. Colouring that as a fault tells a
    /// person their new install is broken, and it also spends the one signal
    /// that should mean "look at this" — so when a real repair is needed, they
    /// have already learned to ignore it.
    pub problem: bool,
    pub download_bytes: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub received: u64,
    pub total: u64,
}

/// Set while a download runs, so a second click cannot start a second one.
static DOWNLOADING: AtomicBool = AtomicBool::new(false);
/// Set to ask the running download to stop.
static CANCEL: AtomicBool = AtomicBool::new(false);

#[tauri::command]
pub async fn model_report(dictation: State<'_, Arc<Dictation>>) -> Result<ModelReport, String> {
    let dictation = Arc::clone(&dictation);
    tauri::async_runtime::spawn_blocking(move || {
        let state = dictation.model_state();
        ModelReport {
            ready: state == ModelState::Ready,
            problem: matches!(state, ModelState::NeedsRepair(_)),
            detail: match &state {
                ModelState::Ready => None,
                ModelState::NotInstalled => Some("The speech model is not installed yet.".into()),
                // Said plainly, including why, because "needs repair" alone tells a
                // person nothing about what to do next.
                ModelState::NeedsRepair(reason) => Some(format!(
                    "The installed model is not usable ({reason}). Downloading it again will fix this."
                )),
            },
            download_bytes: dictation.download_byte_count(),
        }
    })
    .await
    .map_err(|error| format!("The model status task failed: {error}"))
}

/// What this desktop session will not let the app do.
///
/// Empty on a session that can do everything. Shown in the settings window,
/// because a dictation tool that quietly does less than it claims is worse than
/// one that says so — the person cannot otherwise tell "this desktop forbids
/// it" from "I am holding the key wrong".
#[tauri::command]
pub fn session_notices() -> Vec<String> {
    #[cfg(target_os = "linux")]
    {
        crate::adapters::linux_session::detect()
            .notices()
            .into_iter()
            .map(str::to_string)
            .collect()
    }
    #[cfg(not(target_os = "linux"))]
    {
        // Windows and macOS place no comparable restrictions on a tool that has
        // been granted its permissions.
        Vec::new()
    }
}

/// A finished dictation, as the window shows it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRow {
    pub id: String,
    pub text: String,
    /// Seconds since the Unix epoch, which is what a browser understands.
    /// Stored as Foundation's own reference date; converted only here.
    pub at: f64,
    pub has_audio: bool,
}

#[tauri::command]
pub async fn dictation_history(
    dictation: State<'_, Arc<Dictation>>,
) -> Result<Vec<HistoryRow>, String> {
    let dictation = Arc::clone(&dictation);
    tauri::async_runtime::spawn_blocking(move || -> Result<Vec<HistoryRow>, String> {
        Ok(dictation
            .history_entries()
            .map_err(|error| error.to_string())?
            .into_iter()
            .map(|entry| HistoryRow {
                at: entry
                    .date
                    .to_system_time()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|since| since.as_secs_f64())
                    .unwrap_or(0.0),
                has_audio: dictation.history_has_audio(&entry),
                id: entry.id,
                text: entry.text,
            })
            .collect::<Vec<_>>())
    })
    .await
    .map_err(|error| format!("The history task failed: {error}"))?
}

#[tauri::command]
pub async fn delete_history_entry(
    dictation: State<'_, Arc<Dictation>>,
    id: String,
) -> Result<(), String> {
    let dictation = Arc::clone(&dictation);
    tauri::async_runtime::spawn_blocking(move || {
        dictation
            .delete_history_entry(&id)
            .map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| format!("The history deletion task failed: {error}"))?
}

#[tauri::command]
pub async fn clear_history(dictation: State<'_, Arc<Dictation>>) -> Result<(), String> {
    let dictation = Arc::clone(&dictation);
    tauri::async_runtime::spawn_blocking(move || {
        dictation.clear_history().map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| format!("The history deletion task failed: {error}"))?
}

/// Copy a stored transcript with the same local-only privacy markers as paste.
#[tauri::command]
pub async fn copy_history_text(app: tauri::AppHandle, text: String) -> Result<(), String> {
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    app.run_on_main_thread(move || {
        let result = inject::copy_private(&text).map_err(|error| error.to_string());
        if sender.send(result).is_err() {
            eprintln!("The history copy result could not be returned to the settings window.");
        }
    })
    .map_err(|error| format!("The history copy could not reach the main thread: {error}"))?;
    tauri::async_runtime::spawn_blocking(move || {
        receiver
            .recv()
            .map_err(|error| format!("The history copy task stopped: {error}"))?
    })
    .await
    .map_err(|error| format!("The history copy task failed: {error}"))?
}

/// A personal replacement, as the window edits it.
#[derive(Debug, Clone, serde::Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionaryRow {
    pub spoken: String,
    pub written: String,
}

#[tauri::command]
pub async fn dictionary(
    dictation: State<'_, Arc<Dictation>>,
) -> Result<Vec<DictionaryRow>, String> {
    let dictation = Arc::clone(&dictation);
    tauri::async_runtime::spawn_blocking(move || -> Result<Vec<DictionaryRow>, String> {
        Ok(dictation
            .personal_terms()
            .map_err(|error| error.to_string())?
            .into_iter()
            .map(|entry| DictionaryRow {
                spoken: entry.spoken,
                written: entry.written,
            })
            .collect())
    })
    .await
    .map_err(|error| format!("The dictionary task failed: {error}"))?
}

/// Replace the personal dictionary.
///
/// Whole-list rather than add/remove: the list is short, editing it is rare, and
/// a single write cannot leave the file half-updated the way a sequence of
/// mutations can.
#[tauri::command]
pub async fn set_dictionary(
    dictation: State<'_, Arc<Dictation>>,
    rows: Vec<DictionaryRow>,
) -> Result<(), String> {
    let dictation = Arc::clone(&dictation);
    tauri::async_runtime::spawn_blocking(move || {
        dictation
            .set_personal_terms(
                rows.into_iter()
                    .filter(|row| !row.spoken.trim().is_empty() && !row.written.trim().is_empty())
                    .map(|row| (row.spoken, row.written))
                    .collect(),
            )
            .map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| format!("The dictionary task failed: {error}"))?
}

/// Does OpenRamble start with the computer?
#[tauri::command]
pub fn start_at_login(app: tauri::AppHandle) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch()
        .is_enabled()
        .map_err(|error| error.to_string())
}

/// Turn starting with the computer on or off.
///
/// Off until asked for. A dictation tool that puts itself into startup
/// uninvited is the kind of thing people uninstall rather than configure.
#[tauri::command]
pub fn set_start_at_login(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    let manager = app.autolaunch();
    let result = if enabled {
        manager.enable()
    } else {
        manager.disable()
    };
    result.map_err(|error| error.to_string())
}

#[tauri::command]
pub fn dictation_hotkey() -> String {
    Hotkey::default().title().to_string()
}

/// Ask the native macOS Sparkle controller to present its update UI.
///
/// Existing installations and this Tauri shell share the same appcast and
/// permanent EdDSA key. Other platforms have separate package releases and do
/// not pretend this control is available.
#[tauri::command]
pub fn check_for_updates(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use tauri_plugin_sparkle_updater::SparkleUpdaterExt;
        let updater = app.sparkle_updater().ok_or_else(|| {
            "Sparkle is unavailable outside the packaged application.".to_string()
        })?;
        updater
            .check_for_updates()
            .map_err(|error| error.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Err("Sparkle updates are available only in the macOS application.".into())
    }
}

/// Download and install the model.
///
/// Runs on its own thread: this takes minutes, and a settings window frozen for
/// minutes is indistinguishable from one that has crashed.
#[tauri::command]
pub fn install_model(
    app: tauri::AppHandle,
    dictation: State<'_, Arc<Dictation>>,
) -> Result<(), String> {
    if DOWNLOADING.swap(true, Ordering::SeqCst) {
        return Err("A download is already running.".into());
    }
    CANCEL.store(false, Ordering::SeqCst);

    let dictation = Arc::clone(&dictation);
    std::thread::spawn(move || {
        let emit = app.clone();
        let result = download::install(
            dictation.store(),
            &move |received, total| {
                if let Err(error) = emit.emit("model-progress", Progress { received, total }) {
                    eprintln!("Model download progress could not be reported: {error}");
                }
            },
            &|| CANCEL.load(Ordering::SeqCst),
        );
        DOWNLOADING.store(false, Ordering::SeqCst);

        let message = match result {
            Ok(()) => None,
            Err(error) => Some(error.to_string()),
        };
        // Success and failure both reported: a download that stops saying
        // anything is the state people mistake for a hang.
        if let Err(error) = app.emit("model-finished", message) {
            eprintln!("The model download result could not be reported: {error}");
        }
    });
    Ok(())
}

#[tauri::command]
pub fn cancel_install() {
    CANCEL.store(true, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_second_download_cannot_start_while_one_is_running() {
        DOWNLOADING.store(false, Ordering::SeqCst);
        assert!(!DOWNLOADING.swap(true, Ordering::SeqCst));
        assert!(
            DOWNLOADING.swap(true, Ordering::SeqCst),
            "the second must be refused"
        );
        DOWNLOADING.store(false, Ordering::SeqCst);
    }

    #[test]
    fn cancelling_is_visible_to_the_running_download() {
        CANCEL.store(false, Ordering::SeqCst);
        assert!(!CANCEL.load(Ordering::SeqCst));
        cancel_install();
        assert!(CANCEL.load(Ordering::SeqCst));
        CANCEL.store(false, Ordering::SeqCst);
    }
}

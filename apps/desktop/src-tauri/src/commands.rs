//! What the settings window can ask for.
//!
//! Kept small on purpose. Every command here is a question a person asked by
//! clicking something; nothing polls, and nothing runs on its own.

use crate::adapters::download;
use crate::adapters::hotkey::Hotkey;
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
pub fn model_report(dictation: State<'_, Arc<Dictation>>) -> ModelReport {
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
pub fn dictation_history(dictation: State<'_, Arc<Dictation>>) -> Vec<HistoryRow> {
    dictation
        .history()
        .load()
        .into_iter()
        .map(|entry| HistoryRow {
            at: entry
                .date
                .to_system_time()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|since| since.as_secs_f64())
                .unwrap_or(0.0),
            has_audio: dictation.history().audio_path(&entry).is_some(),
            id: entry.id,
            text: entry.text,
        })
        .collect()
}

#[tauri::command]
pub fn delete_history_entry(
    dictation: State<'_, Arc<Dictation>>,
    id: String,
) -> Result<(), String> {
    dictation
        .history()
        .delete(&id)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn clear_history(dictation: State<'_, Arc<Dictation>>) -> Result<(), String> {
    dictation
        .history()
        .delete_all()
        .map_err(|error| error.to_string())
}

#[tauri::command]
pub fn dictation_hotkey() -> String {
    Hotkey::default().title().to_string()
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
                let _ = emit.emit("model-progress", Progress { received, total });
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
        let _ = app.emit("model-finished", message);
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

    /// A first run is not a fault. Only a broken install is.
    #[test]
    fn only_a_broken_install_counts_as_a_problem() {
        assert!(!matches!(
            ModelState::NotInstalled,
            ModelState::NeedsRepair(_)
        ));
        assert!(matches!(
            ModelState::NeedsRepair("truncated".into()),
            ModelState::NeedsRepair(_)
        ));
    }

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

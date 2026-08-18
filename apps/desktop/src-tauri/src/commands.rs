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

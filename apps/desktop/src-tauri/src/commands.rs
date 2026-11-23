//! What the settings window can ask for.
//!
//! Kept small on purpose. Every command here is a question a person asked by
//! clicking something; nothing polls, and nothing runs on its own.

use crate::adapters::block_window;
use crate::adapters::download;
use crate::adapters::hotkey::Hotkey;
use crate::dictation::Dictation;
use crate::runner::Runner;
use crate::take::Block;
use ramble_model::{ModelLineup, ModelState, Slot};
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
    /// The model works, and a newer file of it can be downloaded.
    pub upgrade: bool,
    pub download_bytes: i64,
}

impl ModelReport {
    /// `state` is the state of the model a download installs.
    fn new(state: &ModelState, lineup: ModelLineup, download_bytes: i64) -> Self {
        let serves = lineup.recognizer != Slot::None;
        ModelReport {
            ready: serves,
            // A computer dictating with the previous file sees the current
            // one as the wrong files. That is an offer, not a fault.
            problem: !serves && matches!(state, ModelState::NeedsRepair(_)),
            upgrade: lineup.offers_upgrade(),
            detail: match (lineup.recognizer, state) {
                (Slot::Current, _) => None,
                (Slot::Previous, _) => Some(
                    "Installed and ready. A smaller, faster version of the model is available. \
                     Dictation keeps using the installed one until the new one is ready."
                        .into(),
                ),
                // Said plainly, including why, because "needs repair" alone tells a
                // person nothing about what to do next.
                (Slot::None, ModelState::NeedsRepair(reason)) => Some(format!(
                    "The installed model is not usable ({reason}). Downloading it again will fix this."
                )),
                (Slot::None, _) => Some("The speech model is not installed yet.".into()),
            },
            download_bytes,
        }
    }
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
    ModelReport::new(
        &dictation.model_state(),
        dictation.lineup(),
        dictation.download_byte_count(),
    )
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

/// A personal replacement, as the window edits it.
#[derive(Debug, Clone, serde::Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DictionaryRow {
    pub spoken: String,
    pub written: String,
}

#[tauri::command]
pub fn dictionary(dictation: State<'_, Arc<Dictation>>) -> Vec<DictionaryRow> {
    dictation
        .personal_terms()
        .into_iter()
        .map(|entry| DictionaryRow {
            spoken: entry.spoken,
            written: entry.written,
        })
        .collect()
}

/// Replace the personal dictionary.
///
/// Whole-list rather than add/remove: the list is short, editing it is rare, and
/// a single write cannot leave the file half-updated the way a sequence of
/// mutations can.
#[tauri::command]
pub fn set_dictionary(
    dictation: State<'_, Arc<Dictation>>,
    rows: Vec<DictionaryRow>,
) -> Result<(), String> {
    dictation
        .set_personal_terms(
            rows.into_iter()
                .filter(|row| !row.spoken.trim().is_empty() && !row.written.trim().is_empty())
                .map(|row| (row.spoken, row.written))
                .collect(),
        )
        .map_err(|error| error.to_string())
}

/// Does OpenRamble start with the computer?
#[tauri::command]
pub fn start_at_login(app: tauri::AppHandle) -> bool {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().unwrap_or(false)
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
        let result = download::fetch(
            dictation.store(),
            &move |received, total| {
                let _ = emit.emit("model-progress", Progress { received, total });
            },
            &|| CANCEL.load(Ordering::SeqCst),
        )
        .and_then(|staging| {
            dictation
                .install(&staging)
                .map_err(|error| download::DownloadError::Corrupt(error.to_string()))
        });
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

/// What the take block shows now.
///
/// Asked once, by the block's page when it loads: a take that began before
/// the page was ready is drawn as soon as it is.
#[tauri::command]
pub fn take_block(runner: State<'_, Arc<Runner>>) -> Block {
    runner.block()
}

/// The page drew the block, and this is the size it came to.
#[tauri::command]
pub fn take_block_fits(
    app: tauri::AppHandle,
    runner: State<'_, Arc<Runner>>,
    width: f64,
    height: f64,
) {
    // A take can end while the page is still drawing it. Showing the window
    // then would leave a block on the screen with nothing to remove it.
    if runner.block() != Block::Hidden {
        block_window::fit(&app, width, height);
    }
}

/// A click on the block's own button: what a tap of the dictation key does.
#[tauri::command]
pub fn take_block_act(runner: State<'_, Arc<Runner>>) {
    runner.act();
}

/// A click on Later.
#[tauri::command]
pub fn take_block_later(runner: State<'_, Arc<Runner>>) {
    runner.later();
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

    /// A computer that holds the Q8_0 file 0.42.1 downloaded: the current
    /// model's own state says the folder holds the wrong files.
    #[test]
    fn a_working_previous_model_is_ready_with_an_offer_and_no_fault() {
        let wrong_files = ModelState::NeedsRepair("different model files".into());
        let lineup = ModelLineup::new(&wrong_files, &ModelState::Ready);
        let report = ModelReport::new(&wrong_files, lineup, 486_280_096);
        assert!(report.ready);
        assert!(report.upgrade);
        assert!(!report.problem);
        assert!(report.detail.unwrap().starts_with("Installed and ready."));
        assert_eq!(report.download_bytes, 486_280_096);
    }

    #[test]
    fn the_current_model_is_ready_with_nothing_to_offer() {
        let lineup = ModelLineup::new(&ModelState::Ready, &ModelState::NotInstalled);
        let report = ModelReport::new(&ModelState::Ready, lineup, 486_280_096);
        assert!(report.ready && !report.upgrade && !report.problem);
        assert_eq!(report.detail, None);
    }

    #[test]
    fn with_no_working_model_a_first_run_is_no_fault_and_a_damaged_install_is() {
        let fresh = ModelLineup::new(&ModelState::NotInstalled, &ModelState::NotInstalled);
        let report = ModelReport::new(&ModelState::NotInstalled, fresh, 1);
        assert!(!report.ready && !report.upgrade && !report.problem);

        let cut = ModelState::NeedsRepair("truncated".into());
        let report = ModelReport::new(&cut, ModelLineup::new(&cut, &cut), 1);
        assert!(!report.ready && !report.upgrade && report.problem);
        assert!(report.detail.unwrap().contains("truncated"));
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

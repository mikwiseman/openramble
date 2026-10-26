//! One owner of the engines per machine: the server, or file-mode runs.
//!
//! An engine takes about 1.15 GB on transcribe.cpp 0.2.0, so on an 8 GB
//! machine the server's four and a file-mode run's three do not fit, and the
//! kernel kills the largest process, the server. A lock file decides who may
//! load them. A file-mode run holds it shared for as long as its engines live
//! and refuses to start while the server holds it. The server holds it
//! exclusively for its life, and before loading waits for file-mode runs that
//! started first. Without the file, as on a desktop or a development machine,
//! there is nothing to coordinate and both go ahead. `install.sh` makes it.

use std::fs::{File, TryLockError};
use std::io::ErrorKind;
use std::path::Path;
use std::time::Duration;

/// Where the machine's engine lock lives.
pub const LOCK: &str = "/var/lib/openramble/engines.lock";

/// Opened for reading, which is all a lock needs, so neither side needs
/// write access to it.
fn open(path: &Path) -> Result<Option<File>, String> {
    match File::open(path) {
        Ok(file) => Ok(Some(file)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("cannot open {}: {error}", path.display())),
    }
}

/// The lock for a file-mode run, held until the returned file is dropped.
pub fn share(path: &Path) -> Result<Option<File>, String> {
    let Some(file) = open(path)? else {
        return Ok(None);
    };
    match file.try_lock_shared() {
        Ok(()) => Ok(Some(file)),
        Err(TryLockError::WouldBlock) => Err(
            "the OpenRamble server on this machine holds the engines, and more next to \
             them would not fit in memory; send the file to the server instead, for example \
             through /opt/openramble/bin/transcribe-stdin"
                .into(),
        ),
        Err(TryLockError::Error(error)) => Err(format!("cannot lock {}: {error}", path.display())),
    }
}

/// The lock for the server, held until the returned file is dropped. Waits
/// while file-mode runs hold it, saying so once through `log`, and gives up
/// when `stop()` turns true.
pub fn own(
    path: &Path,
    stop: &dyn Fn() -> bool,
    log: &dyn Fn(&str),
) -> Result<Option<File>, String> {
    let Some(file) = open(path)? else {
        return Ok(None);
    };
    let mut said = false;
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(Some(file)),
            Err(TryLockError::WouldBlock) => {
                if stop() {
                    return Err("stopped while waiting for a file-mode run to finish".into());
                }
                if !said {
                    log("waiting for a file-mode run on this machine to finish before loading the engines");
                    said = true;
                }
                std::thread::sleep(Duration::from_millis(250));
            }
            Err(TryLockError::Error(error)) => {
                return Err(format!("cannot lock {}: {error}", path.display()))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    fn lock_file() -> (tempfile::TempDir, std::path::PathBuf) {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("engines.lock");
        std::fs::write(&path, b"").unwrap();
        (directory, path)
    }

    #[test]
    fn without_the_file_there_is_nothing_to_coordinate() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("absent");
        assert!(share(&path).unwrap().is_none());
        assert!(own(&path, &|| false, &|_| {}).unwrap().is_none());
    }

    #[test]
    fn a_file_mode_run_is_refused_while_the_server_holds_the_engines() {
        let (_directory, path) = lock_file();
        let server = own(&path, &|| false, &|_| {}).unwrap();
        let refused = share(&path).unwrap_err();
        assert!(refused.contains("server"), "{refused}");
        // once the server is gone, file mode may run, several at once
        drop(server);
        let first = share(&path).unwrap();
        let second = share(&path).unwrap();
        assert!(first.is_some() && second.is_some());
    }

    #[test]
    fn the_server_waits_for_file_mode_runs_that_started_first() {
        let (_directory, path) = lock_file();
        let running = share(&path).unwrap();
        let said = Arc::new(Mutex::new(Vec::new()));
        let owner = {
            let (path, said) = (path.clone(), said.clone());
            std::thread::spawn(move || {
                let started = Instant::now();
                let held = own(&path, &|| false, &|line| {
                    said.lock().unwrap().push(line.to_string())
                })
                .unwrap();
                (held.is_some(), started.elapsed())
            })
        };
        std::thread::sleep(Duration::from_millis(300));
        drop(running);
        let (held, waited) = owner.join().unwrap();
        assert!(held);
        assert!(waited >= Duration::from_millis(300), "{waited:?}");
        assert_eq!(said.lock().unwrap().len(), 1, "it says so once");
    }

    #[test]
    fn a_stop_ends_the_wait() {
        let (_directory, path) = lock_file();
        let _running = share(&path).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let owner = {
            let (path, stop) = (path.clone(), stop.clone());
            std::thread::spawn(move || own(&path, &|| stop.load(Ordering::SeqCst), &|_| {}))
        };
        std::thread::sleep(Duration::from_millis(100));
        stop.store(true, Ordering::SeqCst);
        assert!(owner.join().unwrap().is_err());
    }
}

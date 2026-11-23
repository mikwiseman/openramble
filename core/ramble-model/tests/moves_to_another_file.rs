//! Moving to another file of the same model revision.
//!
//! Windows and Linux first downloaded Parakeet Ultra as Q8_0 and now download
//! Q4_K_M. Both are files of one revision, so they share one install folder
//! and one ready marker. These tests pin what that means for a computer that
//! already holds the previous file: it keeps a working model until the
//! current one has verified, and afterwards nothing of the previous file is
//! left on disk.

use ramble_model::lineup::{ModelLineup, Slot};
use ramble_model::manifest::ManifestFile;
use ramble_model::{Manifest, ModelState, ModelStore};
use std::fs;
use std::path::{Path, PathBuf};

const PREVIOUS: (&str, &[u8]) = ("model-Q8_0.gguf", b"the larger file's weights");
const CURRENT: (&str, &[u8]) = ("model-Q4_K_M.gguf", b"the smaller file");

/// A staging folder holding one file, as a finished download leaves it.
fn staged(store: &ModelStore, attempt: &str, name: &str, bytes: &[u8]) -> PathBuf {
    let staging = store.layout.staging_directory(attempt);
    let engine = store.layout.engine_directory_inside(&staging);
    fs::create_dir_all(&engine).unwrap();
    fs::write(engine.join(name), bytes).unwrap();
    staging
}

fn store_for(root: &Path, (name, bytes): (&str, &[u8]), quantization: &str) -> ModelStore {
    let scratch = tempfile::tempdir().unwrap();
    let file = scratch.path().join(name);
    fs::write(&file, bytes).unwrap();
    let manifest = Manifest {
        model_id: "model-gguf".into(),
        repository: "owner/model-gguf".into(),
        revision: "rev1".into(),
        runtime_version: "transcribe.cpp 0.4.1".into(),
        quantization: quantization.into(),
        license: "CC-BY-4.0".into(),
        files: vec![ManifestFile {
            path: name.into(),
            byte_count: bytes.len() as i64,
            sha256: ramble_model::store::digest_of(&file).unwrap(),
        }],
        mirror: None,
    };
    ModelStore::new(manifest, root)
}

/// The two stores of a computer that installed the previous file.
fn a_computer_with_the_previous_file(root: &Path) -> (ModelStore, ModelStore) {
    let previous = store_for(root, PREVIOUS, "Q8_0");
    let current = store_for(root, CURRENT, "Q4_K_M");
    previous
        .promote(&staged(&previous, "first", PREVIOUS.0, PREVIOUS.1))
        .unwrap();
    (current, previous)
}

fn recognizer(current: &ModelStore, previous: &ModelStore) -> Slot {
    ModelLineup::new(&current.state(), &previous.state()).recognizer
}

fn files_in(directory: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn the_two_files_share_one_install_folder() {
    let root = tempfile::tempdir().unwrap();
    let (current, previous) = a_computer_with_the_previous_file(root.path());
    assert_eq!(current.engine_directory(), previous.engine_directory());
    assert_eq!(
        current.layout.ready_marker(),
        previous.layout.ready_marker()
    );
}

#[test]
fn a_computer_with_the_previous_file_keeps_a_working_model() {
    let root = tempfile::tempdir().unwrap();
    let (current, previous) = a_computer_with_the_previous_file(root.path());

    // Seen through the current manifest alone, the install is the wrong
    // files. Without the previous manifest the app would call it broken.
    assert!(matches!(current.state(), ModelState::NeedsRepair(_)));
    assert_eq!(previous.state(), ModelState::Ready);
    assert_eq!(recognizer(&current, &previous), Slot::Previous);
}

#[test]
fn installing_the_current_file_leaves_nothing_of_the_previous_one() {
    let root = tempfile::tempdir().unwrap();
    let (current, previous) = a_computer_with_the_previous_file(root.path());

    current
        .promote(&staged(&current, "second", CURRENT.0, CURRENT.1))
        .unwrap();

    assert_eq!(current.state(), ModelState::Ready);
    assert_eq!(recognizer(&current, &previous), Slot::Current);
    // The folder the engine loads holds the current file and nothing else:
    // the engine takes the single model file it finds there.
    assert_eq!(files_in(&current.engine_directory()), [CURRENT.0]);
    // And the previous file is nowhere under the models folder, in a backup
    // or a staging folder or anywhere else.
    assert_eq!(
        files_in(&current.layout.model_directory()),
        [current.layout.revision.as_str()]
    );
}

#[test]
fn a_download_that_does_not_verify_leaves_the_previous_file_working() {
    let root = tempfile::tempdir().unwrap();
    let (current, previous) = a_computer_with_the_previous_file(root.path());

    let cut_short = staged(&current, "second", CURRENT.0, &CURRENT.1[..4]);
    assert!(current.promote(&cut_short).is_err());

    assert_eq!(previous.state(), ModelState::Ready);
    assert_eq!(recognizer(&current, &previous), Slot::Previous);
    assert_eq!(files_in(&previous.engine_directory()), [PREVIOUS.0]);
}

/// The process dies after the previous install was moved aside and before the
/// current one landed.
#[test]
fn a_crash_during_the_swap_puts_the_previous_file_back() {
    let root = tempfile::tempdir().unwrap();
    let (current, previous) = a_computer_with_the_previous_file(root.path());
    fs::rename(
        current.layout.installed_directory(),
        current.layout.backup_directory(),
    )
    .unwrap();
    assert_eq!(recognizer(&current, &previous), Slot::None);

    // What the app does on its next start, with the current manifest.
    assert!(current.recover_interrupted_promotion().unwrap());

    assert_eq!(recognizer(&current, &previous), Slot::Previous);
    assert_eq!(files_in(&previous.engine_directory()), [PREVIOUS.0]);
}

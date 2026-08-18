//! Finding, verifying and promoting an install.
//!
//! Ported from `ModelStore.swift`, minus the download orchestration: bytes reach
//! this crate through a caller that already has them in a staging directory, so
//! nothing here touches the network. That split is what lets the same install
//! semantics serve a Tauri shell using reqwest and a Swift shell using
//! URLSession without either owning the rules.

use crate::layout::InstallLayout;
use crate::manifest::Manifest;
use crate::marker::{InstalledFile, ReadyMarker, ReferenceDate};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

/// What the store knows about the install right now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelState {
    NotInstalled,
    Ready,
    /// Files are present but do not match the manifest. Repair, do not reinstall
    /// from scratch — the person may be on a metered connection.
    NeedsRepair(String),
}

#[derive(Debug)]
pub enum StoreError {
    Io(std::io::Error),
    Layout(crate::layout::UnsafePath),
    /// A file's digest or size does not match the manifest.
    Corrupt {
        path: String,
        detail: String,
    },
    Missing(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Io(error) => write!(f, "{error}"),
            StoreError::Layout(error) => write!(f, "{error}"),
            StoreError::Corrupt { path, detail } => write!(f, "{path}: {detail}"),
            StoreError::Missing(path) => write!(f, "missing: {path}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        StoreError::Io(error)
    }
}

impl From<crate::layout::UnsafePath> for StoreError {
    fn from(error: crate::layout::UnsafePath) -> Self {
        StoreError::Layout(error)
    }
}

/// The SHA-256 of a file, as lowercase hex.
///
/// Streamed in chunks: the model is 739 MB, and reading it into memory to hash
/// it would cost more than loading the model does.
pub fn digest_of(path: &Path) -> std::io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub struct ModelStore {
    pub manifest: Manifest,
    pub layout: InstallLayout,
}

impl ModelStore {
    pub fn new(manifest: Manifest, root: impl Into<PathBuf>) -> Self {
        let layout = InstallLayout::from_manifest(&manifest, root);
        Self { manifest, layout }
    }

    /// What is on disk, decided cheaply.
    ///
    /// Sizes are checked, digests are not. Hashing 739 MB on every launch would
    /// add seconds to a cold start to catch something that a size check already
    /// catches in nearly every real case: a truncated download, a half-copied
    /// tree, a file the person deleted. `verify` exists for when the answer has
    /// to be certain.
    pub fn state(&self) -> ModelState {
        let marker_path = self.layout.ready_marker();
        let Ok(json) = fs::read_to_string(&marker_path) else {
            return ModelState::NotInstalled;
        };
        let Ok(marker) = ReadyMarker::parse(&json) else {
            return ModelState::NeedsRepair("the ready marker could not be read".into());
        };
        if !marker.describes(&self.manifest.revision, &self.manifest.runtime_version) {
            return ModelState::NeedsRepair(
                "the install was made by a different revision or runtime".into(),
            );
        }

        for file in &self.manifest.files {
            let Ok(destination) = self
                .layout
                .destination(file, &self.layout.engine_directory())
            else {
                return ModelState::NeedsRepair(format!("unsafe path: {}", file.path));
            };
            match fs::metadata(&destination) {
                Err(_) => return ModelState::NeedsRepair(format!("missing: {}", file.path)),
                Ok(metadata) if metadata.len() as i64 != file.byte_count => {
                    return ModelState::NeedsRepair(format!(
                        "{} is {} bytes, expected {}",
                        file.path,
                        metadata.len(),
                        file.byte_count
                    ))
                }
                Ok(_) => {}
            }
        }
        ModelState::Ready
    }

    /// The directory to hand the runtime. Only meaningful when [`Self::state`]
    /// says `Ready`.
    pub fn engine_directory(&self) -> PathBuf {
        self.layout.engine_directory()
    }

    /// Check every byte of a candidate install.
    ///
    /// `install_root` is the directory that will become the install — the files
    /// themselves are expected one level down, inside the engine folder.
    ///
    /// Run against staging before promoting, so a corrupt download can never
    /// become the installed model.
    pub fn verify(&self, install_root: &Path) -> Result<Vec<InstalledFile>, StoreError> {
        // Files live inside the engine folder, not at the root of the install.
        // That nesting is the runtime's requirement, and it is what an install
        // written by the Mac looks like on disk.
        let engine = self.layout.engine_directory_inside(install_root);
        let mut installed = Vec::with_capacity(self.manifest.files.len());
        for file in &self.manifest.files {
            let destination = self.layout.destination(file, &engine)?;
            let metadata =
                fs::metadata(&destination).map_err(|_| StoreError::Missing(file.path.clone()))?;
            if metadata.len() as i64 != file.byte_count {
                return Err(StoreError::Corrupt {
                    path: file.path.clone(),
                    detail: format!("is {} bytes, expected {}", metadata.len(), file.byte_count),
                });
            }
            let digest = digest_of(&destination)?;
            if !digest.eq_ignore_ascii_case(&file.sha256) {
                return Err(StoreError::Corrupt {
                    path: file.path.clone(),
                    detail: "the contents do not match the manifest".into(),
                });
            }
            installed.push(InstalledFile {
                path: file.path.clone(),
                byte_count: file.byte_count,
                modified_at: metadata
                    .modified()
                    .ok()
                    .map(ReferenceDate::from_system_time),
            });
        }
        Ok(installed)
    }

    /// Make a verified staging directory the install.
    ///
    /// The order is what makes this survivable. The existing install is moved
    /// aside rather than deleted, staging is moved into place, and only then is
    /// the backup removed. A crash at any point leaves either the old install or
    /// the new one — never a half of each. The marker is written last, so a tree
    /// without one is never mistaken for ready.
    pub fn promote(&self, staging: &Path) -> Result<(), StoreError> {
        let installed_files = self.verify(staging)?;

        let installed = self.layout.installed_directory();
        let backup = self.layout.backup_directory();
        fs::create_dir_all(self.layout.model_directory())?;

        // A backup left by an interrupted attempt is stale by definition: the
        // install it protected either completed or was rolled back.
        if backup.exists() {
            fs::remove_dir_all(&backup)?;
        }
        let had_previous = installed.exists();
        if had_previous {
            fs::rename(&installed, &backup)?;
        }

        if let Err(error) = fs::rename(staging, &installed) {
            // Put the previous install back before surfacing the failure: the
            // person's dictation must keep working.
            if had_previous {
                let _ = fs::rename(&backup, &installed);
            }
            return Err(StoreError::Io(error));
        }

        let marker = ReadyMarker {
            revision: self.manifest.revision.clone(),
            runtime_version: self.manifest.runtime_version.clone(),
            file_count: self.manifest.files.len() as i32,
            total_byte_count: self.manifest.total_byte_count(),
            verified_at: ReferenceDate::now(),
            installed_files: Some(installed_files),
        };
        fs::write(
            self.layout.ready_marker(),
            marker.to_json().map_err(std::io::Error::other)?,
        )?;

        if had_previous {
            fs::remove_dir_all(&backup)?;
        }
        Ok(())
    }

    /// Finish what a crash interrupted, before anyone is shown a state.
    ///
    /// A backup with no install beside it means the process died between moving
    /// the old install aside and moving the new one in. The old one is the only
    /// complete thing on disk, so it goes back.
    pub fn recover_interrupted_promotion(&self) -> Result<bool, StoreError> {
        let backup = self.layout.backup_directory();
        if !backup.exists() {
            return Ok(false);
        }
        let installed = self.layout.installed_directory();
        if installed.join(".ready.json").exists() {
            // The new install completed; the backup is simply litter.
            fs::remove_dir_all(&backup)?;
            return Ok(false);
        }
        if installed.exists() {
            fs::remove_dir_all(&installed)?;
        }
        fs::rename(&backup, &installed)?;
        Ok(true)
    }

    /// Remove scratch directories left by attempts that did not finish.
    ///
    /// Each one can hold 739 MB, and nothing else will ever clean them up.
    pub fn sweep_stale_staging(&self) -> Result<u32, StoreError> {
        let model_directory = self.layout.model_directory();
        let Ok(entries) = fs::read_dir(&model_directory) else {
            return Ok(0);
        };
        let mut removed = 0;
        for entry in entries.flatten() {
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            if name.starts_with(".staging-") {
                fs::remove_dir_all(entry.path())?;
                removed += 1;
            }
        }
        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{Manifest, ManifestFile};

    fn manifest_for(contents: &[(&str, &[u8])]) -> Manifest {
        let files = contents
            .iter()
            .map(|(path, bytes)| ManifestFile {
                path: (*path).to_string(),
                byte_count: bytes.len() as i64,
                sha256: {
                    let mut hasher = Sha256::new();
                    hasher.update(bytes);
                    hasher
                        .finalize()
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect()
                },
            })
            .collect();
        Manifest {
            model_id: "test-model".into(),
            repository: "owner/test-model".into(),
            revision: "rev1".into(),
            runtime_version: "transcribe.cpp 0.2.0".into(),
            quantization: "Q8_0".into(),
            license: "CC-BY-4.0".into(),
            files,
            mirror: None,
        }
    }

    fn stage(store: &ModelStore, name: &str, contents: &[(&str, &[u8])]) -> PathBuf {
        let staging = store.layout.staging_directory(name);
        let engine = store.layout.engine_directory_inside(&staging);
        for (path, bytes) in contents {
            let destination = engine.join(path);
            fs::create_dir_all(destination.parent().unwrap()).unwrap();
            fs::write(&destination, bytes).unwrap();
        }
        staging
    }

    const FILES: &[(&str, &[u8])] = &[("model.gguf", b"weights"), ("nested/vocab.txt", b"vocab")];

    #[test]
    fn an_empty_root_means_nothing_is_installed() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        assert_eq!(store.state(), ModelState::NotInstalled);
    }

    #[test]
    fn a_promoted_install_reads_as_ready() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        let staging = stage(&store, "a", FILES);
        store.promote(&staging).unwrap();

        assert_eq!(store.state(), ModelState::Ready);
        assert!(store.layout.ready_marker().exists());
        // Staging is gone: it became the install rather than being copied.
        assert!(!staging.exists());
        // And no backup litter is left behind.
        assert!(!store.layout.backup_directory().exists());
    }

    #[test]
    fn a_corrupt_staging_never_becomes_the_install() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        let staging = stage(
            &store,
            "a",
            &[("model.gguf", b"WRONG!!"), ("nested/vocab.txt", b"vocab")],
        );
        let error = store.promote(&staging).unwrap_err();
        assert!(matches!(error, StoreError::Corrupt { .. }), "{error}");
        assert_eq!(store.state(), ModelState::NotInstalled);
    }

    /// Same length, different bytes — the case a size check cannot catch and the
    /// reason `verify` hashes at all.
    #[test]
    fn a_file_of_the_right_length_but_wrong_content_is_caught() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        let staging = stage(
            &store,
            "a",
            &[("model.gguf", b"weighty"), ("nested/vocab.txt", b"vocab")],
        );
        assert!(matches!(
            store.promote(&staging),
            Err(StoreError::Corrupt { .. })
        ));
    }

    #[test]
    fn a_truncated_file_makes_the_install_need_repair() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();

        fs::write(store.layout.engine_directory().join("model.gguf"), b"cut").unwrap();
        assert!(matches!(store.state(), ModelState::NeedsRepair(_)));
    }

    #[test]
    fn a_deleted_file_makes_the_install_need_repair() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();

        fs::remove_file(store.layout.engine_directory().join("model.gguf")).unwrap();
        assert!(matches!(store.state(), ModelState::NeedsRepair(_)));
    }

    /// A tree with every file present but no marker is not an install. The
    /// marker is written last precisely so this case is distinguishable.
    #[test]
    fn files_without_a_marker_are_not_an_install() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        let engine = store.layout.engine_directory();
        for (path, bytes) in FILES {
            let destination = engine.join(path);
            fs::create_dir_all(destination.parent().unwrap()).unwrap();
            fs::write(destination, bytes).unwrap();
        }
        assert_eq!(store.state(), ModelState::NotInstalled);
    }

    #[test]
    fn a_marker_from_another_runtime_needs_repair() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();

        let mut manifest = manifest_for(FILES);
        manifest.runtime_version = "transcribe.cpp 0.3.0".into();
        let newer = ModelStore::new(manifest, root.path());
        assert!(matches!(newer.state(), ModelState::NeedsRepair(_)));
    }

    /// Replacing an install must leave the person with a working one either way.
    #[test]
    fn reinstalling_over_a_good_install_leaves_no_debris() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();
        store.promote(&stage(&store, "b", FILES)).unwrap();

        assert_eq!(store.state(), ModelState::Ready);
        assert!(!store.layout.backup_directory().exists());
    }

    /// The crash case: the old install was moved aside and the process died
    /// before the new one landed.
    #[test]
    fn an_interrupted_promotion_restores_the_previous_install() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();

        // Simulate the crash: install moved to backup, nothing put back.
        fs::rename(
            store.layout.installed_directory(),
            store.layout.backup_directory(),
        )
        .unwrap();
        assert_eq!(store.state(), ModelState::NotInstalled);

        assert!(store.recover_interrupted_promotion().unwrap());
        assert_eq!(store.state(), ModelState::Ready);
        assert!(!store.layout.backup_directory().exists());
    }

    /// A backup beside a completed install is litter, not a rollback.
    #[test]
    fn a_backup_next_to_a_finished_install_is_just_removed() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();
        fs::create_dir_all(store.layout.backup_directory()).unwrap();

        assert!(!store.recover_interrupted_promotion().unwrap());
        assert_eq!(store.state(), ModelState::Ready);
        assert!(!store.layout.backup_directory().exists());
    }

    #[test]
    fn abandoned_staging_directories_are_swept() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        store.promote(&stage(&store, "a", FILES)).unwrap();
        stage(&store, "abandoned-1", FILES);
        stage(&store, "abandoned-2", FILES);

        assert_eq!(store.sweep_stale_staging().unwrap(), 2);
        // And the install itself is untouched.
        assert_eq!(store.state(), ModelState::Ready);
    }

    #[test]
    fn the_engine_directory_is_where_the_runtime_expects_it() {
        let root = tempfile::tempdir().unwrap();
        let store = ModelStore::new(manifest_for(FILES), root.path());
        assert_eq!(
            store.engine_directory(),
            store.layout.installed_directory().join("test-model")
        );
    }
}

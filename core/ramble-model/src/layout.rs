//! Where an installed model lives on disk.
//!
//! Ported from `ModelInstallLayout.swift`. Every path here is part of a contract
//! with the shipping Mac app: when macOS migrates onto this crate it must adopt
//! a tree that Swift wrote, without re-downloading 739 MB. So these are not
//! naming preferences — changing one strands an existing install.

use crate::manifest::{Manifest, ManifestFile};
use std::path::{Path, PathBuf};

/// The directories and files of one model install.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallLayout {
    /// `~/Library/Application Support/OpenRamble/Models` on macOS, the
    /// platform's equivalent elsewhere.
    pub root: PathBuf,
    pub model_id: String,
    pub revision: String,
    /// The folder name the runtime expects inside the install.
    pub engine_folder_name: String,
}

/// A path that would write outside the install directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnsafePath(pub String);

impl std::fmt::Display for UnsafePath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "the path leads outside the install directory: {}",
            self.0
        )
    }
}

impl std::error::Error for UnsafePath {}

impl InstallLayout {
    pub fn new(
        root: impl Into<PathBuf>,
        model_id: impl Into<String>,
        revision: impl Into<String>,
        engine_folder_name: impl Into<String>,
    ) -> Self {
        Self {
            root: root.into(),
            model_id: model_id.into(),
            revision: revision.into(),
            engine_folder_name: engine_folder_name.into(),
        }
    }

    /// The layout a manifest implies.
    ///
    /// The engine folder name comes from the repository name with any `-coreml`
    /// suffix removed. That rule is inherited from the Mac and kept verbatim: the
    /// suffix strip is why an install written by 0.9.0 is found here at all.
    pub fn from_manifest(manifest: &Manifest, root: impl Into<PathBuf>) -> Self {
        let folder = manifest
            .repository
            .rsplit('/')
            .next()
            .unwrap_or(&manifest.model_id)
            .replace("-coreml", "");
        Self::new(root, &manifest.model_id, &manifest.revision, folder)
    }

    pub fn model_directory(&self) -> PathBuf {
        self.root.join(&self.model_id)
    }

    /// Where a finished install lives. The revision is in the path, so a new
    /// revision installs beside the old one instead of over it, and a rollback
    /// remains possible.
    pub fn installed_directory(&self) -> PathBuf {
        self.model_directory().join(&self.revision)
    }

    pub fn engine_directory(&self) -> PathBuf {
        self.installed_directory().join(&self.engine_folder_name)
    }

    pub fn engine_directory_inside(&self, staging: &Path) -> PathBuf {
        staging.join(&self.engine_folder_name)
    }

    /// Written last. Its presence is the claim that every file is in place and
    /// has been verified; nothing else on disk means "ready".
    pub fn ready_marker(&self) -> PathBuf {
        self.installed_directory().join(".ready.json")
    }

    /// The previous working install, kept for the duration of a promotion.
    /// Removed on success; on a crash it is what recovery restores from.
    pub fn backup_directory(&self) -> PathBuf {
        self.model_directory()
            .join(format!(".backup-{}", self.revision))
    }

    /// One install attempt's scratch directory. Unique so two attempts cannot
    /// tread on each other.
    pub fn staging_directory(&self, attempt: &str) -> PathBuf {
        self.model_directory().join(format!(".staging-{attempt}"))
    }

    /// Is this a scratch directory rather than an install?
    pub fn is_scratch_directory(name: &str) -> bool {
        name.starts_with(".staging-") || name.starts_with(".backup-")
    }

    /// Where one manifest file goes inside a directory.
    ///
    /// The manifest path was already checked at parse time; it is checked again
    /// here. Writing outside the install directory is too expensive a mistake to
    /// rest on a single barrier.
    pub fn destination(&self, file: &ManifestFile, inside: &Path) -> Result<PathBuf, UnsafePath> {
        if !crate::manifest::is_safe_relative_path(&file.path) {
            return Err(UnsafePath(file.path.clone()));
        }
        Ok(file
            .path
            .split('/')
            .fold(inside.to_path_buf(), |partial, component| {
                partial.join(component)
            }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

    const SHIPPING: &str =
        include_str!("../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

    fn layout() -> InstallLayout {
        InstallLayout::from_manifest(&Manifest::parse(SHIPPING).unwrap(), "/models")
    }

    /// The exact tree the Mac writes. A change here strands every existing
    /// install, so the shape is pinned rather than described.
    #[test]
    fn the_tree_matches_what_the_mac_writes() {
        let layout = layout();
        assert_eq!(
            layout.installed_directory(),
            Path::new("/models/parakeet-tdt-0.6b-v3-gguf/85ac09ea12fc4b1112fa76810059364bc6adc9de")
        );
        assert_eq!(
            layout.ready_marker(),
            layout.installed_directory().join(".ready.json")
        );
        assert_eq!(
            layout.engine_directory(),
            layout
                .installed_directory()
                .join("parakeet-tdt-0.6b-v3-gguf")
        );
        assert_eq!(
            layout.backup_directory(),
            Path::new("/models/parakeet-tdt-0.6b-v3-gguf/.backup-85ac09ea12fc4b1112fa76810059364bc6adc9de")
        );
    }

    /// The suffix strip is why a tree written by the Mac is found at all.
    #[test]
    fn the_coreml_suffix_is_stripped_from_the_engine_folder() {
        let mut manifest = Manifest::parse(SHIPPING).unwrap();
        manifest.repository = "someone/whisper-large-coreml".into();
        let layout = InstallLayout::from_manifest(&manifest, "/models");
        assert_eq!(layout.engine_folder_name, "whisper-large");
    }

    #[test]
    fn a_new_revision_installs_beside_the_old_one() {
        let mut manifest = Manifest::parse(SHIPPING).unwrap();
        let first = InstallLayout::from_manifest(&manifest, "/models").installed_directory();
        manifest.revision = "0000000000000000000000000000000000000000".into();
        let second = InstallLayout::from_manifest(&manifest, "/models").installed_directory();
        assert_ne!(first, second);
        assert_eq!(first.parent(), second.parent());
    }

    #[test]
    fn two_attempts_do_not_share_a_staging_directory() {
        let layout = layout();
        assert_ne!(
            layout.staging_directory("a1"),
            layout.staging_directory("b2")
        );
        assert!(InstallLayout::is_scratch_directory(
            layout
                .staging_directory("a1")
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
        ));
        assert!(!InstallLayout::is_scratch_directory(
            "85ac09ea12fc4b1112fa76810059364bc6adc9de"
        ));
    }

    /// Files sit inside the engine folder, not at the root of the install.
    ///
    /// Every unit test here once agreed with the opposite assumption, and only
    /// reading the tree the shipping app had actually written on disk disproved
    /// it. Getting this wrong makes an existing install invisible, and the
    /// macOS migration would re-download 739 MB from everyone who already has it.
    #[test]
    fn the_model_files_live_one_level_down_inside_the_engine_folder() {
        let layout = layout();
        let file = crate::manifest::ManifestFile {
            path: "parakeet-tdt-0.6b-v3-Q8_0.gguf".into(),
            byte_count: 1,
            sha256: "a".repeat(64),
        };
        assert_eq!(
            layout
                .destination(&file, &layout.engine_directory())
                .unwrap(),
            Path::new(
                "/models/parakeet-tdt-0.6b-v3-gguf/85ac09ea12fc4b1112fa76810059364bc6adc9de\
/parakeet-tdt-0.6b-v3-gguf/parakeet-tdt-0.6b-v3-Q8_0.gguf"
            )
        );
    }

    #[test]
    fn a_destination_stays_inside_the_directory_it_was_given() {
        let layout = layout();
        let file = crate::manifest::ManifestFile {
            path: "nested/model.gguf".into(),
            byte_count: 1,
            sha256: "a".repeat(64),
        };
        assert_eq!(
            layout.destination(&file, Path::new("/staging")).unwrap(),
            Path::new("/staging/nested/model.gguf")
        );

        // The second barrier: even a manifest that got past parsing is refused.
        let escaping = crate::manifest::ManifestFile {
            path: "../escape".into(),
            byte_count: 1,
            sha256: "a".repeat(64),
        };
        assert!(layout
            .destination(&escaping, Path::new("/staging"))
            .is_err());
    }
}

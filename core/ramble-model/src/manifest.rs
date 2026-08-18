//! What a model install consists of, and where its bytes may come from.
//!
//! Ported from `Packages/LocalASR/Sources/LocalASR/ModelManifest.swift` and its
//! `Resources/model-manifest.json`. The field names are the Swift ones, spelling
//! included — `modelID`, not `modelId` — because the same manifest file is read
//! by both implementations. A prettier name here would mean two manifests.

use serde::{Deserialize, Serialize};

/// One file the install must contain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestFile {
    /// Relative path inside the install directory.
    pub path: String,
    #[serde(rename = "byteCount")]
    pub byte_count: i64,
    pub sha256: String,
}

/// Where the same bytes can be fetched if the primary source is down.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mirror {
    pub repository: String,
    #[serde(rename = "releaseTag")]
    pub release_tag: String,
}

/// The description of one installable model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    #[serde(rename = "modelID")]
    pub model_id: String,
    pub repository: String,
    /// Pinned. The revision is part of the install path, so changing it installs
    /// alongside the old one rather than over it, and a rollback stays possible.
    pub revision: String,
    #[serde(rename = "runtimeVersion")]
    pub runtime_version: String,
    pub quantization: String,
    pub license: String,
    pub files: Vec<ManifestFile>,
    #[serde(default)]
    pub mirror: Option<Mirror>,
}

/// A manifest that cannot be installed from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManifestError {
    Malformed(String),
    /// A path that would write outside the install directory.
    UnsafePath(String),
    NoFiles,
    /// A digest that is not 64 hex characters cannot verify anything.
    MalformedDigest {
        path: String,
        sha256: String,
    },
    NonPositiveSize {
        path: String,
        byte_count: i64,
    },
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManifestError::Malformed(detail) => {
                write!(f, "the manifest could not be read: {detail}")
            }
            ManifestError::UnsafePath(path) => {
                write!(f, "the manifest names a file outside the install: {path}")
            }
            ManifestError::NoFiles => write!(f, "the manifest lists no files"),
            ManifestError::MalformedDigest { path, sha256 } => {
                write!(f, "the digest for {path} is not a SHA-256: {sha256}")
            }
            ManifestError::NonPositiveSize { path, byte_count } => {
                write!(f, "the size of {path} is not a size: {byte_count}")
            }
        }
    }
}

impl std::error::Error for ManifestError {}

/// Exactly three things lead outside an install directory: `..`, a leading
/// slash, and an empty component.
///
/// Checked on the manifest's own string rather than on a joined path. A joined
/// path would have to be canonicalized through the filesystem, which answers
/// differently for a file that exists and one that does not — on macOS `/tmp`
/// against `/private/tmp`, the same place spelled two ways. That made the
/// barrier depend on what happened to be on disk already, and it started
/// rejecting perfectly legal files, breaking installation outright. Parsing the
/// relative path touches no disk at all.
pub fn is_safe_relative_path(path: &str) -> bool {
    let components: Vec<&str> = path.split('/').collect();
    !components.is_empty()
        && !components
            .iter()
            .any(|component| component.is_empty() || *component == "." || *component == "..")
}

impl Manifest {
    pub fn parse(json: &str) -> Result<Self, ManifestError> {
        let manifest: Manifest = serde_json::from_str(json)
            .map_err(|error| ManifestError::Malformed(error.to_string()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        if self.files.is_empty() {
            return Err(ManifestError::NoFiles);
        }
        for file in &self.files {
            if !is_safe_relative_path(&file.path) {
                return Err(ManifestError::UnsafePath(file.path.clone()));
            }
            if file.sha256.len() != 64 || !file.sha256.chars().all(|c| c.is_ascii_hexdigit()) {
                return Err(ManifestError::MalformedDigest {
                    path: file.path.clone(),
                    sha256: file.sha256.clone(),
                });
            }
            if file.byte_count <= 0 {
                return Err(ManifestError::NonPositiveSize {
                    path: file.path.clone(),
                    byte_count: file.byte_count,
                });
            }
        }
        Ok(())
    }

    pub fn total_byte_count(&self) -> i64 {
        self.files.iter().map(|file| file.byte_count).sum()
    }

    /// Sources to try, in order.
    ///
    /// The mirror comes first deliberately. It is a release asset on a repository
    /// this project controls, so it cannot be retagged or rate-limited out from
    /// under a person mid-install the way the upstream host can.
    pub fn sources(&self) -> Vec<Source> {
        let mut sources = Vec::new();
        if let Some(mirror) = &self.mirror {
            sources.push(Source::Mirror {
                repository: mirror.repository.clone(),
                release_tag: mirror.release_tag.clone(),
            });
        }
        sources.push(Source::Upstream {
            repository: self.repository.clone(),
            revision: self.revision.clone(),
        });
        sources
    }
}

/// Where one file's bytes can be fetched from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    Mirror {
        repository: String,
        release_tag: String,
    },
    Upstream {
        repository: String,
        revision: String,
    },
}

impl Source {
    /// The URL for one file.
    ///
    /// Building it here rather than in the shell keeps the host allowlist and the
    /// URL shape in one reviewable place; the shell only moves bytes.
    pub fn url(&self, file: &ManifestFile) -> String {
        match self {
            Source::Mirror {
                repository,
                release_tag,
            } => {
                // Release assets are flat, so a nested manifest path becomes a
                // flat asset name.
                let asset = file.path.replace('/', "-");
                format!("https://github.com/{repository}/releases/download/{release_tag}/{asset}")
            }
            Source::Upstream {
                repository,
                revision,
            } => format!(
                "https://huggingface.co/{repository}/resolve/{revision}/{}",
                file.path
            ),
        }
    }

    /// The host this source uses. The shell refuses anything not on this list,
    /// including after a redirect.
    pub fn host(&self) -> &'static str {
        match self {
            Source::Mirror { .. } => "github.com",
            Source::Upstream { .. } => "huggingface.co",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHIPPING: &str =
        include_str!("../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

    /// The manifest the Mac ships must parse here unchanged. If it stops doing
    /// so, the two implementations have forked their idea of an install.
    #[test]
    fn the_shipping_manifest_parses() {
        let manifest = Manifest::parse(SHIPPING).expect("shipping manifest must parse");
        assert_eq!(manifest.model_id, "parakeet-tdt-0.6b-v3-gguf");
        assert_eq!(
            manifest.revision,
            "85ac09ea12fc4b1112fa76810059364bc6adc9de"
        );
        assert_eq!(manifest.files.len(), 1);
        assert_eq!(manifest.total_byte_count(), 739_508_576);
        assert_eq!(manifest.license, "CC-BY-4.0");
        assert!(manifest.mirror.is_some());
    }

    #[test]
    fn the_mirror_is_tried_before_upstream() {
        let manifest = Manifest::parse(SHIPPING).unwrap();
        let sources = manifest.sources();
        assert!(matches!(sources[0], Source::Mirror { .. }));
        assert!(matches!(sources[1], Source::Upstream { .. }));
    }

    #[test]
    fn urls_point_at_the_expected_hosts() {
        let manifest = Manifest::parse(SHIPPING).unwrap();
        let file = &manifest.files[0];
        let sources = manifest.sources();
        assert!(sources[0].url(file).starts_with(
            "https://github.com/mikwiseman/openramble/releases/download/models-85ac09ea/"
        ));
        assert!(sources[1]
            .url(file)
            .contains("huggingface.co/handy-computer/"));
        assert!(sources[1]
            .url(file)
            .contains("85ac09ea12fc4b1112fa76810059364bc6adc9de"));
        assert_eq!(sources[0].host(), "github.com");
        assert_eq!(sources[1].host(), "huggingface.co");
    }

    #[test]
    fn a_path_that_escapes_the_install_is_refused() {
        for path in ["../evil", "/etc/passwd", "a/../../b", "", "a//b", "./x"] {
            assert!(!is_safe_relative_path(path), "{path} should be refused");
        }
        for path in ["model.gguf", "nested/model.gguf"] {
            assert!(is_safe_relative_path(path), "{path} should be allowed");
        }
    }

    #[test]
    fn a_manifest_that_cannot_verify_anything_is_refused() {
        let base = Manifest::parse(SHIPPING).unwrap();

        let mut short_digest = base.clone();
        short_digest.files[0].sha256 = "abc".into();
        assert!(matches!(
            short_digest.validate(),
            Err(ManifestError::MalformedDigest { .. })
        ));

        let mut not_hex = base.clone();
        not_hex.files[0].sha256 = "z".repeat(64);
        assert!(matches!(
            not_hex.validate(),
            Err(ManifestError::MalformedDigest { .. })
        ));

        let mut no_size = base.clone();
        no_size.files[0].byte_count = 0;
        assert!(matches!(
            no_size.validate(),
            Err(ManifestError::NonPositiveSize { .. })
        ));

        let mut empty = base;
        empty.files.clear();
        assert!(matches!(empty.validate(), Err(ManifestError::NoFiles)));
    }

    #[test]
    fn an_escaping_path_is_refused_at_parse_time_not_only_on_disk() {
        let json = SHIPPING.replace(
            "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            "../../../../etc/authorized_keys",
        );
        assert!(matches!(
            Manifest::parse(&json),
            Err(ManifestError::UnsafePath(_))
        ));
    }
}

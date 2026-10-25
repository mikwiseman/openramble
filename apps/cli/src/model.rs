//! Which model is being served, and whether its bytes are the published ones.
//!
//! The Mac app ships Q4_K_M and the desktop app Q8_0; a server may run either.
//! Both manifests are compiled in, and a model file is checked against the
//! entry with its file name: its size first, then its SHA-256.

use std::path::Path;

use ramble_model::{Manifest, ManifestFile};

const MANIFESTS: [(&str, &str); 2] = [
    (
        "the Mac app's manifest",
        include_str!("../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json"),
    ),
    (
        "the desktop app's manifest",
        include_str!("../../desktop/src-tauri/model-manifest.json"),
    ),
];

/// The name the server reports for a model: its file name without `.gguf`.
pub fn stem(model_file: &Path) -> String {
    model_file
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown".into())
}

/// The published entry for a model file name, and which manifest has it.
pub fn expected(file_name: &str) -> Option<(ManifestFile, &'static str)> {
    MANIFESTS.iter().find_map(|(name, json)| {
        let manifest = Manifest::parse(json).ok()?;
        manifest
            .files
            .into_iter()
            .find(|file| file.path == file_name)
            .map(|file| (file, *name))
    })
}

/// Check a model file's size and SHA-256 against its published entry.
pub fn verify(model_file: &Path) -> Result<String, String> {
    let name = model_file
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let (entry, manifest) = expected(&name)
        .ok_or_else(|| format!("no manifest lists {name}, so it cannot be checked"))?;
    let size = std::fs::metadata(model_file)
        .map_err(|error| format!("{}: {error}", model_file.display()))?
        .len();
    if size != entry.byte_count as u64 {
        return Err(format!(
            "{name} is {size} bytes; {manifest} says {}",
            entry.byte_count
        ));
    }
    let digest = ramble_model::store::digest_of(model_file)
        .map_err(|error| format!("{}: {error}", model_file.display()))?;
    if digest != entry.sha256 {
        return Err(format!(
            "{name} has SHA-256 {digest}; {manifest} says {}",
            entry.sha256
        ));
    }
    Ok(format!("{size} bytes and SHA-256 match {manifest}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_published_quantizations_are_known() {
        let (q4, mac) = expected("parakeet-ultra-Q4_K_M.gguf").unwrap();
        assert_eq!(q4.byte_count, 486_280_096);
        assert_eq!(mac, "the Mac app's manifest");
        let (q8, desktop) = expected("parakeet-ultra-Q8_0.gguf").unwrap();
        assert_eq!(q8.byte_count, 740_363_168);
        assert_eq!(desktop, "the desktop app's manifest");
        assert!(expected("something-else.gguf").is_none());
    }

    #[test]
    fn a_file_that_is_not_the_published_one_fails() {
        let directory = tempfile::tempdir().unwrap();
        let unknown = directory.path().join("mystery.gguf");
        std::fs::write(&unknown, b"x").unwrap();
        assert!(verify(&unknown).unwrap_err().contains("no manifest lists"));

        let short = directory.path().join("parakeet-ultra-Q4_K_M.gguf");
        std::fs::write(&short, b"not a model").unwrap();
        assert!(verify(&short).unwrap_err().contains("is 11 bytes"));
    }

    #[test]
    fn the_reported_name_is_the_file_stem() {
        assert_eq!(
            stem(Path::new("/opt/models/parakeet-ultra-Q8_0.gguf")),
            "parakeet-ultra-Q8_0"
        );
    }
}

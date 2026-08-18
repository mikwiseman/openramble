//! Does this crate recognize an install that the shipping Mac app wrote?
//!
//! The whole point of matching the layout is that the macOS migration must not
//! re-download 739 MB from every person who already has the model. A unit test
//! against a tree this crate created cannot prove that — it only proves the code
//! agrees with itself. This one reads the real install, when the machine running
//! the tests happens to have one.
//!
//! It is a no-op on a machine without an install (CI, a fresh checkout) rather
//! than a failure: absence of the model is not a defect in this crate.

use ramble_model::{Manifest, ModelState, ModelStore};

const SHIPPING_MANIFEST: &str =
    include_str!("../../../Packages/LocalASR/Sources/LocalASR/Resources/model-manifest.json");

fn support_root() -> Option<std::path::PathBuf> {
    // The same override the Mac app honours for isolated debug launches.
    if let Ok(root) = std::env::var("OPENRAMBLE_SUPPORT_ROOT") {
        return Some(std::path::PathBuf::from(root).join("Models"));
    }
    let home = std::env::var("HOME").ok()?;
    Some(std::path::PathBuf::from(home).join("Library/Application Support/OpenRamble/Models"))
}

#[test]
fn an_install_written_by_the_mac_is_adopted_not_redownloaded() {
    let Some(root) = support_root() else {
        eprintln!("no home directory; skipping");
        return;
    };
    let manifest = Manifest::parse(SHIPPING_MANIFEST).expect("shipping manifest must parse");
    let store = ModelStore::new(manifest, &root);

    if !store.layout.ready_marker().exists() {
        eprintln!(
            "no install at {} — skipping the adoption check",
            store.layout.installed_directory().display()
        );
        return;
    }

    assert_eq!(
        store.state(),
        ModelState::Ready,
        "the Mac's own install at {} was not recognized; the macOS migration would \
         re-download 739 MB from every existing user",
        store.layout.installed_directory().display()
    );

    let engine = store.engine_directory();
    assert!(
        engine.exists(),
        "the runtime directory {} does not exist",
        engine.display()
    );
}

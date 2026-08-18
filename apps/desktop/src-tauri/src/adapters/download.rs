//! The one place in this application that touches the network.
//!
//! The macOS app allows exactly two network areas — explicit model downloads and
//! update checks — and `scripts/check-network-surface.sh` enforces that by
//! filename. This module is the Rust half of the first area, and the gate knows
//! its name for the same reason: a promise that is checked only by intention is
//! not checked.
//!
//! What happens here is deliberately thin. Which URLs exist, in what order, and
//! whether the bytes are the right bytes are all decided by `ramble-model`,
//! which has no network access of its own. This module moves bytes and nothing
//! else, so the rules cannot quietly fork between platforms.

use ramble_model::{Manifest, ManifestFile, ModelStore, Source};
use std::io::Write;
use std::path::Path;

#[derive(Debug)]
pub enum DownloadError {
    /// Every source failed. Carries the last reason, which is the one worth
    /// showing.
    AllSourcesFailed(String),
    /// A redirect left the hosts we are willing to talk to.
    ///
    /// Refused rather than followed: a download that can be redirected anywhere
    /// is a download that can be pointed at anything.
    UnapprovedRedirect(String),
    Write(String),
    Corrupt(String),
    Cancelled,
}

impl std::fmt::Display for DownloadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DownloadError::AllSourcesFailed(detail) => write!(
                f,
                "The speech model could not be downloaded: {detail}. \
                 Check the connection and try again."
            ),
            DownloadError::UnapprovedRedirect(host) => write!(
                f,
                "The download was redirected to an unexpected server ({host}) and was stopped."
            ),
            DownloadError::Write(detail) => write!(f, "The model could not be saved: {detail}"),
            DownloadError::Corrupt(detail) => write!(
                f,
                "The downloaded model did not match what was expected ({detail}). \
                 Nothing was installed."
            ),
            DownloadError::Cancelled => write!(f, "The download was stopped."),
        }
    }
}

impl std::error::Error for DownloadError {}

/// Hosts this application will talk to, after redirects included.
///
/// Both are release-asset or model hosts that redirect to their own CDNs, so the
/// list carries those too. Anything else is refused.
fn is_approved(host: &str) -> bool {
    const APPROVED: &[&str] = &[
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "huggingface.co",
        "cdn-lfs.huggingface.co",
        "cdn-lfs-us-1.huggingface.co",
    ];
    APPROVED
        .iter()
        .any(|approved| host == *approved || host.ends_with(&format!(".{approved}")))
}

/// How many times one source is tried before handing over to the next.
///
/// Three. The model is 739 MB, and a source that has failed three times running
/// is not blinking — it is down, and the mirror is the better answer.
const ATTEMPTS_PER_SOURCE: usize = 3;

/// Progress, as a fraction and in bytes.
pub type ProgressFn = dyn Fn(u64, u64) + Send + Sync;

/// Fetch every file the manifest names into a staging directory, verify it, and
/// promote it.
///
/// Nothing becomes the install until every byte has been checked, because a
/// half-downloaded model that loads is worse than none: it fails at dictation
/// time, when a person is mid-sentence.
pub fn install(
    store: &ModelStore,
    progress: &ProgressFn,
    cancelled: &(dyn Fn() -> bool + Send + Sync),
) -> Result<(), DownloadError> {
    let manifest = &store.manifest;
    // Left over from an attempt that did not finish; each can hold 739 MB.
    let _ = store.sweep_stale_staging();

    let attempt = format!(
        "{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|since| since.as_nanos())
            .unwrap_or(0)
    );
    let staging = store.layout.staging_directory(&attempt);
    let engine = store.layout.engine_directory_inside(&staging);

    let total = manifest.total_byte_count() as u64;
    let mut done = 0_u64;

    for file in &manifest.files {
        let destination = store
            .layout
            .destination(file, &engine)
            .map_err(|error| DownloadError::Write(error.to_string()))?;
        fetch_one(
            manifest,
            file,
            &destination,
            done,
            total,
            progress,
            cancelled,
        )?;
        done += file.byte_count as u64;
    }

    store
        .promote(&staging)
        .map_err(|error| DownloadError::Corrupt(error.to_string()))?;
    Ok(())
}

fn fetch_one(
    manifest: &Manifest,
    file: &ManifestFile,
    destination: &Path,
    already_done: u64,
    total: u64,
    progress: &ProgressFn,
    cancelled: &(dyn Fn() -> bool + Send + Sync),
) -> Result<(), DownloadError> {
    let mut last_error = String::from("no source was reachable");

    for source in manifest.sources() {
        for attempt in 0..ATTEMPTS_PER_SOURCE {
            if cancelled() {
                return Err(DownloadError::Cancelled);
            }
            match try_fetch(
                &source,
                file,
                destination,
                already_done,
                total,
                progress,
                cancelled,
            ) {
                Ok(()) => return Ok(()),
                Err(DownloadError::Cancelled) => return Err(DownloadError::Cancelled),
                // A redirect off the allowlist is a property of the address, not
                // a bad minute. Repeating it knocks on a disallowed host again.
                Err(error @ DownloadError::UnapprovedRedirect(_)) => return Err(error),
                Err(error) => {
                    last_error = error.to_string();
                    // Back off a little between attempts on the same source.
                    if attempt + 1 < ATTEMPTS_PER_SOURCE {
                        std::thread::sleep(std::time::Duration::from_secs(2 << attempt));
                    }
                }
            }
        }
    }
    Err(DownloadError::AllSourcesFailed(last_error))
}

fn try_fetch(
    source: &Source,
    file: &ManifestFile,
    destination: &Path,
    already_done: u64,
    total: u64,
    progress: &ProgressFn,
    cancelled: &(dyn Fn() -> bool + Send + Sync),
) -> Result<(), DownloadError> {
    let url = source.url(file);

    let client = reqwest::blocking::Client::builder()
        // Redirects are inspected rather than followed blindly.
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            match attempt.url().host_str() {
                Some(host) if is_approved(host) => attempt.follow(),
                _ => attempt.stop(),
            }
        }))
        .build()
        .map_err(|error| DownloadError::AllSourcesFailed(error.to_string()))?;

    let mut response = client
        .get(&url)
        .send()
        .map_err(|error| DownloadError::AllSourcesFailed(error.to_string()))?;

    let landed = response.url().host_str().unwrap_or_default().to_string();
    if !is_approved(&landed) {
        return Err(DownloadError::UnapprovedRedirect(landed));
    }
    if !response.status().is_success() {
        return Err(DownloadError::AllSourcesFailed(format!(
            "the server answered {}",
            response.status()
        )));
    }

    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent).map_err(|e| DownloadError::Write(e.to_string()))?;
    }
    let mut sink =
        std::fs::File::create(destination).map_err(|e| DownloadError::Write(e.to_string()))?;

    let mut buffer = vec![0_u8; 1 << 20];
    let mut written = 0_u64;
    loop {
        if cancelled() {
            // Half a file is not something to leave behind.
            let _ = std::fs::remove_file(destination);
            return Err(DownloadError::Cancelled);
        }
        let read = std::io::Read::read(&mut response, &mut buffer)
            .map_err(|error| DownloadError::AllSourcesFailed(error.to_string()))?;
        if read == 0 {
            break;
        }
        sink.write_all(&buffer[..read])
            .map_err(|error| DownloadError::Write(error.to_string()))?;
        written += read as u64;
        progress(already_done + written, total);
    }
    sink.flush()
        .map_err(|e| DownloadError::Write(e.to_string()))?;

    // The size is checked here so a truncated transfer is retried against the
    // next source rather than surviving to fail verification at the very end,
    // after every other file has also been fetched.
    if written != file.byte_count as u64 {
        let _ = std::fs::remove_file(destination);
        return Err(DownloadError::AllSourcesFailed(format!(
            "received {written} bytes, expected {}",
            file.byte_count
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hosts_we_talk_to_are_the_ones_the_manifest_names() {
        assert!(is_approved("github.com"));
        assert!(is_approved("huggingface.co"));
        // The CDNs those two redirect to.
        assert!(is_approved("objects.githubusercontent.com"));
        assert!(is_approved("cdn-lfs.huggingface.co"));
    }

    /// A download that can be redirected anywhere is a download that can be
    /// pointed at anything.
    #[test]
    fn anything_else_is_refused_including_lookalikes() {
        for host in [
            "evil.example",
            "github.com.evil.example",
            "nothuggingface.co",
            "",
        ] {
            assert!(!is_approved(host), "{host} should be refused");
        }
    }

    /// Subdomains of an approved host are approved; a suffix that merely ends
    /// with the same letters is not.
    #[test]
    fn the_match_is_on_a_domain_boundary_not_a_string_suffix() {
        assert!(is_approved("us-1.cdn-lfs.huggingface.co"));
        assert!(!is_approved("evilgithub.com"));
    }

    #[test]
    fn a_source_is_tried_three_times_before_the_mirror_takes_over() {
        // Three, because the model is 739 MB and a source that failed three
        // times running is down rather than blinking.
        assert_eq!(ATTEMPTS_PER_SOURCE, 3);
    }
}

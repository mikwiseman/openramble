//! The claim that an install is complete.
//!
//! Ported from `ModelReadyMarker` in `ModelInstallLayout.swift`. The Mac writes
//! this file with a plain `JSONEncoder`, which means dates are **seconds since
//! 2001-01-01 UTC**, not since the Unix epoch. Getting that backwards does not
//! fail loudly — it produces a file that parses and lies about when the install
//! was verified. A strategy mismatch exactly like this one silently emptied the
//! dictation history once, which is why the offset is pinned by a test against
//! a value Swift actually produced.

use serde::{Deserialize, Serialize};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Seconds between the Unix epoch and Foundation's reference date.
///
/// Verified against `JSONEncoder`: `Date(timeIntervalSince1970: 0)` encodes as
/// `-978307200`.
pub const REFERENCE_DATE_OFFSET_SECONDS: f64 = 978_307_200.0;

/// A Foundation `Date` as it appears in JSON.
///
/// Kept as the raw reference-date seconds rather than a `SystemTime` so that
/// reading and rewriting a marker cannot perturb the value.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ReferenceDate(pub f64);

impl ReferenceDate {
    pub fn from_system_time(time: SystemTime) -> Self {
        let unix = time
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_secs_f64();
        ReferenceDate(unix - REFERENCE_DATE_OFFSET_SECONDS)
    }

    pub fn to_system_time(self) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs_f64(self.0 + REFERENCE_DATE_OFFSET_SECONDS)
    }

    pub fn now() -> Self {
        Self::from_system_time(SystemTime::now())
    }
}

/// One file as it was found at verification time.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InstalledFile {
    pub path: String,
    #[serde(rename = "byteCount")]
    pub byte_count: i64,
    #[serde(rename = "modifiedAt", skip_serializing_if = "Option::is_none")]
    pub modified_at: Option<ReferenceDate>,
}

/// Written last, after every file is in place and verified.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadyMarker {
    pub revision: String,
    #[serde(rename = "runtimeVersion")]
    pub runtime_version: String,
    #[serde(rename = "fileCount")]
    pub file_count: i32,
    #[serde(rename = "totalByteCount")]
    pub total_byte_count: i64,
    #[serde(rename = "verifiedAt")]
    pub verified_at: ReferenceDate,
    /// Absent in markers written by older versions. Those are still valid; they
    /// go through one full check and are rewritten in the current form.
    #[serde(rename = "installedFiles", skip_serializing_if = "Option::is_none")]
    pub installed_files: Option<Vec<InstalledFile>>,
}

impl ReadyMarker {
    pub fn parse(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Does this marker describe the install we are looking for?
    ///
    /// A marker left by a different revision or a different runtime is not a
    /// claim about this install, and trusting it would load a model the engine
    /// cannot read.
    pub fn describes(&self, revision: &str, runtime_version: &str) -> bool {
        self.revision == revision && self.runtime_version == runtime_version
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pinned against what Swift actually produced, not against my memory of
    /// which epoch Foundation uses.
    #[test]
    fn the_unix_epoch_encodes_the_way_swift_encodes_it() {
        let encoded = serde_json::to_string(&ReferenceDate::from_system_time(UNIX_EPOCH)).unwrap();
        assert_eq!(encoded, "-978307200.0");

        // And a second value Swift was asked for directly.
        let millennium = UNIX_EPOCH + Duration::from_secs(1_000_000);
        assert_eq!(
            ReferenceDate::from_system_time(millennium).0,
            -977_307_200.0
        );
    }

    #[test]
    fn a_date_survives_the_round_trip() {
        let now = SystemTime::now();
        let restored = ReferenceDate::from_system_time(now).to_system_time();
        let drift = restored
            .duration_since(now)
            .or_else(|_| now.duration_since(restored))
            .unwrap();
        assert!(drift < Duration::from_millis(1), "drifted by {drift:?}");
    }

    /// A marker written by the Mac must read here. If it stops doing so, an
    /// existing install stops being recognized and 739 MB is downloaded again.
    #[test]
    fn a_marker_written_by_the_mac_is_understood() {
        let json = r#"{
            "revision": "85ac09ea12fc4b1112fa76810059364bc6adc9de",
            "runtimeVersion": "transcribe.cpp 0.2.0",
            "fileCount": 1,
            "totalByteCount": 739508576,
            "verifiedAt": 776000000.5,
            "installedFiles": [
                {"path": "parakeet-tdt-0.6b-v3-Q8_0.gguf", "byteCount": 739508576, "modifiedAt": 775999999.0}
            ]
        }"#;
        let marker = ReadyMarker::parse(json).expect("must parse");
        assert_eq!(marker.file_count, 1);
        assert_eq!(marker.total_byte_count, 739_508_576);
        assert_eq!(marker.verified_at.0, 776_000_000.5);
        assert_eq!(marker.installed_files.as_ref().unwrap().len(), 1);
        assert!(marker.describes(
            "85ac09ea12fc4b1112fa76810059364bc6adc9de",
            "transcribe.cpp 0.2.0"
        ));
    }

    /// Older markers have no inventory. They are still valid claims.
    #[test]
    fn a_marker_without_an_inventory_still_reads() {
        let json = r#"{
            "revision": "r1", "runtimeVersion": "rt", "fileCount": 1,
            "totalByteCount": 10, "verifiedAt": 0
        }"#;
        let marker = ReadyMarker::parse(json).expect("must parse");
        assert!(marker.installed_files.is_none());
    }

    #[test]
    fn a_marker_for_another_revision_or_runtime_is_not_this_install() {
        let marker = ReadyMarker {
            revision: "r1".into(),
            runtime_version: "transcribe.cpp 0.2.0".into(),
            file_count: 1,
            total_byte_count: 10,
            verified_at: ReferenceDate(0.0),
            installed_files: None,
        };
        assert!(marker.describes("r1", "transcribe.cpp 0.2.0"));
        assert!(!marker.describes("r2", "transcribe.cpp 0.2.0"));
        // A model built for a runtime we no longer run is not loadable.
        assert!(!marker.describes("r1", "transcribe.cpp 0.3.0"));
    }

    #[test]
    fn the_written_form_uses_the_mac_field_names() {
        let marker = ReadyMarker {
            revision: "r1".into(),
            runtime_version: "rt".into(),
            file_count: 2,
            total_byte_count: 30,
            verified_at: ReferenceDate(1.0),
            installed_files: Some(vec![InstalledFile {
                path: "a.gguf".into(),
                byte_count: 30,
                modified_at: None,
            }]),
        };
        let json = marker.to_json().unwrap();
        for key in [
            "\"runtimeVersion\"",
            "\"fileCount\"",
            "\"totalByteCount\"",
            "\"verifiedAt\"",
            "\"installedFiles\"",
            "\"byteCount\"",
        ] {
            assert!(json.contains(key), "missing {key} in {json}");
        }
        // A file with no recorded timestamp omits the key rather than writing
        // null, which is what Swift's optional encoding does.
        assert!(!json.contains("modifiedAt"), "{json}");
    }
}

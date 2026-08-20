//! Recent dictations, with the audio that produced them.
//!
//! Ported from `apps/macos/OpenRamble/System/DictationHistoryStore.swift`. This
//! is the one place in the product where transcripts and recordings are kept
//! after quit, which is why it is bounded by an explicit retention setting and
//! why deleting an entry takes its audio with it.
//!
//! The on-disk form matches the Mac's exactly, dates included. A plain Swift
//! `JSONEncoder` writes dates as seconds since 2001, and an encoder configured
//! differently from its decoder produces a history that reads back empty —
//! silently, with no error. That has already happened once in this codebase.

pub use ramble_model::ReferenceDate;
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};

/// How many takes are kept by default.
///
/// Five. Enough to find the one that went wrong, few enough that a person is
/// not unknowingly accumulating a transcript of their week.
pub const DEFAULT_LIMIT: usize = 5;

/// The most that may be kept, whatever a setting says.
///
/// The number has to stay finite: this is audio, and the folder is the only
/// thing standing between a retention setting and a disk.
pub const MAXIMUM_LIMIT: usize = 50;

/// One finished dictation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistoryEntry {
    /// The Mac writes a UUID string; kept verbatim so a file round-trips.
    pub id: String,
    pub date: ReferenceDate,
    pub text: String,
    /// The take's audio, if it is still on disk. A file can go missing — someone
    /// may have deleted it, or a crash may have left the record without it — and
    /// an entry whose text is intact is still worth showing.
    #[serde(rename = "audioFileName", skip_serializing_if = "Option::is_none")]
    pub audio_file_name: Option<String>,
}

/// The history on disk.
pub struct HistoryStore {
    directory: PathBuf,
}

impl HistoryStore {
    pub fn new(directory: impl Into<PathBuf>) -> Self {
        HistoryStore {
            directory: directory.into(),
        }
    }

    fn index_path(&self) -> PathBuf {
        self.directory.join("history.json")
    }

    /// Read what is stored.
    ///
    /// A truncated or hand-edited index reads as empty rather than taking the
    /// application down: history is a convenience, and losing it must never cost
    /// someone their ability to dictate.
    pub fn load(&self) -> Vec<HistoryEntry> {
        self.try_load().unwrap_or_default()
    }

    /// Read history without hiding disk or decoding failures.
    ///
    /// The UI uses this path so a damaged index cannot be mistaken for an empty
    /// history and then overwritten by the next mutation.
    pub fn try_load(&self) -> std::io::Result<Vec<HistoryEntry>> {
        let bytes = match std::fs::read(self.index_path()) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        serde_json::from_slice(&bytes).map_err(std::io::Error::other)
    }

    fn write(&self, entries: &[HistoryEntry]) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.directory)?;
        let json = serde_json::to_vec(entries).map_err(std::io::Error::other)?;
        let mut temporary = tempfile::NamedTempFile::new_in(&self.directory)?;
        temporary.write_all(&json)?;
        temporary.as_file().sync_all()?;
        temporary
            .persist(self.index_path())
            .map_err(|error| error.error)?;
        Ok(())
    }

    /// The audio for an entry, if the file is still there.
    pub fn audio_path(&self, entry: &HistoryEntry) -> Option<PathBuf> {
        let name = entry.audio_file_name.as_ref()?;
        let path = self.directory.join(name);
        path.exists().then_some(path)
    }

    /// Record a finished dictation, moving its audio in beside the transcript.
    ///
    /// Blank text is not a dictation and is not recorded — otherwise every silent
    /// take would leave an empty row.
    pub fn record(
        &self,
        text: &str,
        audio: Option<&Path>,
        limit: usize,
        now: ReferenceDate,
        id: String,
    ) -> std::io::Result<Vec<HistoryEntry>> {
        if text.trim().is_empty() {
            return self.try_load();
        }
        std::fs::create_dir_all(&self.directory)?;
        // Refuse corruption before copying audio, otherwise a failed mutation
        // leaves an orphan recording on disk.
        let mut entries = self.try_load()?;

        let audio_file_name = match audio {
            Some(source) => {
                let name = format!("{id}.wav");
                std::fs::copy(source, self.directory.join(&name))?;
                Some(name)
            }
            None => None,
        };

        // Newest first: that is the one someone is looking for.
        entries.insert(
            0,
            HistoryEntry {
                id,
                date: now,
                text: text.to_string(),
                audio_file_name: audio_file_name.clone(),
            },
        );
        let evicted = self.trim(&mut entries, limit);
        if let Err(error) = self.write(&entries) {
            if let Some(name) = &audio_file_name {
                if let Err(cleanup_error) = std::fs::remove_file(self.directory.join(name)) {
                    eprintln!(
                        "Could not remove the unindexed history recording after a write failure: {cleanup_error}"
                    );
                }
            }
            return Err(error);
        }
        self.remove_audio_files(evicted)?;
        Ok(entries)
    }

    /// Apply a retention setting to what is already stored.
    ///
    /// Lowering the setting has to act on the existing history, not only on what
    /// arrives next — otherwise a person who reduces it keeps everything they
    /// were trying to remove.
    pub fn apply_limit(&self, limit: usize) -> std::io::Result<Vec<HistoryEntry>> {
        let mut entries = self.try_load()?;
        let evicted = self.trim(&mut entries, limit);
        self.write(&entries)?;
        self.remove_audio_files(evicted)?;
        Ok(entries)
    }

    /// Drop everything past the limit, taking the audio with it.
    ///
    /// Audio is the expensive part. An entry that falls off the end must not
    /// leave its recording behind, or the folder grows without bound while the
    /// list looks correctly short.
    fn trim(&self, entries: &mut Vec<HistoryEntry>, limit: usize) -> Vec<String> {
        let limit = limit.clamp(1, MAXIMUM_LIMIT);
        let evicted = entries
            .iter()
            .skip(limit)
            .filter_map(|entry| entry.audio_file_name.clone())
            .collect();
        entries.truncate(limit);
        evicted
    }

    fn remove_audio_files(&self, names: Vec<String>) -> std::io::Result<()> {
        for name in names {
            match std::fs::remove_file(self.directory.join(name)) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    pub fn delete(&self, id: &str) -> std::io::Result<Vec<HistoryEntry>> {
        let mut entries = self.try_load()?;
        let audio = if let Some(position) = entries.iter().position(|entry| entry.id == id) {
            let removed = entries.remove(position);
            removed.audio_file_name.into_iter().collect()
        } else {
            Vec::new()
        };
        self.write(&entries)?;
        self.remove_audio_files(audio)?;
        Ok(entries)
    }

    /// Remove every transcript and every recording.
    pub fn delete_all(&self) -> std::io::Result<()> {
        let audio = self
            .try_load()?
            .into_iter()
            .filter_map(|entry| entry.audio_file_name)
            .collect();
        self.write(&[])?;
        self.remove_audio_files(audio)
    }

    /// A stored retention value, made safe.
    pub fn effective_limit(stored: Option<i64>) -> usize {
        match stored {
            // Zero would mean keeping nothing, which is not what the setting
            // offers — the way to keep nothing is to turn history off.
            Some(value) if value > 0 => (value as usize).min(MAXIMUM_LIMIT),
            _ => DEFAULT_LIMIT,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, HistoryStore) {
        let directory = tempfile::tempdir().unwrap();
        let store = HistoryStore::new(directory.path());
        (directory, store)
    }

    fn at(seconds: f64) -> ReferenceDate {
        ReferenceDate(seconds)
    }

    fn wav(directory: &Path, name: &str) -> PathBuf {
        let path = directory.join(name);
        std::fs::write(&path, b"fake wav").unwrap();
        path
    }

    /// The point of the feature: it is still there after quit. This also catches
    /// a mismatch between how entries are written and how they are read — a
    /// disagreement about dates loses the whole history at the next launch,
    /// silently and with no error.
    #[test]
    fn entries_survive_a_reload() {
        let (directory, store) = store();
        store
            .record("first take", None, 5, at(1.0), "a".into())
            .unwrap();
        store
            .record("second take", None, 5, at(2.0), "b".into())
            .unwrap();

        let reopened = HistoryStore::new(directory.path()).load();
        assert_eq!(
            reopened.iter().map(|e| e.text.as_str()).collect::<Vec<_>>(),
            vec!["second take", "first take"]
        );
        assert_eq!(reopened[0].date, at(2.0));
    }

    #[test]
    fn blank_text_is_not_a_dictation() {
        let (_directory, store) = store();
        let entries = store
            .record("   \n ", None, 5, at(1.0), "a".into())
            .unwrap();
        assert!(entries.is_empty());
    }

    #[test]
    fn the_list_is_trimmed_to_the_limit_newest_first() {
        let (_directory, store) = store();
        for index in 0..8 {
            store
                .record(
                    &format!("take {index}"),
                    None,
                    5,
                    at(index as f64),
                    index.to_string(),
                )
                .unwrap();
        }
        let entries = store.load();
        assert_eq!(entries.len(), 5);
        assert_eq!(entries[0].text, "take 7");
    }

    /// Audio is the expensive part: an evicted entry must not leave its
    /// recording behind while the list looks correctly short.
    #[test]
    fn an_evicted_entry_takes_its_audio_with_it() {
        let (directory, store) = store();
        let source = wav(directory.path(), "source.wav");
        store
            .record("oldest", Some(&source), 1, at(1.0), "old".into())
            .unwrap();
        let stored = directory.path().join("old.wav");
        assert!(stored.exists());

        store
            .record("newest", None, 1, at(2.0), "new".into())
            .unwrap();
        assert_eq!(store.load().len(), 1);
        assert!(
            !stored.exists(),
            "the evicted take's audio is still on disk"
        );
    }

    #[test]
    fn lowering_the_limit_acts_on_what_is_already_stored() {
        let (_directory, store) = store();
        for index in 0..6 {
            store
                .record(
                    &format!("take {index}"),
                    None,
                    10,
                    at(index as f64),
                    index.to_string(),
                )
                .unwrap();
        }
        assert_eq!(store.apply_limit(2).unwrap().len(), 2);
        assert_eq!(store.load()[0].text, "take 5");
    }

    #[test]
    fn deleting_an_entry_removes_it_and_its_audio() {
        let (directory, store) = store();
        let source = wav(directory.path(), "source.wav");
        store
            .record("keep", None, 5, at(1.0), "keep".into())
            .unwrap();
        store
            .record("remove", Some(&source), 5, at(2.0), "gone".into())
            .unwrap();
        let stored = directory.path().join("gone.wav");

        let remaining = store.delete("gone").unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].text, "keep");
        assert!(!stored.exists());
    }

    #[test]
    fn deleting_everything_leaves_nothing_behind() {
        let (directory, store) = store();
        let source = wav(directory.path(), "source.wav");
        store
            .record("one", Some(&source), 5, at(1.0), "one".into())
            .unwrap();
        store.delete_all().unwrap();
        assert!(store.load().is_empty());
        assert!(!directory.path().join("one.wav").exists());
    }

    /// A record whose file has gone is still worth showing: the text is the part
    /// people came for.
    #[test]
    fn an_entry_whose_audio_vanished_still_loads() {
        let (directory, store) = store();
        let source = wav(directory.path(), "source.wav");
        store
            .record("with audio", Some(&source), 5, at(1.0), "x".into())
            .unwrap();
        std::fs::remove_file(directory.path().join("x.wav")).unwrap();

        let entry = &store.load()[0];
        assert_eq!(entry.text, "with audio");
        assert_eq!(store.audio_path(entry), None);
    }

    /// A truncated index must not take the application down. Losing history is a
    /// nuisance; losing the ability to dictate is not.
    #[test]
    fn a_corrupt_index_reads_as_empty() {
        let (directory, store) = store();
        std::fs::create_dir_all(directory.path()).unwrap();
        std::fs::write(directory.path().join("history.json"), b"{ not json").unwrap();
        assert!(store.load().is_empty());
    }

    #[test]
    fn a_corrupt_index_cannot_be_silently_overwritten() {
        let (directory, store) = store();
        std::fs::create_dir_all(directory.path()).unwrap();
        let index = directory.path().join("history.json");
        std::fs::write(&index, b"{ not json").unwrap();

        assert!(store
            .record("new words", None, 5, at(1.0), "new".into())
            .is_err());
        assert_eq!(std::fs::read(index).unwrap(), b"{ not json");
    }

    #[test]
    fn the_retention_setting_stays_finite_and_never_means_nothing() {
        assert_eq!(HistoryStore::effective_limit(None), DEFAULT_LIMIT);
        // Zero would mean keeping nothing, which is not what the setting offers.
        assert_eq!(HistoryStore::effective_limit(Some(0)), DEFAULT_LIMIT);
        assert_eq!(HistoryStore::effective_limit(Some(-3)), DEFAULT_LIMIT);
        assert_eq!(HistoryStore::effective_limit(Some(20)), 20);
        assert_eq!(HistoryStore::effective_limit(Some(10_000)), MAXIMUM_LIMIT);
    }

    /// A history written by the Mac must read here, dates included.
    #[test]
    fn a_history_written_by_the_mac_is_understood() {
        let (directory, store) = store();
        std::fs::create_dir_all(directory.path()).unwrap();
        std::fs::write(
            directory.path().join("history.json"),
            r#"[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","date":808763809.006857,
                 "text":"\u043f\u0440\u0438\u0432\u0435\u0442","audioFileName":"E621E1F8.wav"}]"#
                .as_bytes(),
        )
        .unwrap();

        let entries = store.load();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].date, at(808_763_809.006_857));
        assert_eq!(entries[0].audio_file_name.as_deref(), Some("E621E1F8.wav"));
        // Asserted explicitly: a parse failure returns an empty history rather
        // than an error, so only checking the count would let the exact defect
        // this test exists for slip through as a pass.
        assert_eq!(
            entries[0].text,
            "\u{043f}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
        );
    }
}

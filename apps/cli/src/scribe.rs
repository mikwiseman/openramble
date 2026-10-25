//! The API's request fields, responses and errors, in ElevenLabs Scribe's shape.
//!
//! Callers written for Scribe work unchanged, with three honest differences:
//! there is no language detection (`language_code` is null rather than a
//! guess), there is no speaker separation (`diarize=true` is refused rather
//! than answered with empty speakers), and there is no per-word confidence
//! (no `logprob` rather than a made-up one).
//!
//! Every error message is fixed English: it never repeats a file name, a key
//! term or anything the audio said.

use std::ops::Range;

use ramble_engine::Recognized;
use serde_json::{json, Value};

/// The budget a request gets when neither it nor its key names one: within
/// the meetings caller's 30-minute timeout, with room for the upload.
pub const DEFAULT_DEADLINE_S: f64 = 1620.0;
pub const MAX_DEADLINE_S: f64 = 86_400.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Granularity {
    Word,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    /// ElevenLabs Scribe's response.
    Scribe,
    /// The command-line tool's JSON.
    OpenRamble,
}

/// What a request asked for, once validated.
#[derive(Debug, Clone, PartialEq)]
pub struct Params {
    pub granularity: Granularity,
    /// Clean Verbatim: hesitations and stutters removed.
    pub no_verbatim: bool,
    pub format: Format,
    /// How long the caller waits in all, upload included, if it said.
    pub deadline_s: Option<f64>,
}

/// An error response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    pub status: u16,
    /// `detail.status` and `detail.code`.
    pub code: &'static str,
    pub message: &'static str,
    pub retry_after_s: Option<u64>,
}

impl ApiError {
    const fn new(status: u16, code: &'static str, message: &'static str) -> Self {
        ApiError {
            status,
            code,
            message,
            retry_after_s: None,
        }
    }

    pub fn invalid(message: &'static str) -> Self {
        ApiError::new(400, "invalid_parameters", message)
    }

    pub fn unsupported(message: &'static str) -> Self {
        ApiError::new(400, "unsupported_parameter", message)
    }

    pub fn diarization() -> Self {
        ApiError::new(
            400,
            "diarization_unsupported",
            "This server cannot separate speakers. Send one file per speaker with diarize=false.",
        )
    }

    pub fn invalid_key() -> Self {
        ApiError::new(
            401,
            "invalid_api_key",
            "The xi-api-key header is missing or not valid.",
        )
    }

    pub fn not_found() -> Self {
        ApiError::new(404, "not_found", "There is nothing at this path.")
    }

    pub fn method_not_allowed() -> Self {
        ApiError::new(
            405,
            "method_not_allowed",
            "This path does not accept that method.",
        )
    }

    pub fn too_large() -> Self {
        ApiError::new(413, "file_too_large", "The upload is larger than 2 GiB.")
    }

    pub fn invalid_audio() -> Self {
        ApiError::new(
            422,
            "invalid_audio",
            "No audio could be decoded from the file.",
        )
    }

    pub fn too_long() -> Self {
        ApiError::new(422, "audio_too_long", "The audio is longer than 12 hours.")
    }

    pub fn too_long_for_deadline() -> Self {
        ApiError::new(
            422,
            "audio_too_long_for_deadline",
            "The audio cannot be transcribed within deadline_s even on an idle server.",
        )
    }

    pub fn busy(retry_after_s: u64) -> Self {
        ApiError {
            retry_after_s: Some(retry_after_s),
            ..ApiError::new(
                429,
                "system_busy",
                "The server is busy. Retry after the Retry-After seconds.",
            )
        }
    }

    pub fn starting() -> Self {
        ApiError {
            retry_after_s: Some(15),
            ..ApiError::new(
                429,
                "starting",
                "The server is loading its engines. Retry after the Retry-After seconds.",
            )
        }
    }

    pub fn shutting_down() -> Self {
        ApiError {
            retry_after_s: Some(60),
            ..ApiError::new(
                429,
                "shutting_down",
                "The server is restarting. Retry after the Retry-After seconds.",
            )
        }
    }

    pub fn internal() -> Self {
        ApiError::new(500, "internal_error", "The recognizer failed on this file.")
    }

    /// `{"detail":{"status":…,"code":…,"message":…}}`
    pub fn body(&self) -> Value {
        json!({"detail": {"status": self.code, "code": self.code, "message": self.message}})
    }
}

/// Read a boolean the way form posts spell them.
fn boolean(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Some(true),
        "false" | "0" | "no" => Some(false),
        _ => None,
    }
}

/// Validate the request's fields (form fields and query string together).
/// Unknown fields are ignored; for a repeated field the last one counts,
/// except `keyterms`, which is accepted and ignored in any number.
pub fn params(fields: &[(String, String)]) -> Result<Params, ApiError> {
    let mut params = Params {
        granularity: Granularity::Word,
        no_verbatim: false,
        format: Format::Scribe,
        deadline_s: None,
    };
    let flag = |value: &str| boolean(value).ok_or(ApiError::invalid(BAD_BOOLEAN));
    for (name, value) in fields {
        match name.as_str() {
            "timestamps_granularity" => {
                params.granularity =
                    match value.trim() {
                        "word" => Granularity::Word,
                        "none" => Granularity::None,
                        "character" => return Err(ApiError::unsupported(
                            "timestamps_granularity=character is not supported; use word or none.",
                        )),
                        _ => {
                            return Err(ApiError::invalid(
                                "timestamps_granularity must be word or none.",
                            ))
                        }
                    }
            }
            "diarize" => {
                if flag(value)? {
                    return Err(ApiError::diarization());
                }
            }
            "no_verbatim" => params.no_verbatim = flag(value)?,
            "tag_audio_events" => {
                flag(value)?;
            }
            "webhook" => {
                if flag(value)? {
                    return Err(ApiError::unsupported(
                        "webhook=true is not supported; the response carries the transcript.",
                    ));
                }
            }
            "use_multi_channel" => {
                if flag(value)? {
                    return Err(ApiError::unsupported(
                        "use_multi_channel=true is not supported; send one file per channel.",
                    ));
                }
            }
            "cloud_storage_url" => {
                if !value.trim().is_empty() {
                    return Err(ApiError::unsupported(
                        "cloud_storage_url is not supported; upload the file.",
                    ));
                }
            }
            "file_format" => {
                if value.trim() != "other" {
                    return Err(ApiError::unsupported(
                        "Only file_format=other is supported; send the file as it is.",
                    ));
                }
            }
            "output_format" => {
                params.format = match value.trim() {
                    "openramble" => Format::OpenRamble,
                    "scribe" | "json" | "" => Format::Scribe,
                    _ => {
                        return Err(ApiError::invalid(
                            "output_format must be openramble or omitted.",
                        ))
                    }
                }
            }
            "deadline_s" => {
                params.deadline_s = Some(
                    value
                        .trim()
                        .parse::<f64>()
                        .ok()
                        .filter(|s| s.is_finite() && *s > 0.0 && *s <= MAX_DEADLINE_S)
                        .ok_or(ApiError::invalid(
                            "deadline_s must be a number of seconds above 0 and at most 86400.",
                        ))?,
                );
            }
            // model_id, language_code, num_speakers, keyterms and anything
            // else: accepted and ignored
            _ => {}
        }
    }
    Ok(params)
}

const BAD_BOOLEAN: &str = "A boolean field must be true, false, 1, 0, yes or no.";

/// One word with its place in the file, in milliseconds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimedWord {
    pub text: String,
    pub start_ms: u64,
    pub end_ms: u64,
}

/// The words of every piece, placed in the file, in order. Times never go
/// backwards: a word that starts before the previous one ended is moved to
/// that end. A piece with text but no word rows (not seen from Parakeet) is
/// kept as one entry spanning the piece, so no text is lost.
pub fn timed_words(pieces: &[Range<u64>], recognized: &[Recognized]) -> Vec<TimedWord> {
    let mut words = Vec::new();
    let mut last_end = 0;
    for (piece, heard) in pieces.iter().zip(recognized) {
        let offset = piece.start / 16;
        let rows: Vec<(String, u64, u64)> = if heard.words.is_empty() {
            let text = heard.text.trim();
            if text.is_empty() {
                continue;
            }
            vec![(text.to_string(), 0, (piece.end - piece.start) / 16)]
        } else {
            heard
                .words
                .iter()
                .map(|w| (w.text.clone(), u64::from(w.start_ms), u64::from(w.end_ms)))
                .collect()
        };
        for (text, start, end) in rows {
            let start_ms = (offset + start).max(last_end);
            let end_ms = (offset + end).max(start_ms);
            last_end = end_ms;
            words.push(TimedWord {
                text,
                start_ms,
                end_ms,
            });
        }
    }
    words
}

/// The text the words make, joined by single spaces.
pub fn text(words: &[TimedWord]) -> String {
    words
        .iter()
        .map(|word| word.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

fn seconds(ms: u64) -> f64 {
    ms as f64 / 1000.0
}

/// The Scribe response. Words alternate with the spaces between them, so
/// joining every entry's text gives `text` exactly.
pub fn response(words: &[TimedWord], granularity: Granularity, id: &str) -> Value {
    let mut entries = Vec::new();
    if granularity == Granularity::Word {
        for (index, word) in words.iter().enumerate() {
            if index > 0 {
                let previous = words[index - 1].end_ms;
                entries.push(json!({
                    "text": " ",
                    "start": seconds(previous),
                    "end": seconds(word.start_ms.max(previous)),
                    "type": "spacing",
                    "speaker_id": null,
                }));
            }
            entries.push(json!({
                "text": word.text,
                "start": seconds(word.start_ms),
                "end": seconds(word.end_ms),
                "type": "word",
                "speaker_id": null,
            }));
        }
    }
    json!({
        "language_code": null,
        "language_probability": null,
        "text": text(words),
        "words": entries,
        "transcription_id": id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use ramble_engine::Word;

    fn fields(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(n, v)| (n.to_string(), v.to_string()))
            .collect()
    }

    fn word(text: &str, start_ms: u32, end_ms: u32) -> Word {
        Word {
            text: text.into(),
            start_ms,
            end_ms,
        }
    }

    fn heard(words: Vec<Word>) -> Recognized {
        Recognized {
            text: words
                .iter()
                .map(|w| w.text.as_str())
                .collect::<Vec<_>>()
                .join(" "),
            words,
            truncated: false,
        }
    }

    #[test]
    fn the_meetings_and_voice_note_requests_parse() {
        let mut meeting = fields(&[
            ("model_id", "scribe_v2"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
            ("diarize", "false"),
            ("no_verbatim", "true"),
            ("num_speakers", "1"),
            ("deadline_s", "14400"),
        ]);
        for i in 0..90 {
            meeting.push(("keyterms".into(), format!("term {i}")));
        }
        meeting.push(("something_new".into(), "whatever".into()));
        assert_eq!(
            params(&meeting),
            Ok(Params {
                granularity: Granularity::Word,
                no_verbatim: true,
                format: Format::Scribe,
                deadline_s: Some(14_400.0),
            })
        );
        let note = fields(&[
            ("model_id", "scribe_v2"),
            ("timestamps_granularity", "none"),
            ("tag_audio_events", "false"),
            ("language_code", "ru"),
            ("output_format", "openramble"),
        ]);
        assert_eq!(
            params(&note),
            Ok(Params {
                granularity: Granularity::None,
                no_verbatim: false,
                format: Format::OpenRamble,
                deadline_s: None,
            })
        );
        assert_eq!(params(&[]).unwrap().granularity, Granularity::Word);
    }

    #[test]
    fn booleans_are_read_the_way_forms_write_them() {
        for yes in ["true", "TRUE", "1", "yes", "Yes", " true "] {
            assert!(
                params(&fields(&[("no_verbatim", yes)]))
                    .unwrap()
                    .no_verbatim
            );
        }
        for no in ["false", "False", "0", "no", "NO"] {
            assert!(!params(&fields(&[("no_verbatim", no)])).unwrap().no_verbatim);
        }
        for bad in ["", "y", "2", "on", "truthy"] {
            for name in [
                "no_verbatim",
                "diarize",
                "tag_audio_events",
                "webhook",
                "use_multi_channel",
            ] {
                assert_eq!(
                    params(&fields(&[(name, bad)])).unwrap_err().code,
                    "invalid_parameters",
                    "{name}={bad:?}"
                );
            }
        }
    }

    #[test]
    fn each_refused_parameter_says_why() {
        let code = |pairs: &[(&str, &str)]| params(&fields(pairs)).unwrap_err();
        let diarize = code(&[("diarize", "true")]);
        assert_eq!(
            (diarize.status, diarize.code),
            (400, "diarization_unsupported")
        );
        assert!(diarize.message.contains("diarize=false"));
        for refused in [
            &[("timestamps_granularity", "character")][..],
            &[("cloud_storage_url", "https://example.com/a.m4a")],
            &[("webhook", "true")],
            &[("use_multi_channel", "true")],
            &[("file_format", "pcm_s16le_16")],
        ] {
            let error = code(refused);
            assert_eq!(
                (error.status, error.code),
                (400, "unsupported_parameter"),
                "{refused:?}"
            );
        }
        for invalid in [
            &[("timestamps_granularity", "segment")][..],
            &[("deadline_s", "0")],
            &[("deadline_s", "86401")],
            &[("deadline_s", "soon")],
            &[("deadline_s", "NaN")],
            &[("output_format", "srt")],
        ] {
            let error = code(invalid);
            assert_eq!(
                (error.status, error.code),
                (400, "invalid_parameters"),
                "{invalid:?}"
            );
        }
        // the harmless spellings of the same fields are fine
        let fine = fields(&[
            ("webhook", "false"),
            ("use_multi_channel", "false"),
            ("cloud_storage_url", ""),
            ("file_format", "other"),
        ]);
        assert!(params(&fine).is_ok());
    }

    #[test]
    fn words_alternate_with_spaces_and_join_to_the_text() {
        let pieces = [16_000..336_000, 400_000..720_000];
        let recognized = [
            heard(vec![word("Привет,", 120, 480), word("мир.", 520, 900)]),
            heard(vec![
                word("Second", 0, 300),
                // overlapping and out of order: must not go backwards
                word("piece", 250, 200),
                word("here.", 400, 700),
            ]),
        ];
        let words = timed_words(&pieces, &recognized);
        let body = response(&words, Granularity::Word, "or_test");
        let entries = body["words"].as_array().unwrap();
        assert_eq!(entries.len(), 2 * 5 - 1);
        let joined: String = entries
            .iter()
            .map(|e| e["text"].as_str().unwrap())
            .collect();
        assert_eq!(joined, body["text"].as_str().unwrap());
        assert_eq!(body["text"], "Привет, мир. Second piece here.");
        let mut last = 0.0;
        for (index, entry) in entries.iter().enumerate() {
            let kind = if index % 2 == 0 { "word" } else { "spacing" };
            assert_eq!(entry["type"], kind);
            assert!(entry["speaker_id"].is_null());
            assert!(entry.get("logprob").is_none());
            let (start, end) = (
                entry["start"].as_f64().unwrap(),
                entry["end"].as_f64().unwrap(),
            );
            assert!(start.is_finite() && end.is_finite());
            assert!(start >= last && end >= start, "{entry}");
            for time in [start, end] {
                assert_eq!(
                    (time * 1000.0).round() / 1000.0,
                    time,
                    "three decimals: {time}"
                );
            }
            last = end;
        }
        // file offsets: the first piece starts at 1 s
        assert_eq!(entries[0]["start"], 1.12);
        assert_eq!(entries[0]["end"], 1.48);
        assert_eq!(entries[1]["start"], 1.48);
        assert_eq!(entries[1]["end"], 1.52);
        assert_eq!(entries[4]["start"], 25.0);
        assert!(body["language_code"].is_null() && body["language_probability"].is_null());
        assert_eq!(body["transcription_id"], "or_test");
    }

    #[test]
    fn no_word_times_and_silence_have_their_own_shapes() {
        let piece = 0..32_000;
        let words = timed_words(&[piece], &[heard(vec![word("Hello.", 0, 400)])]);
        let plain = response(&words, Granularity::None, "or_a");
        assert_eq!(plain["text"], "Hello.");
        assert_eq!(plain["words"], json!([]));

        let silence = response(&[], Granularity::Word, "or_b");
        assert_eq!(
            silence,
            json!({"language_code": null, "language_probability": null, "text": "",
                   "words": [], "transcription_id": "or_b"})
        );
        assert!(silence.get("detail").is_none() && silence.get("error").is_none());
    }

    #[test]
    fn a_piece_with_text_and_no_word_rows_keeps_its_text() {
        let pieces = [32_000..64_000, 64_000..80_000];
        let recognized = [
            Recognized {
                text: " untimed words ".into(),
                ..Default::default()
            },
            Recognized::default(),
        ];
        let words = timed_words(&pieces, &recognized);
        assert_eq!(
            words,
            vec![TimedWord {
                text: "untimed words".into(),
                start_ms: 2_000,
                end_ms: 4_000
            }]
        );
    }

    #[test]
    fn errors_have_the_detail_shape_and_fixed_messages() {
        let errors = [
            ApiError::invalid("x"),
            ApiError::unsupported("x"),
            ApiError::diarization(),
            ApiError::invalid_key(),
            ApiError::not_found(),
            ApiError::method_not_allowed(),
            ApiError::too_large(),
            ApiError::invalid_audio(),
            ApiError::too_long(),
            ApiError::too_long_for_deadline(),
            ApiError::busy(30),
            ApiError::shutting_down(),
            ApiError::internal(),
        ];
        for error in &errors {
            let body = error.body();
            let detail = body["detail"].as_object().unwrap();
            assert_eq!(detail.len(), 3);
            assert_eq!(detail["status"], error.code);
            assert_eq!(detail["code"], error.code);
            assert!(!detail["message"].as_str().unwrap().is_empty());
            assert_eq!(
                error.retry_after_s.is_some(),
                error.status == 429,
                "{error:?}"
            );
        }
        assert_eq!(ApiError::busy(30).retry_after_s, Some(30));
        assert_eq!(ApiError::shutting_down().retry_after_s, Some(60));
    }
}

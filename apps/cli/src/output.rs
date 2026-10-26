//! What file mode writes, and the server's `output_format=openramble`.

use std::ops::Range;

use ramble_engine::Recognized;
use serde_json::json;

/// One piece of transcript, with times in seconds of the file.
#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    pub start: f64,
    pub end: f64,
    /// The `--segments` span it came from, if it had a label.
    pub label: Option<String>,
    pub text: String,
}

/// Pieces (in samples, each with its span's index) and what the engine heard
/// in them, as segments carrying their span's label. Pieces with no words are
/// left out.
pub fn segments(
    pieces: &[(Range<u64>, usize)],
    labels: &[Option<String>],
    recognized: &[Recognized],
) -> Vec<Segment> {
    pieces
        .iter()
        .zip(recognized)
        .filter_map(|((range, span), heard)| {
            let text = heard.text.trim();
            (!text.is_empty()).then(|| Segment {
                start: range.start as f64 / 16_000.0,
                end: range.end as f64 / 16_000.0,
                label: labels.get(*span).cloned().flatten(),
                text: text.to_string(),
            })
        })
        .collect()
}

/// The whole text: the segments joined by single spaces.
pub fn joined(segments: &[Segment]) -> String {
    segments
        .iter()
        .map(|segment| segment.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

/// `{"model","duration","elapsed","segments":[{"start","end","label","text"}],"text"}`
pub fn json(model: &str, duration: f64, elapsed: f64, segments: &[Segment]) -> serde_json::Value {
    let rows: Vec<_> = segments
        .iter()
        .map(|s| json!({"start": s.start, "end": s.end, "label": s.label, "text": s.text}))
        .collect();
    json!({
        "model": model,
        "duration": duration,
        "elapsed": elapsed,
        "segments": rows,
        "text": joined(segments),
    })
}

/// `[hh:mm:ss] label: text` lines.
pub fn text(segments: &[Segment]) -> String {
    segments
        .iter()
        .map(|s| match &s.label {
            Some(label) => format!("[{}] {label}: {}\n", clock(s.start, false), s.text),
            None => format!("[{}] {}\n", clock(s.start, false), s.text),
        })
        .collect()
}

pub fn srt(segments: &[Segment]) -> String {
    segments
        .iter()
        .enumerate()
        .map(|(i, s)| {
            format!(
                "{}\n{} --> {}\n{}\n\n",
                i + 1,
                clock(s.start, true),
                clock(s.end, true),
                s.text
            )
        })
        .collect()
}

fn clock(seconds: f64, srt: bool) -> String {
    let ms = (seconds.max(0.0) * 1000.0).round() as u64;
    let (h, m, s, rest) = (ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000);
    if srt {
        format!("{h:02}:{m:02}:{s:02},{rest:03}")
    } else {
        format!("{h:02}:{m:02}:{s:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn segments() -> Vec<Segment> {
        vec![
            Segment {
                start: 1.5,
                end: 4.25,
                label: Some("Anna".into()),
                text: "Hello there.".into(),
            },
            Segment {
                start: 3725.0,
                end: 3730.5,
                label: None,
                text: "Bye.".into(),
            },
        ]
    }

    #[test]
    fn the_json_has_exactly_the_documented_shape() {
        let value = json("parakeet-ultra-Q4_K_M", 3731.0, 12.5, &segments());
        let mut keys: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort();
        assert_eq!(keys, ["duration", "elapsed", "model", "segments", "text"]);
        assert_eq!(value["model"], "parakeet-ultra-Q4_K_M");
        assert_eq!(value["text"], "Hello there. Bye.");
        let row = value["segments"][0].as_object().unwrap();
        let mut keys: Vec<&str> = row.keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, ["end", "label", "start", "text"]);
        assert_eq!(value["segments"][0]["label"], "Anna");
        assert!(value["segments"][1]["label"].is_null());
        assert_eq!(value["segments"][1]["start"], 3725.0);
    }

    #[test]
    fn pieces_keep_their_span_labels_and_empty_pieces_go() {
        let heard = |text: &str| Recognized {
            text: text.into(),
            ..Default::default()
        };
        let pieces = [
            (16_000..48_000, 1),
            (48_000..64_000, 1),
            (80_000..96_000, 0),
        ];
        let labels = [None, Some("Boris".to_string())];
        let built = super::segments(
            &pieces,
            &labels,
            &[heard(" Hello. "), heard("  "), heard("Hi.")],
        );
        assert_eq!(
            built,
            vec![
                Segment {
                    start: 1.0,
                    end: 3.0,
                    label: Some("Boris".into()),
                    text: "Hello.".into()
                },
                Segment {
                    start: 5.0,
                    end: 6.0,
                    label: None,
                    text: "Hi.".into()
                },
            ]
        );
    }

    #[test]
    fn text_and_subtitles_carry_times_and_labels() {
        assert_eq!(
            text(&segments()),
            "[00:00:01] Anna: Hello there.\n[01:02:05] Bye.\n"
        );
        assert_eq!(
            srt(&segments()),
            "1\n00:00:01,500 --> 00:00:04,250\nHello there.\n\n\
             2\n01:02:05,000 --> 01:02:10,500\nBye.\n\n"
        );
    }
}

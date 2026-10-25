//! `no_verbatim=true`: the Mac's Clean Verbatim, with each word's time kept.
//!
//! Each piece's words go through `ramble_text::clean::clean` exactly as the
//! Mac's meeting transcripts do (spoken corrections off, no dictionary, no
//! paragraph breaks). Cleanup only deletes words, though it may move a capital
//! or a comma, so what survives is matched back onto the raw words in order by
//! letters and digits: the cleaned word supplies the text, the raw word its
//! times. If any cleaned word finds no raw word, the piece keeps its raw words
//! rather than guess.

use std::collections::HashSet;

use ramble_engine::{Recognized, Word};
use ramble_text::clean::{self, PromptMode};

/// The piece with hesitations and stutters removed.
pub fn clean(heard: &Recognized) -> Recognized {
    if heard.words.is_empty() {
        return Recognized {
            text: clean_text(heard.text.trim()),
            ..heard.clone()
        };
    }
    let joined = heard
        .words
        .iter()
        .map(|word| word.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let cleaned = clean_text(&joined);
    if cleaned == joined {
        return heard.clone();
    }
    match align(&heard.words, &cleaned) {
        Some(words) => Recognized {
            text: cleaned,
            words,
            truncated: heard.truncated,
        },
        None => heard.clone(),
    }
}

fn clean_text(text: &str) -> String {
    clean::clean(text, false, &HashSet::new(), PromptMode::Verbatim)
}

/// The letters and digits of a word, lowercased: what cleanup cannot change.
fn key(text: &str) -> String {
    text.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Each word of `cleaned` matched, in order, to a raw word with the same key.
fn align(raw: &[Word], cleaned: &str) -> Option<Vec<Word>> {
    let mut remaining = raw.iter();
    cleaned
        .split_whitespace()
        .map(|token| {
            let wanted = key(token);
            let source = remaining.by_ref().find(|word| key(&word.text) == wanted)?;
            Some(Word {
                text: token.to_string(),
                start_ms: source.start_ms,
                end_ms: source.end_ms,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Words 400 ms apart, each 300 ms long.
    fn heard(text: &str) -> Recognized {
        let words: Vec<Word> = text
            .split_whitespace()
            .enumerate()
            .map(|(i, w)| Word {
                text: w.into(),
                start_ms: i as u32 * 400,
                end_ms: i as u32 * 400 + 300,
            })
            .collect();
        Recognized {
            text: text.into(),
            words,
            truncated: false,
        }
    }

    fn joined(recognized: &Recognized) -> String {
        recognized
            .words
            .iter()
            .map(|w| w.text.as_str())
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn hesitations_go_and_the_words_left_keep_their_times() {
        let raw = heard("So we, uh, shipped the build. Um, it works.");
        let cleaned = clean(&raw);
        assert_eq!(cleaned.text, clean_text(&raw.text));
        assert_eq!(cleaned.text, "So we shipped the build. It works.");
        assert_eq!(joined(&cleaned), cleaned.text);
        let times: Vec<(String, u32)> = cleaned
            .words
            .iter()
            .map(|w| (w.text.clone(), w.start_ms))
            .collect();
        assert_eq!(
            times,
            [
                ("So", 0),
                ("we", 400),
                ("shipped", 1_200),
                ("the", 1_600),
                ("build.", 2_000),
                ("It", 2_800),
                ("works.", 3_200)
            ]
            .map(|(t, ms)| (t.to_string(), ms))
        );
    }

    #[test]
    fn a_stutter_collapses_and_a_russian_hesitation_goes() {
        let raw = heard("Мы мы обсудим, э, план на неделю.");
        let cleaned = clean(&raw);
        assert_eq!(cleaned.text, clean_text(&raw.text));
        assert_ne!(cleaned.text, raw.text);
        assert_eq!(joined(&cleaned), cleaned.text);
        assert!(!cleaned.words.iter().any(|w| key(&w.text) == "э"));

        let doubled = heard("Then the the team met.");
        let cleaned = clean(&doubled);
        assert_eq!(cleaned.text, clean_text(&doubled.text));
        assert_eq!(cleaned.words.len(), doubled.words.len() - 1);
        assert_eq!(joined(&cleaned), cleaned.text);
    }

    #[test]
    fn a_capital_moved_by_cleanup_lands_on_the_right_word() {
        let raw = heard("Um, then we left.");
        let cleaned = clean(&raw);
        assert_eq!(cleaned.text, clean_text(&raw.text));
        let first = &cleaned.words[0];
        assert_eq!(key(&first.text), "then");
        assert_eq!(first.start_ms, 400);
    }

    #[test]
    fn nothing_to_remove_changes_nothing() {
        let raw = heard("Plain words, nothing to remove.");
        assert_eq!(clean(&raw), raw);
    }

    #[test]
    fn a_cleaned_word_without_a_raw_word_keeps_the_piece_raw() {
        let raw = heard("one two three");
        assert_eq!(align(&raw.words, "one four"), None);
        assert_eq!(align(&raw.words, "three one"), None, "order matters");
        assert_eq!(align(&raw.words, "One, three.").unwrap().len(), 2);
    }

    #[test]
    fn a_piece_without_word_rows_is_cleaned_as_text() {
        let raw = Recognized {
            text: "Uh, hello there.".into(),
            ..Default::default()
        };
        assert_eq!(clean(&raw).text, clean_text("Uh, hello there."));
        assert!(clean(&raw).words.is_empty());
    }
}

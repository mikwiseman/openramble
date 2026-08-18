//! The custom dictionary: how a term was heard → how it should be written.
//!
//! Ported from `DictionaryReplacements.swift`.
//!
//! # Why there is no regular expression here
//!
//! The Swift version builds an `NSRegularExpression` per entry, using lookbehind
//! and lookahead for word boundaries. Rust's `regex` crate supports neither, and
//! reaching for a backtracking crate would buy a second regex engine whose
//! Unicode and alternation semantics differ from ICU's in ways nobody would
//! notice until a person's dictionary quietly stopped working on one platform.
//! Since both engines were only ever asked for one fixed pattern shape —
//! optional head words, a stem, an optional inflection ending, boundaries on
//! both sides — that shape is written out directly below. It is the same
//! decision either way, minus the risk that two engines disagree.

use serde::{Deserialize, Serialize};

/// One replacement.
///
/// This is what a dictionary is for: the model does not know the names a person
/// lives with every day, and writes "sentry" where they meant Sentry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DictionaryReplacement {
    /// Kept as the exact text that was stored rather than a parsed UUID, so a
    /// dictionary written by the Mac app round-trips through here byte for byte.
    pub id: String,
    /// What the model heard.
    pub spoken: String,
    /// What should appear in the text.
    pub written: String,
    /// Whether to expect Russian case endings on this entry.
    ///
    /// A property of the entry, not an inference from its letters. "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}" is a word
    /// and has cases. "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}" is not a word but a recognition artefact: it has no
    /// cases, but it does have "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0430}", which an inflecting stem would swallow along
    /// with the term.
    #[serde(default = "default_true")]
    pub inflects: bool,
    /// Whether to keep this term away from the acoustic prompt.
    ///
    /// A property of the entry, not a list in somebody else's file. Some terms
    /// sound exactly like an ordinary Russian word, and no threshold can
    /// separate the two — the honest word and the term produce the same text.
    #[serde(default)]
    pub no_acoustic_boost: bool,
    /// Whether this spelling may be used as a fuzzy phonetic candidate.
    ///
    /// Exact repairs are deliberately literal. Feeding a strangely merged phrase
    /// into the fuzzy matcher widens its blast radius past the measured output it
    /// was added for. A person's own entries keep the historical default of true.
    #[serde(default = "default_true")]
    pub allows_phonetic_matching: bool,
}

fn default_true() -> bool {
    true
}

impl DictionaryReplacement {
    /// An entry with the defaults a hand-written one gets.
    pub fn new(
        id: impl Into<String>,
        spoken: impl Into<String>,
        written: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            spoken: spoken.into(),
            written: written.into(),
            inflects: true,
            no_acoustic_boost: false,
            allows_phonetic_matching: true,
        }
    }
}

/// The first pass: exact matches, with Russian case endings.
///
/// Word boundaries are required. Without them a replacement of "код" → "code"
/// would rewrite the inside of "кодирование". Input case is ignored, because
/// recognition does not produce it consistently.
///
/// Replacements layer: a later rule may rewrite what an earlier one produced.
/// That is fixed by tests in the Swift suite and is not up for change.
pub fn apply_exact(replacements: &[DictionaryReplacement], text: &str) -> String {
    if replacements.is_empty() || text.is_empty() {
        return text.to_string();
    }

    // Longest spoken form first, or "pull" would fire inside "pull request".
    //
    // A *stable* sort, unlike Swift's `sorted(by:)`. Entries of equal length keep
    // their dictionary order here, while Swift's introsort may reorder them —
    // for two same-length entries that both match, the platforms could otherwise
    // produce different text. Pinning the order makes this side the defined one.
    let mut ordered: Vec<&DictionaryReplacement> = replacements.iter().collect();
    ordered.sort_by_key(|entry| std::cmp::Reverse(entry.spoken.chars().count()));

    let mut result = text.to_string();
    for replacement in ordered {
        let spoken = replacement
            .spoken
            .trim_matches(|c: char| c == ' ' || c == '\t');
        if spoken.is_empty() {
            continue;
        }
        result = replace_whole_words(spoken, &replacement.written, replacement.inflects, &result);
    }
    result
}

/// Case endings Russian adds to a borrowed word.
///
/// The list is closed and short on purpose: these are not "similar words" but
/// exactly the tails that make an exact match never fire. Order matters —
/// longest first, so the longest ending wins, matching the alternation order the
/// Swift pattern relies on.
const ENDINGS: &[&str] = &[
    "\u{0430}\u{043C}\u{0438}",
    "\u{044F}\u{043C}\u{0438}",
    "\u{043E}\u{0439}",
    "\u{0435}\u{0439}",
    "\u{043E}\u{043C}",
    "\u{0435}\u{043C}",
    "\u{043E}\u{0432}",
    "\u{0435}\u{0432}",
    "\u{0430}\u{043C}",
    "\u{044F}\u{043C}",
    "\u{0430}\u{0445}",
    "\u{044F}\u{0445}",
    "\u{0430}",
    "\u{0435}",
    "\u{0438}",
    "\u{044B}",
    "\u{0443}",
    "\u{044E}",
    "\u{044F}",
];

/// Is a case ending worth expecting?
///
/// Only for Cyrillic, and only from four letters up: on shorter words the tail is
/// too often the start of another word.
///
/// Words ending in a vowel ("\u{0444}\u{0438}\u{0433}\u{043C}\u{0430}" → "\u{0444}\u{0438}\u{0433}\u{043C}\u{0435}") deliberately do not qualify. Catching
/// them would mean trimming the final vowel — and then "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}" reduces to the stem
/// "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}", and "\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}" turns into "\u{0432} Sentry \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}". The price is that
/// such an entry only fires in the exact form it was written in.
fn is_inflectable(needle: &str) -> bool {
    let Some(last) = needle.split(' ').rfind(|w| !w.is_empty()) else {
        return false;
    };
    if last.chars().count() < 4 {
        return false;
    }
    needle.chars().all(|character| {
        // The hyphen is part of the term: the model writes "\u{0442}\u{0430}\u{0439}\u{043F}\u{0441}\u{043A}\u{0440}\u{0438}\u{043F}\u{0442}" as one word,
        // and only its tail inflects anyway.
        character == ' ' || character == '-' || ('\u{0400}'..='\u{04FF}').contains(&character)
    })
}

/// Case-insensitive character comparison.
fn eq_ignoring_case(a: char, b: char) -> bool {
    a == b || a.to_lowercase().eq(b.to_lowercase())
}

/// Is this character one that a word boundary must not sit inside?
///
/// Mirrors `\p{L}` and `\p{N}` in the Swift pattern's lookaround.
fn is_word_character(character: char) -> bool {
    character.is_alphabetic() || character.is_numeric()
}

fn boundary_before(text: &[char], position: usize) -> bool {
    position == 0 || !is_word_character(text[position - 1])
}

fn boundary_after(text: &[char], position: usize) -> bool {
    position >= text.len() || !is_word_character(text[position])
}

/// Match a literal sequence case-insensitively, returning the position after it.
fn match_literal(text: &[char], position: usize, literal: &[char]) -> Option<usize> {
    if position + literal.len() > text.len() {
        return None;
    }
    for (offset, &expected) in literal.iter().enumerate() {
        if !eq_ignoring_case(text[position + offset], expected) {
            return None;
        }
    }
    Some(position + literal.len())
}

/// Consume one or more whitespace characters, as `\s+` would.
fn match_whitespace(text: &[char], position: usize) -> Option<usize> {
    let mut cursor = position;
    while cursor < text.len() && text[cursor].is_whitespace() {
        cursor += 1;
    }
    (cursor > position).then_some(cursor)
}

/// Replace every whole-word occurrence of `needle`.
fn replace_whole_words(needle: &str, replacement: &str, inflected: bool, text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    let words: Vec<Vec<char>> = needle
        .split(' ')
        .filter(|w| !w.is_empty())
        .map(|w| w.chars().collect())
        .collect();

    // The literal branch takes the needle exactly as written, single spaces and
    // all, matching the Swift pattern that escapes the whole string.
    let use_inflection = inflected && !words.is_empty() && is_inflectable(needle);
    let literal: Vec<char> = needle.chars().collect();

    // For the inflecting branch: head words joined by whitespace, then the stem,
    // then an optional ending.
    //
    // A word ending in "\u{0439}" has that letter replaced by the ending rather than
    // followed by it ("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}" → "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{044F}"), so it is trimmed off the stem and
    // added back to the list of tails — otherwise the word would stop matching
    // itself.
    let (head, stem, tails): (Vec<Vec<char>>, Vec<char>, Vec<Vec<char>>) = if use_inflection {
        let last = words.last().expect("checked non-empty");
        let has_short_i = last.last() == Some(&'\u{0439}');
        let stem = if has_short_i {
            last[..last.len() - 1].to_vec()
        } else {
            last.clone()
        };
        let mut tails: Vec<Vec<char>> = Vec::with_capacity(ENDINGS.len() + 1);
        if has_short_i {
            tails.push(vec!['\u{0439}']);
        }
        tails.extend(ENDINGS.iter().map(|e| e.chars().collect::<Vec<char>>()));
        (words[..words.len() - 1].to_vec(), stem, tails)
    } else {
        (Vec::new(), Vec::new(), Vec::new())
    };

    let mut result = String::with_capacity(text.len());
    let mut index = 0;

    while index < characters.len() {
        let matched_end = if !boundary_before(&characters, index) {
            None
        } else if use_inflection {
            match_inflected(&characters, index, &head, &stem, &tails)
        } else {
            match_literal(&characters, index, &literal)
                .filter(|&end| boundary_after(&characters, end))
        };

        match matched_end {
            Some(end) if end > index => {
                result.push_str(replacement);
                index = end;
            }
            _ => {
                result.push(characters[index]);
                index += 1;
            }
        }
    }

    result
}

fn match_inflected(
    text: &[char],
    start: usize,
    head: &[Vec<char>],
    stem: &[char],
    tails: &[Vec<char>],
) -> Option<usize> {
    let mut cursor = start;
    for word in head {
        cursor = match_literal(text, cursor, word)?;
        cursor = match_whitespace(text, cursor)?;
    }
    cursor = match_literal(text, cursor, stem)?;

    // Alternatives in order, longest ending first, then the empty one — the same
    // order the Swift pattern's alternation resolves in, with the trailing
    // boundary deciding which one survives.
    for tail in tails {
        if let Some(end) = match_literal(text, cursor, tail) {
            if boundary_after(text, end) {
                return Some(end);
            }
        }
    }
    boundary_after(text, cursor).then_some(cursor)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(spoken: &str, written: &str) -> DictionaryReplacement {
        DictionaryReplacement::new("id", spoken, written)
    }

    fn rigid(spoken: &str, written: &str) -> DictionaryReplacement {
        let mut replacement = entry(spoken, written);
        replacement.inflects = false;
        replacement
    }

    #[test]
    fn a_replacement_fires_on_a_whole_word_only() {
        let dictionary = vec![rigid("\u{043A}\u{043E}\u{0434}", "code")];
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} \u{043A}\u{043E}\u{0434}"
            ),
            "\u{043D}\u{0430}\u{043F}\u{0438}\u{0448}\u{0438} code"
        );
        // Not inside another word: "\u{043A}\u{043E}\u{0434}\u{0438}\u{0440}\u{043E}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435}" must survive intact.
        assert_eq!(apply_exact(&dictionary, "\u{043A}\u{043E}\u{0434}\u{0438}\u{0440}\u{043E}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435}"), "\u{043A}\u{043E}\u{0434}\u{0438}\u{0440}\u{043E}\u{0432}\u{0430}\u{043D}\u{0438}\u{0435}");
    }

    #[test]
    fn the_input_case_does_not_matter() {
        let dictionary = vec![rigid("sentry", "Sentry")];
        assert_eq!(apply_exact(&dictionary, "SeNtRy is down"), "Sentry is down");
    }

    /// The reason inflection exists: a person says "\u{0434}\u{043E} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0430}" and expects
    /// "\u{0434}\u{043E} release" — an exact match would never fire.
    #[test]
    fn a_cyrillic_term_matches_through_its_case_endings() {
        let dictionary = vec![entry("\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}", "release")];
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0434}\u{043E} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0430}"
            ),
            "\u{0434}\u{043E} release"
        );
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0432} \u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0435}"
            ),
            "\u{0432} release"
        );
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}\u{0430}\u{043C}\u{0438}"
            ),
            "release"
        );
        assert_eq!(
            apply_exact(&dictionary, "\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}"),
            "release"
        );
    }

    /// A word ending in "\u{0439}" has that letter replaced by the ending, so it has to be
    /// trimmed from the stem and handed back as a tail — or the word stops
    /// matching itself.
    #[test]
    fn a_word_ending_in_short_i_still_matches_itself_and_its_cases() {
        let dictionary = vec![entry(
            "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}",
            "deploy",
        )];
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}"
            ),
            "deploy"
        );
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{044F}"
            ),
            "deploy"
        );
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0435}\u{043C}"
            ),
            "deploy"
        );
    }

    /// A Latin term in Russian speech does not decline, and an extra tail there
    /// would mean a different word.
    #[test]
    fn a_latin_term_gets_no_inflection() {
        let dictionary = vec![entry("python", "Python")];
        assert_eq!(
            apply_exact(&dictionary, "\u{0432} python"),
            "\u{0432} Python"
        );
        // "pythona" is not a case form of anything.
        assert_eq!(apply_exact(&dictionary, "pythona"), "pythona");
    }

    #[test]
    fn short_words_do_not_inflect_because_the_tail_starts_another_word() {
        let dictionary = vec![entry("\u{043F}\u{0440}", "PR")];
        assert_eq!(apply_exact(&dictionary, "\u{043F}\u{0440}"), "PR");
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}"
            ),
            "\u{043F}\u{0440}\u{043E}\u{0441}\u{0442}\u{043E}"
        );
    }

    #[test]
    fn a_longer_entry_wins_over_a_shorter_one_it_contains() {
        let dictionary = vec![
            rigid("pull", "\u{0442}\u{044F}\u{043D}\u{0443}\u{0442}\u{044C}"),
            rigid("pull request", "PR"),
        ];
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} pull request"
            ),
            "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} PR"
        );
    }

    #[test]
    fn a_multi_word_entry_matches_across_whitespace() {
        let dictionary = vec![entry(
            "\u{043A}\u{043E}\u{0434} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}",
            "code review",
        )];
        assert_eq!(apply_exact(&dictionary, "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043A}\u{043E}\u{0434} \u{0440}\u{0435}\u{0432}\u{044C}\u{044E}"), "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} code review");
    }

    #[test]
    fn an_empty_dictionary_or_text_changes_nothing() {
        assert_eq!(apply_exact(&[], "text"), "text");
        assert_eq!(apply_exact(&[entry("a", "b")], ""), "");
        // A blank spoken side is skipped rather than matching everywhere.
        assert_eq!(apply_exact(&[entry("   ", "x")], "text"), "text");
    }

    /// The empty written side is how a filler word gets struck out.
    #[test]
    fn an_empty_written_side_deletes_the_word() {
        let dictionary = vec![rigid("\u{044D}\u{044D}", "")];
        assert_eq!(
            apply_exact(
                &dictionary,
                "\u{043D}\u{0443} \u{044D}\u{044D} \u{0434}\u{0430}"
            ),
            "\u{043D}\u{0443}  \u{0434}\u{0430}"
        );
    }

    #[test]
    fn every_occurrence_is_replaced_not_only_the_first() {
        let dictionary = vec![rigid("sentry", "Sentry")];
        assert_eq!(
            apply_exact(&dictionary, "sentry and sentry"),
            "Sentry and Sentry"
        );
    }

    #[test]
    fn a_dictionary_written_by_the_mac_app_round_trips() {
        // Fields the Mac added later are absent from older files; their defaults
        // are what the Swift decoder uses, and getting them backwards would
        // silently change how every old entry behaves.
        let json =
            r#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spoken":"релиз","written":"release"}"#;
        let parsed: DictionaryReplacement = serde_json::from_str(json).unwrap();
        assert!(parsed.inflects, "a missing 'inflects' means it inflects");
        assert!(!parsed.no_acoustic_boost, "a missing flag means boosting");
        assert!(parsed.allows_phonetic_matching);
        assert_eq!(parsed.id, "E621E1F8-C36C-495A-93FC-0C247A3E6E5F");
    }
}

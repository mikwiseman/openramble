//! The dictionary's second pass: a term written differently than the dictionary
//! spells it.
//!
//! Ported from `PhoneticMatching.swift`.
//!
//! A flat spelling table cannot work in principle: how the model writes a term
//! depends on the phrase it appeared in. One word "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", said in one voice,
//! comes back as "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}", "\u{0434}\u{0435}\u{043F}\u{043B}\u{0430}", "\u{0434}\u{0435}\u{043F}\u{043B}\u{0435}\u{0439}", "\u{0434}\u{0438}\u{0441}\u{043F}\u{043B}\u{0435}\u{0439}" — and the next phrase
//! will spell it a fifth way. The key below collapses exactly the differences
//! Russian phonetics does not distinguish, and leaves everything else alone.

use crate::dictionary::DictionaryReplacement;
use crate::span::ProtectedSpan;
use std::collections::{HashMap, HashSet};

/// The phonetic key of a Russian word.
///
/// What collapses:
///
/// - **unstressed vowels**: "\u{043E}" sounds like "\u{0430}", "\u{0435}"/"\u{0451}"/"\u{0438}"/"\u{044B}" merge, "\u{044E}" like "\u{0443}";
/// - **paired consonants by voicing — only where Russian genuinely stops
///   distinguishing them**: word-finally and before another obstruent;
/// - **doubled letters**.
///
/// What does NOT collapse, and this is the point:
///
/// - **the final letter, when it is a vowel.** The case ending lives there, and
///   collapsing it declares "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}" and "\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}" one word — which turns
///   "\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}" into "\u{0432} Sentry \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}";
/// - **voicing at the start of a word and between vowels.** Russian devoices
///   neither, and collapsing them turns "\u{0442}\u{0451}\u{043F}\u{043B}\u{044B}\u{0439}" into "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}" and
///   "\u{0431}\u{0430}\u{043D}\u{043A}\u{0430}" into "\u{043F}\u{0430}\u{0439}\u{0442}\u{043E}\u{043D}". Measured on the same set: collapsing
///   catches 161 real Russian words, positional collapsing 70, and the win is
///   identical;
/// - **the soft and hard signs.**
pub mod key {
    /// Vowels and what they collapse into.
    ///
    /// "\u{044F}" is left alone: its reduction depends on the softness of its neighbour,
    /// and without stress that cannot be guessed.
    const VOWELS: &[(char, char)] = &[
        ('\u{0430}', '\u{0430}'),
        ('\u{043E}', '\u{0430}'),
        ('\u{0451}', '\u{0430}'),
        ('\u{0435}', '\u{0435}'),
        ('\u{0438}', '\u{0435}'),
        ('\u{044D}', '\u{0435}'),
        ('\u{044B}', '\u{0435}'),
        ('\u{0443}', '\u{0443}'),
        ('\u{044E}', '\u{0443}'),
        ('\u{044F}', '\u{044F}'),
    ];

    /// Paired by voicing — folded to the voiceless one.
    const PAIRED: &[(char, char)] = &[
        ('\u{0431}', '\u{043F}'),
        ('\u{043F}', '\u{043F}'),
        ('\u{0432}', '\u{0444}'),
        ('\u{0444}', '\u{0444}'),
        ('\u{0433}', '\u{043A}'),
        ('\u{043A}', '\u{043A}'),
        ('\u{0434}', '\u{0442}'),
        ('\u{0442}', '\u{0442}'),
        ('\u{0436}', '\u{0448}'),
        ('\u{0448}', '\u{0448}'),
        ('\u{0437}', '\u{0441}'),
        ('\u{0441}', '\u{0441}'),
    ];

    /// Obstruents: assimilation by voicing happens before them.
    const OBSTRUENTS: &[char] = &[
        '\u{0431}', '\u{043F}', '\u{0432}', '\u{0444}', '\u{0433}', '\u{043A}', '\u{0434}',
        '\u{0442}', '\u{0436}', '\u{0448}', '\u{0437}', '\u{0441}', '\u{0445}', '\u{0446}',
        '\u{0447}', '\u{0449}',
    ];

    fn lookup(table: &[(char, char)], character: char) -> Option<char> {
        table
            .iter()
            .find(|(from, _)| *from == character)
            .map(|(_, to)| *to)
    }

    pub fn of(word: &str) -> String {
        let lowered: Vec<char> = word.to_lowercase().chars().collect();
        // Doubled letters collapse.
        let mut squeezed: Vec<char> = Vec::with_capacity(lowered.len());
        for character in lowered {
            if squeezed.last() != Some(&character) {
                squeezed.push(character);
            }
        }

        let mut key = String::with_capacity(squeezed.len());
        for (offset, &character) in squeezed.iter().enumerate() {
            let is_last = offset == squeezed.len() - 1;

            if let Some(folded) = lookup(VOWELS, character) {
                // The final vowel keeps its identity: the case ending lives there.
                key.push(if is_last { character } else { folded });
                continue;
            }

            if let Some(devoiced) = lookup(PAIRED, character) {
                let neutralised = is_last || OBSTRUENTS.contains(&squeezed[offset + 1]);
                if neutralised {
                    key.push(devoiced);
                    continue;
                }
            }

            key.push(character);
        }
        key
    }
}

/// A phonetic key shorter than five letters is not taken.
///
/// Short words carry too much ordinary speech per key: "api", up to unstressed
/// vowels, coincides with "\u{044D}\u{043F}\u{0438}", "\u{043E}\u{043F}\u{0430}", "\u{0443}\u{043F}\u{0430}". Five is not a round number but
/// the point below which measurement started hitting ordinary words.
pub const MINIMUM_LETTERS: usize = 5;

/// How many words in a row one term may occupy.
///
/// The model either glues a term into one word or splits it into two: "\u{0434}\u{0430}\u{0443}\u{043D}
/// \u{0442}\u{0430}\u{0439}\u{043C}" and "\u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}", "\u{044D}\u{043D}\u{0434} \u{043F}\u{043E}\u{0439}\u{043D}\u{0442}" and "\u{044D}\u{043D}\u{0434}\u{043F}\u{043E}\u{0439}\u{043D}\u{0442}". The window closes
/// both spellings with one check.
const MAXIMUM_WINDOW: usize = 3;

const INFLECTION_ENDINGS: &[&str] = &[
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

#[derive(Default)]
struct Index {
    /// Entry key → how to write it.
    exact: HashMap<String, String>,
    /// The same, restricted to entries that inflect.
    inflected: HashMap<String, String>,
}

/// A half-open range of character offsets.
type Range = (usize, usize);

fn ranges_overlap(a: Range, b: Range) -> bool {
    a.0 < b.1 && b.0 < a.1
}

/// Phonetic matching that steps around protected spans.
///
/// Two separate protections, both needed. First, a word inside a span never
/// becomes a candidate. Second, the three-word window may not step over a span:
/// otherwise a word left of a path and a word right of it would be glued into
/// one term through the protected piece.
pub fn apply(
    replacements: &[DictionaryReplacement],
    text: &str,
    spans: &[ProtectedSpan],
) -> String {
    let index = make_index(replacements);
    if index.exact.is_empty() || text.is_empty() {
        return text.to_string();
    }

    let characters: Vec<char> = text.chars().collect();
    let protected: Vec<Range> = spans
        .iter()
        .filter(|span| span.end <= characters.len())
        .map(|span| (span.start, span.end))
        .collect();

    let words: Vec<Range> = word_ranges(&characters)
        .into_iter()
        .filter(|word| !protected.iter().any(|range| ranges_overlap(*range, *word)))
        .collect();
    if words.is_empty() {
        return text.to_string();
    }

    // Before which word the window must break: a protected piece sits between it
    // and the previous one.
    let mut breaks_before: HashSet<usize> = HashSet::new();
    if !protected.is_empty() {
        for position in 1..words.len() {
            let gap = (words[position - 1].1, words[position].0);
            if protected.iter().any(|range| ranges_overlap(*range, gap)) {
                breaks_before.insert(position);
            }
        }
    }

    let mut result = String::with_capacity(text.len());
    let mut cursor = 0;
    let mut start = 0;

    while start < words.len() {
        let mut matched = false;
        let mut size = MAXIMUM_WINDOW.min(words.len() - start);
        // Shorten the window to the nearest break.
        for offset in 1..size {
            if breaks_before.contains(&(start + offset)) {
                size = offset;
                break;
            }
        }

        while size >= 1 {
            let window = &words[start..start + size];
            if let Some(written) = lookup(window, &characters, &index) {
                result.extend(&characters[cursor..window[0].0]);
                result.push_str(&written);
                cursor = window[size - 1].1;
                start += size;
                matched = true;
                break;
            }
            size -= 1;
        }

        if !matched {
            start += 1;
        }
    }

    result.extend(&characters[cursor..]);
    result
}

fn make_index(replacements: &[DictionaryReplacement]) -> Index {
    let mut index = Index::default();
    let mut ambiguous: HashSet<String> = HashSet::new();
    let mut ambiguous_inflected: HashSet<String> = HashSet::new();

    for replacement in replacements {
        if !replacement.allows_phonetic_matching {
            continue;
        }
        let spoken = replacement
            .spoken
            .trim_matches(|c: char| c == ' ' || c == '\t');
        // An empty written side is how a filler word gets struck out. An exact
        // match can do that; phonetic matching must not, because a deletion is
        // invisible in the text and a person would never spot the mistake.
        if replacement.written.is_empty() {
            continue;
        }

        let letters = compacted(spoken);
        if letters.chars().count() < MINIMUM_LETTERS || !is_cyrillic(&letters) {
            continue;
        }

        let entry_key = key::of(&letters);
        if let Some(existing) = index.exact.get(&entry_key) {
            if existing != &replacement.written {
                ambiguous.insert(entry_key.clone());
            }
        }
        index
            .exact
            .insert(entry_key.clone(), replacement.written.clone());

        if !replacement.inflects {
            continue;
        }
        if let Some(existing) = index.inflected.get(&entry_key) {
            if existing != &replacement.written {
                ambiguous_inflected.insert(entry_key.clone());
            }
        }
        index
            .inflected
            .insert(entry_key, replacement.written.clone());
    }

    // One key standing for two different terms is not a choice, it is a guess.
    for entry_key in ambiguous {
        index.exact.remove(&entry_key);
    }
    for entry_key in ambiguous_inflected {
        index.inflected.remove(&entry_key);
    }
    index
}

fn is_word_character(character: char) -> bool {
    character.is_alphabetic() || character.is_numeric()
}

/// The text's words. A digit beside the letters makes it a different word:
/// "api2" is not "api".
///
/// Reproduces `(?<![\p{L}\p{N}])\p{L}+(?:-\p{L}+)*(?![\p{L}\p{N}])` — including
/// its backtracking: in "end-point2" the greedy match fails on the trailing
/// digit, and the engine falls back to "end", which does match.
fn word_ranges(characters: &[char]) -> Vec<Range> {
    let mut ranges = Vec::new();
    let mut index = 0;

    while index < characters.len() {
        if !characters[index].is_alphabetic()
            || (index > 0 && is_word_character(characters[index - 1]))
        {
            index += 1;
            continue;
        }

        // Ends of each letter run, which are the only positions the pattern can
        // finish on: a stop inside a run always has a letter next and fails the
        // trailing assertion.
        let mut candidates = Vec::new();
        let mut cursor = index;
        loop {
            while cursor < characters.len() && characters[cursor].is_alphabetic() {
                cursor += 1;
            }
            candidates.push(cursor);
            if cursor + 1 < characters.len()
                && characters[cursor] == '-'
                && characters[cursor + 1].is_alphabetic()
            {
                cursor += 1;
                continue;
            }
            break;
        }

        let matched = candidates
            .iter()
            .rev()
            .find(|&&end| end >= characters.len() || !is_word_character(characters[end]));

        match matched {
            Some(&end) => {
                ranges.push((index, end));
                index = end;
            }
            None => index += 1,
        }
    }

    ranges
}

/// How these words should be written, if they are in fact a term.
fn lookup(window: &[Range], characters: &[char], index: &Index) -> Option<String> {
    // The window's words must be adjacent and separated by spaces: "\u{044D}\u{043D}\u{0434}, \u{043F}\u{043E}\u{0439}\u{043D}\u{0442}"
    // is two places in a phrase, not a term broken in half.
    for pair in window.windows(2) {
        let gap = &characters[pair[0].1..pair[1].0];
        if gap.is_empty() || !gap.iter().all(|&c| c == ' ') {
            return None;
        }
    }

    let parts: Vec<String> = window
        .iter()
        .map(|&(start, end)| compacted(&characters[start..end].iter().collect::<String>()))
        .collect();
    if !parts
        .iter()
        .all(|part| !part.is_empty() && is_cyrillic(part))
    {
        return None;
    }

    let (tail, head_parts) = parts.split_last()?;
    let head: String = head_parts.concat();

    let whole = format!("{head}{tail}");
    if whole.chars().count() >= MINIMUM_LETTERS {
        if let Some(written) = index.exact.get(&key::of(&whole)) {
            return Some(written.clone());
        }
    }

    for stem in stems(tail) {
        let candidate = format!("{head}{stem}");
        if candidate.chars().count() < MINIMUM_LETTERS {
            continue;
        }
        if let Some(written) = index.inflected.get(&key::of(&candidate)) {
            return Some(written.clone());
        }
    }
    None
}

/// The word's stems after trimming a case ending.
///
/// The list of tails is the same closed one the exact pass uses, and "\u{0439}" goes
/// back on for the same reason: "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{044E}" is "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}" + "\u{044E}", and the term itself
/// ends in "\u{0439}".
fn stems(word: &str) -> Vec<String> {
    let mut found = Vec::new();
    for ending in INFLECTION_ENDINGS {
        if !word.ends_with(ending) {
            continue;
        }
        let stem: String = word
            .chars()
            .take(word.chars().count() - ending.chars().count())
            .collect();
        if stem.chars().count() < 3 {
            continue;
        }
        found.push(stem.clone());
        found.push(format!("{stem}\u{0439}"));
    }
    found
}

/// A word without spaces or hyphens: they are optional in a term.
fn compacted(text: &str) -> String {
    text.chars()
        .filter(|&c| c != ' ' && c != '-')
        .flat_map(|c| c.to_lowercase())
        .collect()
}

/// Latin entries are not analysed phonetically: the rules here are Russian.
fn is_cyrillic(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| ('\u{0400}'..='\u{04FF}').contains(&c))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::span;

    fn entry(spoken: &str, written: &str) -> DictionaryReplacement {
        DictionaryReplacement::new("id", spoken, written)
    }

    fn matched(dictionary: &[DictionaryReplacement], text: &str) -> String {
        apply(dictionary, text, &[])
    }

    #[test]
    fn unstressed_vowels_collapse_but_the_final_one_does_not() {
        assert_eq!(
            key::of("\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}"),
            key::of("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}")
        );
        // "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}" and "\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}" must stay apart, or "\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}"
        // becomes "\u{0432} Sentry \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430}".
        assert_ne!(
            key::of("\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}"),
            key::of("\u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}")
        );
    }

    #[test]
    fn doubled_letters_collapse() {
        assert_eq!(
            key::of("\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}"),
            key::of("\u{043A}\u{043E}\u{043C}\u{0438}\u{0442}")
        );
    }

    #[test]
    fn voicing_collapses_at_the_end_but_not_at_the_start() {
        // "\u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0441}" / "\u{0440}\u{0438}\u{0431}\u{0435}\u{0439}\u{0437}" — same word.
        assert_eq!(
            key::of("\u{0440}\u{0435}\u{0431}\u{0435}\u{0439}\u{0441}"),
            key::of("\u{0440}\u{0438}\u{0431}\u{0435}\u{0439}\u{0437}")
        );
        // "\u{0442}\u{0451}\u{043F}\u{043B}\u{044B}\u{0439}" must not become "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}": Russian devoices neither initially
        // nor between vowels.
        assert_ne!(
            key::of("\u{0442}\u{0451}\u{043F}\u{043B}\u{044B}\u{0439}"),
            key::of("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}")
        );
    }

    #[test]
    fn a_term_spelled_differently_than_the_dictionary_is_still_found() {
        let dictionary = vec![entry(
            "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}",
            "deploy",
        )];
        assert_eq!(matched(&dictionary, "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}"), "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} deploy");
    }

    #[test]
    fn a_term_split_across_two_words_is_rejoined() {
        let dictionary = vec![entry(
            "\u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}",
            "downtime",
        )];
        assert_eq!(matched(&dictionary, "\u{0431}\u{0435}\u{0437} \u{0434}\u{0430}\u{0443}\u{043D} \u{0442}\u{0430}\u{0439}\u{043C}"), "\u{0431}\u{0435}\u{0437} downtime");
        assert_eq!(matched(&dictionary, "\u{0431}\u{0435}\u{0437} \u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}"), "\u{0431}\u{0435}\u{0437} downtime");
    }

    #[test]
    fn a_comma_between_the_words_means_they_are_not_one_term() {
        let dictionary = vec![entry(
            "\u{044D}\u{043D}\u{0434}\u{043F}\u{043E}\u{0439}\u{043D}\u{0442}",
            "endpoint",
        )];
        assert_eq!(
            matched(
                &dictionary,
                "\u{044D}\u{043D}\u{0434}, \u{043F}\u{043E}\u{0439}\u{043D}\u{0442}"
            ),
            "\u{044D}\u{043D}\u{0434}, \u{043F}\u{043E}\u{0439}\u{043D}\u{0442}"
        );
    }

    #[test]
    fn short_words_are_not_matched_because_ordinary_speech_collides_with_them() {
        let dictionary = vec![
            entry("api", "API"),
            entry("\u{044D}\u{043F}\u{0438}", "API"),
        ];
        assert_eq!(
            matched(&dictionary, "\u{043E}\u{043F}\u{0430}"),
            "\u{043E}\u{043F}\u{0430}"
        );
    }

    #[test]
    fn one_key_for_two_different_terms_is_dropped_rather_than_guessed() {
        let dictionary = vec![
            entry("\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}", "release"),
            entry("\u{0440}\u{0435}\u{043B}\u{0438}\u{0441}", "Relis"),
        ];
        // Both spellings share a key; neither wins.
        assert_eq!(
            matched(&dictionary, "\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}"),
            "\u{0440}\u{0435}\u{043B}\u{0438}\u{0437}"
        );
    }

    #[test]
    fn an_entry_that_opts_out_is_not_a_phonetic_candidate() {
        let mut replacement = entry("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}", "deploy");
        replacement.allows_phonetic_matching = false;
        assert_eq!(
            matched(
                &[replacement],
                "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}"
            ),
            "\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}"
        );
    }

    #[test]
    fn an_empty_written_side_is_never_a_phonetic_candidate() {
        // A deletion is invisible in the text, so a wrong guess would go unnoticed.
        let dictionary = vec![entry(
            "\u{043A}\u{043E}\u{043C}\u{043C}\u{0438}\u{0442}",
            "",
        )];
        assert_eq!(
            matched(&dictionary, "\u{043A}\u{0430}\u{043C}\u{0438}\u{0442}"),
            "\u{043A}\u{0430}\u{043C}\u{0438}\u{0442}"
        );
    }

    #[test]
    fn a_word_inside_a_protected_span_is_never_a_candidate() {
        let dictionary = vec![entry(
            "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}",
            "deploy",
        )];
        let text = "`\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}`";
        assert_eq!(apply(&dictionary, text, &span::detect(text)), text);
    }

    /// The window must not step over a span, or a word on each side of a path
    /// would be glued into one term through the protected piece.
    #[test]
    fn the_window_does_not_reach_across_a_protected_piece() {
        let dictionary = vec![entry(
            "\u{0434}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}\u{0439}\u{043C}",
            "downtime",
        )];
        let text =
            "\u{0434}\u{0430}\u{0443}\u{043D} /usr/local/bin \u{0442}\u{0430}\u{0439}\u{043C}";
        assert_eq!(apply(&dictionary, text, &span::detect(text)), text);
    }

    #[test]
    fn an_empty_span_set_behaves_exactly_like_no_spans() {
        let dictionary = vec![entry(
            "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}",
            "deploy",
        )];
        let text = "\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}";
        assert_eq!(apply(&dictionary, text, &[]), matched(&dictionary, text));
    }

    #[test]
    fn a_digit_beside_the_letters_makes_it_a_different_word() {
        let characters: Vec<char> = "api2".chars().collect();
        assert!(word_ranges(&characters).is_empty());
    }

    /// The regex this replaces backtracks here: the greedy "end-point" fails on
    /// the digit, and "end" is what matches.
    #[test]
    fn a_hyphenated_word_falls_back_to_its_first_half_before_a_digit() {
        let characters: Vec<char> = "end-point2".chars().collect();
        assert_eq!(word_ranges(&characters), vec![(0, 3)]);
    }

    #[test]
    fn hyphenated_words_are_one_word() {
        let characters: Vec<char> = "\u{043A}\u{043E}\u{0434}-\u{0440}\u{0435}\u{0432}\u{044C}\u{044E} \u{0442}\u{0443}\u{0442}".chars().collect();
        assert_eq!(word_ranges(&characters), vec![(0, 9), (10, 13)]);
    }
}

//! Cleanup that only ever deletes.
//!
//! Ported from `CleanVerbatim.swift`, which is the specification. Speech
//! carries traces typing never does: hesitations, a word said twice while the
//! next one loads, a sentence taken back out loud. This removes exactly those
//! and nothing else. It never rewords, reorders or adds a word — the difference
//! from cleanup done by a language model, which can turn "don't" into "do".
//!
//! **When in doubt, keep.** Two adversarial review rounds tried to make the
//! stage delete something real, and each attempt is a test.
//!
//! Three passes, in this order:
//!
//! 1. **Spoken corrections.** "Scratch that" takes back the sentence before it
//!    (as its own sentence or opening one) or what came before it in its
//!    sentence (at the end, or between commas). English only. Every full stop
//!    ends a sentence except a title's ("Dr. Smith"), so a wrong guess takes
//!    back too little, never a sentence the person meant to keep.
//! 2. **Fillers.** Hesitation words. "um", "э" and "mmm" are words too, so they
//!    go only when punctuation sets them apart on both sides. "um" also goes
//!    after a word in a take that reads as English, and never from a take with
//!    German or Portuguese in it. Acronyms and "uh huh"/"uh oh" are
//!    words. The commas around a hesitation go with it unless it sits in a
//!    list. Repeated until nothing changes.
//! 3. **Stutters.** A short function word said twice in a row, from a list of
//!    words whose doubles are never grammatical ("the the", "я я", "I, I").
//! 4. **"New paragraph"** ("Новый абзац"), set apart by punctuation, becomes a
//!    paragraph break — in prose apps only. In a terminal a newline can run a
//!    command, so verbatim apps keep the words. Last, so a hesitation after the
//!    command is already gone and cannot take the break with it.
//!
//! Protected spans and every word the person's own dictionary wrote are never
//! touched. Text with nothing to remove comes back exactly as it went in, and a
//! line break survives the removal of whatever followed it. A meeting
//! transcript turns spoken corrections off and keeps a turn that is nothing but
//! an interjection. The text is assumed to be NFC, as the recognizer writes it.

use std::collections::HashSet;

use crate::span;

/// Where the text is going. Prose apps get paragraph breaks; verbatim apps
/// (terminals, editors, anything unknown) never receive a newline they did not
/// ask for. Ported from `PromptMode` in `PromptMode.swift`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PromptMode {
    #[default]
    Verbatim,
    Prose,
}

/// Hesitation in every language Parakeet speaks: none of these is a word.
const FILLERS: &[&str] = &[
    "uh", "uhh", "uhm", "umm", "erm", "hmm", "hm", "ээ", "эээ", "эмм", "äh", "ähm", "euh",
];

/// Hesitations that are also words: removed only when punctuation sets them
/// apart.
const GUARDED_FILLERS: &[&str] = &["um", "э", "mmm", "ммм"];

/// Halves of two-word interjections: "uh huh", "uh oh", "mm hmm".
const INTERJECTION_HEADS: &[&str] = &["uh", "uhm", "mm", "mmm", "hm", "hmm"];
const INTERJECTION_TAILS: &[&str] = &["huh", "oh", "hmm", "hm"];

/// Words that mark a take as German or Portuguese, where "um" is a word.
const UM_IS_A_WORD_MARKERS: &[&str] = &[
    "der", "das", "und", "ist", "nicht", "ich", "wir", "sich", "auch", "ein", "eine", "mit", "es",
    "geht", "dann", "dich", "oder", "aber", "nein", "bitte", "danke", "não", "você", "uma", "eu",
    "quero", "também", "são", "dois", "três", "quatro", "por", "favor", "obrigado", "obrigada",
    "muito", "isso", "está", "para",
];

/// Letters that only German or Portuguese write, among the languages here.
const UM_IS_A_WORD_LETTERS: &[char] = &['ä', 'ö', 'ü', 'ß', 'ã', 'õ'];

/// Words no other language the model speaks writes. One of them makes a take
/// English, where "um" is never a word.
const ENGLISH_MARKERS: &[&str] = &[
    "the", "you", "your", "that", "this", "with", "what", "would", "should", "could", "they",
    "about", "think", "know", "there", "their", "it's", "don't", "i'm", "let's",
];

/// Words after which a comma is grammar.
const COMMA_GRAMMAR_WORDS: &[&str] = &[
    "что",
    "чтобы",
    "но",
    "а",
    "который",
    "которая",
    "которое",
    "которые",
    "если",
    "когда",
    "потому",
    "which",
    "but",
];

/// Short function words whose doubles are never grammatical. "i" counts only
/// as the capital pronoun.
const STUTTER_WORDS: &[&str] = &[
    "i", "the", "we", "he", "she", "they", "our", "your", "but", "of", "with", "я", "мы", "ты",
    "вы", "он", "она", "оно", "они", "и", "но", "в", "на", "с", "к", "у", "по", "за", "из", "от",
    "до",
];

/// Doubles with a comma between them that are still stutters: "the, the".
const COMMA_STUTTER_WORDS: &[&str] = &[
    "the", "our", "your", "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
];

/// Pronouns that stutter with a comma when they open a sentence: "I, I think".
const OPENING_COMMA_STUTTER_WORDS: &[&str] = &["i", "we", "я", "мы"];

/// Spoken corrections, as consecutive words.
const CORRECTIONS: &[&[&str]] = &[&["scratch", "that"]];

/// Words people lead a correction with: "Sorry, scratch that".
const CORRECTION_LEAD_INS: &[&str] = &[
    "ah", "oh", "okay", "ok", "so", "well", "sorry", "no", "actually", "wait", "oops",
];

/// Spoken paragraph breaks, as consecutive words.
const PARAGRAPH_COMMANDS: &[&[&str]] = &[&["new", "paragraph"], &["новый", "абзац"]];

/// Titles whose full stop does not end a sentence: a name follows.
const TITLES: &[&str] = &["dr", "mr", "mrs", "ms", "prof"];

const TRAILING_PUNCTUATION: &[char] = &[',', '.', ';', ':', '!', '?', '…'];
const SENTENCE_ENDING: &[char] = &['.', '!', '?', '…'];
const CLOSERS: &[char] = &['"', '\'', '”', '’', '»', ')', ']'];

/// Remove hesitations, stutters and — when `spoken_corrections` — spoken
/// corrections. Words in `protected_words` (lowercased) are never touched.
pub fn clean(
    text: &str,
    spoken_corrections: bool,
    protected_words: &HashSet<String>,
    mode: PromptMode,
) -> String {
    let mut tokens = Tokens::new(text, protected_words);
    if tokens.items.is_empty() {
        return text.to_string();
    }

    let corrected = spoken_corrections && tokens.remove_corrections();
    let mut unfilled = false;
    for _ in 0..3 {
        if !tokens.remove_fillers() {
            break;
        }
        unfilled = true;
    }
    let unstuttered = tokens.collapse_stutters();
    let broken = mode == PromptMode::Prose && tokens.apply_paragraph_commands();
    if !(corrected || unfilled || unstuttered || broken) {
        return text.to_string();
    }
    if !spoken_corrections && tokens.items.is_empty() {
        return text.to_string();
    }
    tokens.rendered()
}

/// Every word of every dictionary entry's written form, lowercased.
pub fn protected_words<'a>(written: impl IntoIterator<Item = &'a str>) -> HashSet<String> {
    written
        .into_iter()
        .flat_map(|phrase| {
            phrase
                .to_lowercase()
                .split_whitespace()
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .collect()
}

/// One word, or one protected span, with the whitespace in front of it.
#[derive(Debug, Clone)]
struct Token {
    separator: String,
    text: String,
    protected: bool,
}

impl Token {
    /// The word without its closing punctuation, lowercased.
    fn word(&self) -> String {
        self.text
            .trim_end_matches(|c: char| TRAILING_PUNCTUATION.contains(&c))
            .to_lowercase()
    }

    /// The closing punctuation alone.
    fn punctuation(&self) -> &str {
        let stem = self
            .text
            .trim_end_matches(|c: char| TRAILING_PUNCTUATION.contains(&c));
        &self.text[stem.len()..]
    }

    fn ends_with_comma(&self) -> bool {
        self.text.ends_with(',')
    }

    /// An acronym: two or more letters, all capitals.
    fn is_shouting(&self) -> bool {
        let letters: Vec<char> = self.text.chars().filter(|c| c.is_alphabetic()).collect();
        letters.len() >= 2 && letters.iter().all(|c| c.is_uppercase())
    }

    fn is_number(&self) -> bool {
        let stem = self.word();
        !stem.is_empty()
            && stem.chars().all(|c| c.is_numeric() || c == '.')
            && stem.chars().any(|c| c.is_numeric())
    }

    /// Whether this token closes a sentence, possibly inside a closing quote
    /// or bracket. A title's full stop ("Dr.") is the one exception.
    fn ends_sentence(&self) -> bool {
        let unquoted = self.text.trim_end_matches(|c: char| CLOSERS.contains(&c));
        let Some(last) = unquoted.chars().last() else {
            return false;
        };
        if !SENTENCE_ENDING.contains(&last) {
            return false;
        }
        if last != '.' {
            return true;
        }
        let stem = unquoted.trim_end_matches(|c: char| TRAILING_PUNCTUATION.contains(&c));
        !TITLES.contains(&stem.to_lowercase().as_str())
    }

    /// Only punctuation, detached from the word it closes: "Uh , the".
    fn is_detached_punctuation(&self) -> bool {
        !self.protected
            && !self.text.is_empty()
            && self.text.chars().all(|c| TRAILING_PUNCTUATION.contains(&c))
    }
}

struct Tokens<'a> {
    items: Vec<Token>,
    trailing: String,
    protected_words: &'a HashSet<String>,
}

impl<'a> Tokens<'a> {
    fn new(text: &str, protected_words: &'a HashSet<String>) -> Self {
        let characters: Vec<char> = text.chars().collect();
        let spans = span::detect(text);
        let mut items: Vec<Token> = Vec::new();
        let mut span_index = 0;
        let mut separator = String::new();
        let mut index = 0;

        while index < characters.len() {
            while span_index < spans.len() && spans[span_index].end <= index {
                span_index += 1;
            }
            if span_index < spans.len() && spans[span_index].start == index {
                let end = spans[span_index].end;
                items.push(Token {
                    separator: std::mem::take(&mut separator),
                    text: characters[index..end].iter().collect(),
                    protected: true,
                });
                index = end;
                continue;
            }
            if characters[index].is_whitespace() {
                separator.push(characters[index]);
                index += 1;
                continue;
            }
            let mut word = String::new();
            while index < characters.len() && !characters[index].is_whitespace() {
                if span_index < spans.len() && spans[span_index].start == index {
                    break;
                }
                word.push(characters[index]);
                index += 1;
            }
            let token = Token {
                separator: std::mem::take(&mut separator),
                text: word,
                protected: false,
            };
            // Punctuation the recognizer detached belongs to the word before it.
            let attach = token.is_detached_punctuation()
                && !token.separator.is_empty()
                && !token.separator.contains(['\n', '\r'])
                && items.last().is_some_and(|last| !last.protected);
            if attach {
                if let Some(last) = items.last_mut() {
                    last.text.push_str(&token.text);
                }
            } else {
                items.push(token);
            }
        }

        Self {
            items,
            trailing: separator,
            protected_words,
        }
    }

    fn rendered(&self) -> String {
        let mut result: String = self
            .items
            .iter()
            .map(|token| format!("{}{}", token.separator, token.text))
            .collect();
        result.push_str(&self.trailing);
        result
    }

    /// Remove `start..=end`. The text's leading whitespace stays where it was,
    /// and a line break in front of the removed piece survives it.
    fn remove(&mut self, start: usize, end: usize) {
        let leading = self.items[start].separator.clone();
        self.items.drain(start..=end);
        if start >= self.items.len() {
            return;
        }
        let next_has_break = self.items[start].separator.contains(['\n', '\r']);
        if start == 0 || (leading.contains(['\n', '\r']) && !next_has_break) {
            self.items[start].separator = leading;
        }
    }

    fn is_kept(&self, token: &Token) -> bool {
        token.protected || token.is_shouting() || self.protected_words.contains(&token.word())
    }

    /// Whether "um" is a word in this take: German or Portuguese in it.
    fn um_is_a_word(&self) -> bool {
        self.items.iter().any(|token| {
            !token.protected
                && !token.is_shouting()
                && (UM_IS_A_WORD_MARKERS.contains(&token.word().as_str())
                    || token
                        .text
                        .to_lowercase()
                        .chars()
                        .any(|c| UM_IS_A_WORD_LETTERS.contains(&c)))
        })
    }

    /// Whether this take reads as English, where "um" is only a hesitation.
    fn reads_as_english(&self) -> bool {
        self.items
            .iter()
            .any(|token| !token.protected && ENGLISH_MARKERS.contains(&token.word().as_str()))
    }

    fn word_at(&self, index: Option<usize>) -> Option<String> {
        index
            .and_then(|i| self.items.get(i))
            .map(|token| token.word())
    }

    fn is_filler(&self, index: usize, um_is_a_word: bool, reads_as_english: bool) -> bool {
        let token = &self.items[index];
        if self.is_kept(token) {
            return false;
        }
        let word = token.word();
        // "uh huh", "uh oh", "mm hmm" are words.
        if INTERJECTION_HEADS.contains(&word.as_str()) && token.punctuation().is_empty() {
            if let Some(next) = self.word_at(Some(index + 1)) {
                if INTERJECTION_TAILS.contains(&next.as_str()) {
                    return false;
                }
            }
        }
        if INTERJECTION_TAILS.contains(&word.as_str())
            && index > 0
            && self.items[index - 1].punctuation().is_empty()
        {
            if let Some(previous) = self.word_at(index.checked_sub(1)) {
                if INTERJECTION_HEADS.contains(&previous.as_str()) {
                    return false;
                }
            }
        }
        if FILLERS.contains(&word.as_str()) {
            return true;
        }
        if !GUARDED_FILLERS.contains(&word.as_str()) {
            return false;
        }
        if word == "um" && um_is_a_word {
            return false;
        }
        // A letter among letters: "а, о, у, э, ы".
        if let (Some(previous), Some(next)) = (
            self.word_at(index.checked_sub(1)),
            self.word_at(Some(index + 1)),
        ) {
            if previous.chars().count() == 1 && next.chars().count() == 1 {
                return false;
            }
        }
        // Hesitations in a row are one pause: "um uh, now".
        let carries_comma = token.ends_with_comma()
            || (token.punctuation().is_empty()
                && self.items.get(index + 1).is_some_and(|next| {
                    !self.is_kept(next)
                        && FILLERS.contains(&next.word().as_str())
                        && next.ends_with_comma()
                }));
        let apart_before = index == 0
            || self.items[index - 1].ends_sentence()
            || self.items[index - 1].ends_with_comma()
            || (word == "um" && reads_as_english);
        if carries_comma && apart_before {
            return true;
        }
        // A dangling one a trailing command left behind: "…it, um".
        token.punctuation().is_empty()
            && index == self.items.len() - 1
            && index > 0
            && self.items[index - 1].ends_with_comma()
    }

    /// A hesitation, as far as a correction is concerned.
    fn is_any_filler_word(&self, index: usize) -> bool {
        let token = &self.items[index];
        if self.is_kept(token) {
            return false;
        }
        let word = token.word();
        FILLERS.contains(&word.as_str()) || GUARDED_FILLERS.contains(&word.as_str())
    }

    /// Whether the comma before a hesitation at `index` is grammar.
    fn comma_before_is_grammar(&self, index: usize) -> bool {
        if index >= 2
            && self.items[index - 2].ends_with_comma()
            && !COMMA_GRAMMAR_WORDS.contains(&self.items[index - 1].word().as_str())
        {
            return true;
        }
        if index >= 1
            && index + 1 < self.items.len()
            && self.items[index - 1].is_number()
            && self.items[index + 1].is_number()
        {
            return true;
        }
        self.word_at(Some(index + 1))
            .is_some_and(|next| COMMA_GRAMMAR_WORDS.contains(&next.as_str()))
    }

    // Pass 1: corrections

    fn sentences(&self) -> Vec<(usize, usize)> {
        let mut result = Vec::new();
        let mut start = 0;
        for index in 0..self.items.len() {
            if self.items[index].ends_sentence() || index == self.items.len() - 1 {
                result.push((start, index));
                start = index + 1;
            }
        }
        result
    }

    fn remove_corrections(&mut self) -> bool {
        let mut changed = false;
        for _ in 0..self.items.len() {
            let Some((start, end)) = self.next_correction() else {
                break;
            };
            self.remove(start, end);
            changed = true;
            if start < self.items.len() && !self.items[start].protected {
                self.capitalize_first_letter(start);
            }
        }
        changed
    }

    fn next_correction(&self) -> Option<(usize, usize)> {
        let sentences = self.sentences();
        for (position, &(start, end)) in sentences.iter().enumerate() {
            let words: Vec<usize> = (start..=end)
                .filter(|&index| !self.is_any_filler_word(index))
                .collect();
            let spoken: Vec<String> = words
                .iter()
                .map(|&index| {
                    let token = &self.items[index];
                    if token.protected {
                        token.text.clone()
                    } else {
                        token.word()
                    }
                })
                .collect();

            for command in CORRECTIONS {
                if spoken.len() < command.len() {
                    continue;
                }
                for offset in 0..=spoken.len() - command.len() {
                    let matches = spoken[offset..offset + command.len()]
                        .iter()
                        .zip(command.iter())
                        .all(|(a, b)| a == b);
                    if !matches {
                        continue;
                    }
                    let first = words[offset];
                    let last = words[offset + command.len() - 1];
                    let opens = spoken[..offset]
                        .iter()
                        .all(|word| CORRECTION_LEAD_INS.contains(&word.as_str()));
                    let closes = offset + command.len() == spoken.len();
                    let pause_before = first > start
                        && (self.items[first - 1].ends_with_comma()
                            || self.is_any_filler_word(first - 1));
                    let pause_after = self.items[last].ends_with_comma();

                    if opens && (closes || pause_after) {
                        let from = self.previous_start(position, &sentences);
                        return Some((from, if closes { end } else { last }));
                    }
                    if closes && pause_before {
                        return Some((start, end));
                    }
                    if !opens && !closes && pause_before && pause_after {
                        return Some((start, last));
                    }
                }
            }
        }
        None
    }

    fn previous_start(&self, position: usize, sentences: &[(usize, usize)]) -> usize {
        let mut candidate = position;
        while candidate > 0 {
            let (start, end) = sentences[candidate - 1];
            if (start..=end).all(|index| self.is_any_filler_word(index)) {
                candidate -= 1;
            } else {
                return start;
            }
        }
        sentences[0].0
    }

    // Pass 2: fillers

    fn remove_fillers(&mut self) -> bool {
        let um_is_a_word = self.um_is_a_word();
        let reads_as_english = self.reads_as_english();
        let mut changed = false;
        let mut index = 0;
        while index < self.items.len() {
            if !self.is_filler(index, um_is_a_word, reads_as_english) {
                index += 1;
                continue;
            }
            let filler = self.items[index].clone();
            let terminal: String = filler
                .punctuation()
                .chars()
                .filter(|c| SENTENCE_ENDING.contains(c))
                .collect();
            let starts_sentence = index == 0 || self.items[index - 1].ends_sentence();
            let is_last = index == self.items.len() - 1;

            let mut removal = (index, index);
            if index > 0 && !self.items[index - 1].protected {
                let previous = index - 1;
                if !terminal.is_empty() {
                    if !self.items[previous].ends_sentence() {
                        self.strip_closing_pauses(previous);
                        self.items[previous].text.push_str(&terminal);
                    }
                } else if self.items[previous].ends_with_comma()
                    && (is_last
                        || (filler.ends_with_comma() && !self.comma_before_is_grammar(index)))
                {
                    // The commas around a hesitation mark the pause.
                    self.items[previous].text.pop();
                    if self.items[previous].text.is_empty() {
                        removal = (previous, index);
                    }
                }
            } else if index > 0 && !terminal.is_empty() && !self.items[index - 1].ends_sentence() {
                self.items.insert(
                    index,
                    Token {
                        separator: String::new(),
                        text: terminal,
                        protected: false,
                    },
                );
                removal = (index + 1, index + 1);
            }

            self.remove(removal.0, removal.1);
            changed = true;
            index = removal.0;

            if starts_sentence && index < self.items.len() && !self.items[index].protected {
                self.capitalize_first_letter(index);
            }
        }
        changed
    }

    fn strip_closing_pauses(&mut self, index: usize) {
        while matches!(self.items[index].text.chars().last(), Some(',' | ';' | ':')) {
            self.items[index].text.pop();
        }
    }

    fn capitalize_first_letter(&mut self, index: usize) {
        let text = &self.items[index].text;
        let mut characters = text.chars();
        let Some(first) = characters.next() else {
            return;
        };
        if !first.is_lowercase() {
            return;
        }
        let capitalized: String = first.to_uppercase().chain(characters).collect();
        self.items[index].text = capitalized;
    }

    // Pass 4: paragraph commands

    fn apply_paragraph_commands(&mut self) -> bool {
        let mut changed = false;
        let mut index = 0;
        while index < self.items.len() {
            let Some(length) = self.paragraph_command_length(index) else {
                index += 1;
                continue;
            };
            let last = index + length - 1;
            let has_before = index > 0;
            let has_after = last + 1 < self.items.len();

            if has_before
                && !self.items[index - 1].protected
                && !self.items[index - 1].ends_sentence()
            {
                self.strip_closing_pauses(index - 1);
                self.items[index - 1].text.push('.');
            }
            self.remove(index, last);
            if has_before && has_after {
                self.items[index].separator = "\n\n".to_string();
            }
            if index < self.items.len() && !self.items[index].protected {
                self.capitalize_first_letter(index);
            }
            changed = true;
        }
        changed
    }

    /// How many tokens a paragraph command starting at `index` spans, when
    /// punctuation sets it apart: "…point. New paragraph. Second…" is a command,
    /// "added a new paragraph about…" is a sentence.
    fn paragraph_command_length(&self, index: usize) -> Option<usize> {
        for command in PARAGRAPH_COMMANDS {
            let last = index + command.len() - 1;
            if last >= self.items.len() {
                continue;
            }
            let tokens = &self.items[index..=last];
            let matches = tokens.iter().all(|token| !token.protected)
                && tokens
                    .iter()
                    .zip(command.iter())
                    .all(|(token, word)| token.word() == *word)
                && tokens[..tokens.len() - 1]
                    .iter()
                    .all(|token| token.punctuation().is_empty());
            if !matches {
                continue;
            }
            let apart_before = index == 0 || !self.items[index - 1].punctuation().is_empty();
            let apart_after =
                last == self.items.len() - 1 || !self.items[last].punctuation().is_empty();
            if apart_before && apart_after {
                return Some(command.len());
            }
        }
        None
    }

    // Pass 3: stutters

    fn collapse_stutters(&mut self) -> bool {
        let mut changed = false;
        let mut index = 1;
        while index < self.items.len() {
            if !self.is_stutter(index) {
                index += 1;
                continue;
            }
            let punctuation = self.items[index].punctuation().to_string();
            if self.items[index - 1].ends_with_comma() {
                self.items[index - 1].text.pop();
            }
            self.items[index - 1].text.push_str(&punctuation);
            self.items.remove(index);
            changed = true;
        }
        changed
    }

    fn is_stutter(&self, index: usize) -> bool {
        let previous = &self.items[index - 1];
        let current = &self.items[index];
        if self.is_kept(previous)
            || self.is_kept(current)
            || previous.word() != current.word()
            || current.separator.contains(['\n', '\r'])
        {
            return false;
        }
        let word = current.word();
        // "i" is the capital pronoun only: Polish "i i" is "and i".
        if word == "i" && !(previous.text.starts_with('I') && current.text.starts_with('I')) {
            return false;
        }
        if previous.punctuation().is_empty() {
            return STUTTER_WORDS.contains(&word.as_str());
        }
        if previous.punctuation() != "," {
            return false;
        }
        if COMMA_STUTTER_WORDS.contains(&word.as_str()) {
            return true;
        }
        let opens_sentence = index == 1 || self.items[index - 2].ends_sentence();
        opens_sentence && OPENING_COMMA_STUTTER_WORDS.contains(&word.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::{clean, protected_words, PromptMode};
    use std::collections::HashSet;

    fn plain(text: &str) -> String {
        clean(text, true, &HashSet::new(), PromptMode::Verbatim)
    }

    /// The same cases as `CleanVerbatimTests.swift`. The conformance fixtures
    /// check the two against each other through the whole pipeline; these keep
    /// the stage readable on its own.
    #[test]
    fn removes_what_was_not_meant() {
        let cases = [
            ("Um, so the build passed.", "So the build passed."),
            ("We should, um, ship it.", "We should ship it."),
            ("Don't, uh, deploy on Friday.", "Don't deploy on Friday."),
            (
                "Мы, э, думаем, что, ээ, надо подождать.",
                "Мы думаем, что надо подождать.",
            ),
            ("Send me the, uh, the report.", "Send me the report."),
            (
                "Set the values to 10, 20, um, 30.",
                "Set the values to 10, 20, 30.",
            ),
            ("Set it to 10, um, 30.", "Set it to 10, 30."),
            ("I need you to um, fix it.", "I need you to fix it."),
            ("Ship it, um uh, now", "Ship it now"),
            ("We should um uh, ship it.", "We should ship it."),
            ("Купи хлеб, молоко, э, сыр.", "Купи хлеб, молоко, сыр."),
            ("Uh , the build passed.", "The build passed."),
            ("Ship it , uh , now", "Ship it now"),
            ("Я, э, не уверен.", "Я не уверен."),
            ("Es geht um, äh, Geld.", "Es geht um Geld."),
            (
                "Um, the battery will die soon.",
                "The battery will die soon.",
            ),
            ("Um, I studied at MIT.", "I studied at MIT."),
            ("I, I really think so.", "I really think so."),
            ("Я, я думаю.", "Я думаю."),
            ("The, the answer is yes.", "The answer is yes."),
            (
                "Meet at 3 p.m. Bring snacks. Scratch that. Bring drinks.",
                "Meet at 3 p.m. Bring drinks.",
            ),
            (
                "Are we shipping today? No. Scratch that. Yes.",
                "Are we shipping today? Yes.",
            ),
            ("We meet at 5. Scratch that. We meet at 6.", "We meet at 6."),
            (
                "I met Dr. Smith today. Scratch that. I met nobody.",
                "I met nobody.",
            ),
            ("Can we ship? No. Uh, not yet.", "Can we ship? No. Not yet."),
            ("He said no. Uh. Then he left.", "He said no. Then he left."),
            (
                "I will scratch that off the list, scratch that, I will keep it.",
                "I will keep it.",
            ),
            (
                "First paragraph.\r\n\r\nUh, second paragraph.",
                "First paragraph.\r\n\r\nSecond paragraph.",
            ),
            (
                "Um, so that the deploy failed. Ah, scratch that, the deploy passed.",
                "The deploy passed.",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(plain(input), expected, "input: {input:?}");
        }
    }

    #[test]
    fn keeps_what_was_meant() {
        let unchanged = [
            "Benenne die Funktion um.",
            "Quantos? Um, por favor.",
            "Dreh dich um, bitte.",
            "Ljudski um, kao i tijelo, treba odmor.",
            "Comprei só um, mas era caro.",
            "Ich will you to um, fix it.",
            "Format the date as dd mmm yyyy.",
            "Гласные: а, о, у, э, ы.",
            "Use a 3 mm drill bit and a 10 mm bolt.",
            "We trained an HMM on the data.",
            "Uh huh, ship it.",
            "Mm hmm, sounds good.",
            "Uh oh, the deploy failed.",
            "I told you you were right.",
            "When I saw it it was broken.",
            "Zmienne i i j są indeksami.",
            "Use i I mean j.",
            "My my, how you have grown.",
            "Read the\nthe report",
            "Try it, it works.",
            "What it is is a mess.",
            "No, no, no.",
            "Please scratch that line from the file.",
            "Run `uh` now.",
            "",
            "   ",
            "Hello,  world.",
        ];
        for text in unchanged {
            assert_eq!(plain(text), text, "input: {text:?}");
        }
    }

    #[test]
    fn dictionary_words_are_kept() {
        let words = protected_words(["The The", "Hmm Labs"]);
        assert_eq!(
            clean("I love The The band.", true, &words, PromptMode::Verbatim),
            "I love The The band."
        );
        assert_eq!(
            clean("I work at Hmm Labs.", true, &words, PromptMode::Verbatim),
            "I work at Hmm Labs."
        );
    }

    #[test]
    fn a_meeting_keeps_corrections_and_interjections() {
        let none = HashSet::new();
        assert_eq!(
            clean(
                "Um, the deploy failed. Scratch that. It passed.",
                false,
                &none,
                PromptMode::Verbatim
            ),
            "The deploy failed. Scratch that. It passed."
        );
        assert_eq!(clean("Hmm?", false, &none, PromptMode::Verbatim), "Hmm?");
    }

    #[test]
    fn new_paragraph_breaks_prose_and_stays_words_in_verbatim_apps() {
        let prose = [
            (
                "First point. New paragraph. Second point.",
                "First point.\n\nSecond point.",
            ),
            (
                "First point, new paragraph, second point.",
                "First point.\n\nSecond point.",
            ),
            (
                "Первый пункт. Новый абзац. Второй пункт.",
                "Первый пункт.\n\nВторой пункт.",
            ),
            (
                "First point. New paragraph. Um, second point.",
                "First point.\n\nSecond point.",
            ),
            ("New paragraph. Hello there.", "Hello there."),
            ("Hello there. New paragraph.", "Hello there."),
            (
                "I added a new paragraph about pricing.",
                "I added a new paragraph about pricing.",
            ),
        ];
        for (input, expected) in prose {
            assert_eq!(
                clean(input, true, &HashSet::new(), PromptMode::Prose),
                expected,
                "input: {input:?}"
            );
        }
        let text = "First point. New paragraph. Second point.";
        assert_eq!(plain(text), text);
    }

    #[test]
    fn is_idempotent() {
        for text in [
            "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
            "We should, um, ship it.",
            "Set the values to 10, 20, um, 30.",
            "Ship it, um uh, now",
        ] {
            let once = plain(text);
            assert_eq!(plain(&once), once, "input: {text:?}");
        }
    }
}

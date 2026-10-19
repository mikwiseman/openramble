//! Cleanup that only ever deletes.
//!
//! Ported from `CleanVerbatim.swift`, which is the specification. Speech
//! carries traces typing never does: hesitations, a word said twice while the
//! next one loads, a sentence taken back out loud. This removes exactly those
//! and nothing else. It never rewords, reorders or adds a word — the difference
//! from cleanup done by a language model, which can turn "don't" into "do".
//!
//! A false deletion is the worse failure, so every rule leans towards keeping.
//! The rules were shaped by an adversarial review that tried to make the stage
//! delete something real — German separable verbs, the Portuguese "one",
//! millimetres, acronyms, grammatical doubles — and each of those is a test.
//!
//! Three passes, in this order:
//!
//! 1. **Spoken corrections.** "Scratch that" takes back what was just said: as
//!    its own sentence or opening one, the sentence before it; at the end of a
//!    sentence, or between commas in the middle of one, everything before it in
//!    that sentence. The commas are what make it a command rather than the verb.
//!    English only. Runs first because it reads the commas the filler pass
//!    removes.
//! 2. **Fillers.** Words that are hesitation and nothing else. "um" and "э" are
//!    words too, so they go only when they carry a comma of their own — and
//!    "um" never in a take with German or Portuguese in it. An all-caps token is
//!    an acronym, never a hesitation. The comma before a hesitation stays.
//! 3. **Stutters.** A short function word said twice in a row with nothing
//!    between, from a list of words whose doubles are never grammatical.
//!
//! Protected spans are atomic and never edited. Text with nothing to remove
//! comes back exactly as it went in, and a line break survives the removal of
//! whatever followed it. A meeting transcript turns spoken corrections off and
//! keeps a turn that is nothing but an interjection.

use crate::span;

/// Hesitation in every language Parakeet speaks: none of these is a word.
const FILLERS: &[&str] = &[
    "uh", "uhh", "uhm", "umm", "erm", "hmm", "hm", "mmm", "ээ", "эээ", "эмм", "ммм", "äh", "ähm",
    "euh",
];

/// Hesitations that are also words: "um" (a German particle, the Portuguese
/// "one") and "э" (a Russian letter). Removed only with a comma of their own.
const GUARDED_FILLERS: &[&str] = &["um", "э"];

/// Words that mark a take as German or Portuguese, where "um" is a word.
const UM_IS_A_WORD_MARKERS: &[&str] = &[
    "der", "die", "das", "und", "ist", "nicht", "ich", "wir", "sich", "auch", "ein", "eine", "mit",
    "es", "geht", "dann", "não", "você", "uma", "eu", "quero", "também", "são", "dois", "três",
    "quatro",
];

/// Letters that only German or Portuguese write, among the languages here.
const UM_IS_A_WORD_LETTERS: &[char] = &['ä', 'ö', 'ü', 'ß', 'ã', 'õ', 'ç'];

/// Short function words whose doubles are never grammatical.
const STUTTER_WORDS: &[&str] = &[
    "i", "the", "we", "you", "he", "she", "they", "my", "our", "your", "but", "of", "it", "with",
    "я", "мы", "ты", "вы", "он", "она", "оно", "они", "и", "но", "в", "на", "с", "к", "у", "по",
    "за", "из", "от", "до",
];

/// Spoken corrections, as consecutive words.
const CORRECTIONS: &[&[&str]] = &[&["scratch", "that"]];

/// Words people lead a correction with: "Sorry, scratch that". Before the
/// command they do not stop it from opening the sentence. "ah" is here because
/// the model writes a spoken "uh" that way.
const CORRECTION_LEAD_INS: &[&str] = &[
    "ah", "oh", "okay", "ok", "so", "well", "sorry", "no", "actually", "wait", "oops",
];

/// Words whose full stop does not end a sentence.
const ABBREVIATIONS: &[&str] = &[
    "dr", "mr", "mrs", "ms", "st", "vs", "etc", "inc", "ltd", "jr", "sr", "no", "prof", "mt", "fig",
];

const TRAILING_PUNCTUATION: &[char] = &[',', '.', ';', ':', '!', '?', '…'];
const SENTENCE_ENDING: &[char] = &['.', '!', '?', '…'];
const CLOSERS: &[char] = &['"', '\'', '”', '’', '»', ')', ']'];

/// Remove hesitations, stutters and — when `spoken_corrections` — spoken
/// corrections.
pub fn clean(text: &str, spoken_corrections: bool) -> String {
    let mut tokens = Tokens::new(text);
    if tokens.items.is_empty() {
        return text.to_string();
    }

    let corrected = spoken_corrections && tokens.remove_corrections();
    let unfilled = tokens.remove_fillers();
    let unstuttered = tokens.collapse_stutters();
    if !(corrected || unfilled || unstuttered) {
        return text.to_string();
    }
    if !spoken_corrections && tokens.items.is_empty() {
        return text.to_string();
    }
    tokens.rendered()
}

/// Whether `command` appears in `spoken` starting at `at`.
fn matches_at(spoken: &[String], command: &[&str], at: usize) -> bool {
    at + command.len() <= spoken.len()
        && spoken[at..at + command.len()]
            .iter()
            .zip(command.iter())
            .all(|(a, b)| a == b)
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

    /// Whether this token closes a sentence: a full stop, question mark,
    /// exclamation or ellipsis, possibly inside a closing quote or bracket, and
    /// not the full stop of an abbreviation ("Dr.", "p.m.", "J.").
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
        if stem.contains('.') || stem.chars().count() == 1 {
            return false;
        }
        !ABBREVIATIONS.contains(&stem.to_lowercase().as_str())
    }
}

struct Tokens {
    items: Vec<Token>,
    trailing: String,
}

impl Tokens {
    fn new(text: &str) -> Self {
        let characters: Vec<char> = text.chars().collect();
        let spans = span::detect(text);
        let mut items = Vec::new();
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
            items.push(Token {
                separator: std::mem::take(&mut separator),
                text: word,
                protected: false,
            });
        }

        Self {
            items,
            trailing: separator,
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
        let next_has_break = self.items[start].separator.contains('\n');
        if start == 0 || (leading.contains('\n') && !next_has_break) {
            self.items[start].separator = leading;
        }
    }

    /// Whether "um" is a word in this take: German or Portuguese in it.
    fn um_is_a_word(&self) -> bool {
        self.items.iter().any(|token| {
            !token.protected
                && (UM_IS_A_WORD_MARKERS.contains(&token.word().as_str())
                    || token
                        .text
                        .to_lowercase()
                        .chars()
                        .any(|c| UM_IS_A_WORD_LETTERS.contains(&c)))
        })
    }

    fn is_filler(&self, index: usize, um_is_a_word: bool) -> bool {
        let token = &self.items[index];
        if token.protected || token.is_shouting() {
            return false;
        }
        let word = token.word();
        if FILLERS.contains(&word.as_str()) {
            return true;
        }
        if !GUARDED_FILLERS.contains(&word.as_str()) {
            return false;
        }
        if word == "um" && um_is_a_word {
            return false;
        }
        if token.ends_with_comma() {
            return true;
        }
        // A dangling "um" a trailing command left behind: "…it, um".
        token.punctuation().is_empty()
            && index == self.items.len() - 1
            && index > 0
            && self.items[index - 1].ends_with_comma()
    }

    /// A hesitation, as far as a correction is concerned: any filler word,
    /// guarded or not, because it can only stand between words here.
    fn is_any_filler_word(&self, index: usize) -> bool {
        let token = &self.items[index];
        if token.protected || token.is_shouting() {
            return false;
        }
        let word = token.word();
        FILLERS.contains(&word.as_str()) || GUARDED_FILLERS.contains(&word.as_str())
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
        // Each removal shortens the text, so the bound is the token count.
        for _ in 0..self.items.len() {
            let Some((start, end)) = self.next_correction() else {
                break;
            };
            self.remove(start, end);
            changed = true;
            // Every removal starts at a sentence start, so whatever is left
            // there now opens a sentence.
            if start < self.items.len() && !self.items[start].protected {
                self.capitalize_first_letter(start);
            }
        }
        changed
    }

    /// The tokens the first spoken correction removes, itself included.
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
                let Some(offset) =
                    (0..=spoken.len() - command.len()).find(|&at| matches_at(&spoken, command, at))
                else {
                    continue;
                };

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
        None
    }

    /// Where the sentence a correction takes back begins. Sentences of nothing
    /// but hesitation are passed over and go with it.
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
        let mut changed = false;
        let mut index = 0;
        while index < self.items.len() {
            if !self.is_filler(index, um_is_a_word) {
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
                } else if is_last && self.items[previous].ends_with_comma() {
                    // Nothing follows the comma any more.
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

    /// Drop the commas, semicolons and colons that close a word, so a full stop
    /// can take their place.
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

    // Pass 3: stutters

    fn collapse_stutters(&mut self) -> bool {
        let mut changed = false;
        let mut index = 1;
        while index < self.items.len() {
            let previous = &self.items[index - 1];
            let current = &self.items[index];
            let word = current.word();
            let is_stutter = !previous.protected
                && !current.protected
                && !previous.is_shouting()
                && !current.is_shouting()
                && previous.punctuation().is_empty()
                && previous.word() == word
                && STUTTER_WORDS.contains(&word.as_str());
            if !is_stutter {
                index += 1;
                continue;
            }
            let punctuation = current.punctuation().to_string();
            self.items[index - 1].text.push_str(&punctuation);
            self.items.remove(index);
            changed = true;
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::clean;

    /// The same cases as `CleanVerbatimTests.swift`. The conformance fixtures
    /// check the two against each other through the whole pipeline; these keep
    /// the stage readable on its own.
    #[test]
    fn removes_what_was_not_meant() {
        let cases = [
            ("Um, so the build passed.", "So the build passed."),
            ("Uh, the build passed.", "The build passed."),
            ("We should, um, ship it.", "We should, ship it."),
            (
                "Set the values to 10, 20, um, 30.",
                "Set the values to 10, 20, 30.",
            ),
            ("Купи хлеб, молоко, э, сыр.", "Купи хлеб, молоко, сыр."),
            ("Then uh we ship it.", "Then we ship it."),
            ("It is hmm fine.", "It is fine."),
            ("Done. Uh, the next one.", "Done. The next one."),
            ("I think, uh.", "I think."),
            ("I think uh.", "I think."),
            ("Is it ready, uh?", "Is it ready?"),
            (
                "Ээ, я думаю, что это работает.",
                "Я думаю, что это работает.",
            ),
            ("Я, э, не уверен.", "Я, не уверен."),
            ("Ммм, давай завтра.", "Давай завтра."),
            ("Ähm, ich komme morgen.", "Ich komme morgen."),
            ("Euh, je pense que oui.", "Je pense que oui."),
            ("Uh.", ""),
            ("Uh, uh.", ""),
            ("Es geht um, äh, Geld.", "Es geht um, Geld."),
            ("I need you to um, fix it.", "I need you to fix it."),
            (
                "I I think the the build passed.",
                "I think the build passed.",
            ),
            ("The the the deploy failed.", "The deploy failed."),
            ("Я я думаю, что и и это тоже.", "Я думаю, что и это тоже."),
            ("Ask me and I I.", "Ask me and I."),
            (
                "The deploy failed. Scratch that. The deploy passed.",
                "The deploy passed.",
            ),
            (
                "So the deploy failed, scratch that. The deploy passed.",
                "The deploy passed.",
            ),
            (
                "Um, so that the deploy failed, uh, scratch that, the deploy passed.",
                "The deploy passed.",
            ),
            (
                "This stays. We go Friday, scratch that, we go Monday.",
                "This stays. We go Monday.",
            ),
            ("The deploy failed. Scratch that, it passed.", "It passed."),
            ("Scratch that, it passed.", "It passed."),
            ("Scratch that. Hello there.", "Hello there."),
            ("Ship it on Friday. Scratch that", ""),
            (
                "First. Second. Scratch that. Scratch that. Third.",
                "Third.",
            ),
            ("Ship it. Uh. Scratch that.", ""),
            (
                "Ship it. Um. Scratch that. Ship it Monday.",
                "Ship it Monday.",
            ),
            (
                "Meet at 5 p.m. tomorrow. Scratch that. Meet at 6.",
                "Meet at 6.",
            ),
            (
                "I met Dr. Smith today. Scratch that. I met nobody.",
                "I met nobody.",
            ),
            ("Call Dr. Smith, scratch that, Dr. Jones.", "Dr. Jones."),
            (
                "He said \"stop.\" Then we left, scratch that, we stayed.",
                "He said \"stop.\" We stayed.",
            ),
            (
                "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
                "The deploy passed.",
            ),
            (
                "Uh, I need you to um, fix the login bug, um, and then update the readme.",
                "I need you to fix the login bug, and then update the readme.",
            ),
            ("Run `swift  test`, uh, now.", "Run `swift  test`, now."),
            ("Uh, onTextInserted fired.", "onTextInserted fired."),
            (
                "Um, so that the deploy failed. Ah, scratch that, the deploy passed.",
                "The deploy passed.",
            ),
            (
                "We meet on Friday. Sorry, scratch that, we meet on Monday.",
                "We meet on Monday.",
            ),
            ("Ship it today. No, scratch that.", ""),
            (
                "Ah, I need you to um, fix the login bug, um, and then update the readme.",
                "Ah, I need you to fix the login bug, and then update the readme.",
            ),
            (
                "First paragraph.\n\nUh, second paragraph.",
                "First paragraph.\n\nSecond paragraph.",
            ),
            (
                "Line one.\nLine two. Scratch that. Line three.",
                "Line one.\nLine three.",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(clean(input, true), expected, "input: {input:?}");
        }
    }

    #[test]
    fn keeps_what_was_meant() {
        let unchanged = [
            "Um fünf Uhr treffen wir uns.",
            "Wir gehen um fünf.",
            "Eu tenho um carro.",
            "Benenne die Funktion um.",
            "Wir ziehen nächste Woche um.",
            "Bau die Funktion um, damit sie async ist.",
            "Wir steigen in Berlin um, dann fahren wir weiter.",
            "Er dreht sich um.",
            "Quero um, não dois.",
            "Só preciso de um.",
            "Conta comigo: um, dois, três.",
            "Um, dois, três, quatro.",
            "Mais um?",
            "So um the build passed.",
            "Um.",
            "Use a 3 mm drill bit and a 10 mm bolt.",
            "Толщина стенки 5 мм.",
            "Format the date as dd mm yyyy.",
            "Слово начинается на э.",
            "Отправь эс эм эс.",
            "We trained an HMM on the data.",
            "We need an ERM framework.",
            "I studied at UH.",
            "That was very very good.",
            "I had had enough.",
            "I think that that is right.",
            "Да да, конечно.",
            "What the problem is is that the cache is stale.",
            "Log in in Safari and check the cookie.",
            "Search for for loops in the codebase.",
            "The movie was so so.",
            "My name is Aaron, spelled A A R O N.",
            "Take him to the OR or the ER.",
            "Tell IT it is broken.",
            "Il y a a priori un problème.",
            "Najważniejsze to to, że działa.",
            "Er weiß nicht, was was ist.",
            "Это это?",
            "No, no, no.",
            "Please scratch that line from the file.",
            "If it chips, scratch that spot and repaint.",
            "Scratch that itch.",
            "В третьей строке опечатка. Зачеркни это, а потом перепиши.",
            "Видишь лишнее слово? Зачеркни.",
            "Run `uh` now.",
            "Open /tmp/um/file please.",
            "Call AppState AppState twice.",
            "",
            "   ",
            "Hello,  world.",
            "first line\nsecond line",
            "Ship it.\n",
        ];
        for text in unchanged {
            assert_eq!(clean(text, true), text, "input: {text:?}");
        }
    }

    #[test]
    fn a_meeting_keeps_corrections_and_interjections() {
        assert_eq!(
            clean("Um, the deploy failed. Scratch that. It passed.", false),
            "The deploy failed. Scratch that. It passed."
        );
        assert_eq!(clean("Hmm?", false), "Hmm?");
        assert_eq!(clean("Uh.", false), "Uh.");
    }

    #[test]
    fn is_idempotent() {
        for text in [
            "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
            "We should, um, ship it.",
            "I I think, uh.",
            "Я, э, не уверен.",
            "Set the values to 10, 20, um, 30.",
        ] {
            let once = clean(text, true);
            assert_eq!(clean(&once, true), once, "input: {text:?}");
        }
    }
}

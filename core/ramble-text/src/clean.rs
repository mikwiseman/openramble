//! Cleanup that only ever deletes.
//!
//! Ported from `CleanVerbatim.swift`. Speech carries traces typing never does:
//! hesitations, a word said twice while the next one loads, a sentence taken
//! back out loud. This removes exactly those and nothing else. It never
//! rewords, reorders or adds a word — the difference from cleanup done by a
//! language model, which can turn "don't" into "do". This has no way to write a
//! word that was not said.
//!
//! Three passes, in this order:
//!
//! 1. **Spoken corrections.** "Scratch that" ("Зачеркни это") takes back what
//!    was just said: as its own sentence or opening one, the sentence before it;
//!    at the end of a sentence, or between commas in the middle of one ("we go
//!    Friday, scratch that, we go Monday"), everything before it in that
//!    sentence. The commas are what make it a command rather than the verb.
//!    Runs first because it reads the commas the filler pass removes.
//! 2. **Fillers.** Words that are hesitation in every language the model speaks.
//!    "um" is a real word in German and Portuguese, so it goes only when it
//!    carries punctuation of its own ("um," / "um.").
//! 3. **Stutters.** A short function word said twice in a row with nothing
//!    between. Doubles that mean something ("very very", "да да", "had had") are
//!    not on the list.
//!
//! Protected spans are atomic: a span is never a filler, a stutter or a command,
//! and its text is never edited. Text with nothing to remove comes back exactly
//! as it went in, whitespace included.
//!
//! Spoken corrections are a dictation command. A meeting transcript turns them
//! off: there "scratch that" is something a person said, and the sentence before
//! it may be someone else's.

use crate::span;

/// Hesitation in every language Parakeet speaks: none of these is a word.
const FILLERS: &[&str] = &[
    "uh", "uhh", "uhm", "umm", "erm", "hmm", "hm", "mm", "mmm", "э", "ээ", "эээ", "эм", "эмм",
    "мм", "ммм", "äh", "ähm", "euh",
];

/// A hesitation in English, a word in German ("um fünf") and Portuguese
/// ("um carro"). Removed only when it carries punctuation of its own.
const GUARDED_FILLER: &str = "um";

/// Short function words a speaker repeats while the next word loads.
const STUTTER_WORDS: &[&str] = &[
    "i", "a", "an", "the", "to", "and", "of", "in", "on", "it", "is", "we", "you", "he", "she",
    "they", "so", "but", "my", "our", "your", "for", "with", "at", "be", "was", "if", "or", "я",
    "и", "в", "во", "на", "не", "мы", "ты", "вы", "он", "она", "оно", "они", "это", "а", "но", "с",
    "к", "у", "по", "за", "из", "от", "до", "о",
];

/// Spoken corrections, as the words of a whole sentence.
const CORRECTIONS: &[&[&str]] = &[&["scratch", "that"], &["зачеркни", "это"], &["зачеркни"]];

const TRAILING_PUNCTUATION: &[char] = &[',', '.', ';', ':', '!', '?', '…'];
const SENTENCE_ENDING: &[char] = &['.', '!', '?', '…'];

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

    fn ends_sentence(&self) -> bool {
        self.punctuation()
            .chars()
            .any(|c| SENTENCE_ENDING.contains(&c))
    }

    fn ends_with_comma(&self) -> bool {
        self.text.ends_with(',')
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

    /// Remove `start..=end`, keeping the text's leading whitespace where it was.
    fn remove(&mut self, start: usize, end: usize) {
        let leading = self.items[start].separator.clone();
        self.items.drain(start..=end);
        if start == 0 && !self.items.is_empty() {
            self.items[0].separator = leading;
        }
    }

    fn is_filler(&self, index: usize) -> bool {
        let token = &self.items[index];
        if token.protected {
            return false;
        }
        let word = token.word();
        if FILLERS.contains(&word.as_str()) {
            return true;
        }
        word == GUARDED_FILLER && !token.punctuation().is_empty()
    }

    /// A filler, as far as a correction is concerned: any hesitation word,
    /// guarded or not, because it can only stand between words here.
    fn is_any_filler_word(&self, index: usize) -> bool {
        let token = &self.items[index];
        if token.protected {
            return false;
        }
        let word = token.word();
        FILLERS.contains(&word.as_str()) || word == GUARDED_FILLER
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
            let previous_start = if position > 0 {
                sentences[position - 1].0
            } else {
                start
            };
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
                if matches_at(&spoken, command, 0) && spoken.len() == command.len() {
                    return Some((previous_start, end));
                }
                // Inside a longer sentence only the two-word forms count: a
                // bare "зачеркни" is as likely an instruction to a reader.
                if command.len() < 2 || spoken.len() <= command.len() {
                    continue;
                }
                let Some(offset) =
                    (0..=spoken.len() - command.len()).find(|&at| matches_at(&spoken, command, at))
                else {
                    continue;
                };

                let first = words[offset];
                let last = words[offset + command.len() - 1];
                let opens = offset == 0;
                let closes = offset + command.len() == spoken.len();
                let pause_before = first > start
                    && (self.items[first - 1].ends_with_comma()
                        || self.is_any_filler_word(first - 1));
                let pause_after = self.items[last].ends_with_comma();

                if opens && pause_after {
                    return Some((previous_start, last));
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

    // Pass 2: fillers

    fn remove_fillers(&mut self) -> bool {
        let mut changed = false;
        let mut index = 0;
        while index < self.items.len() {
            if !self.is_filler(index) {
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
                    && (filler.ends_with_comma() || is_last)
                {
                    // The commas around a hesitation mark the pause, not the grammar.
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
            ("We should, um, ship it.", "We should ship it."),
            ("We should, uh, ship it.", "We should ship it."),
            ("Then uh we ship it.", "Then we ship it."),
            ("It is hmm fine.", "It is fine."),
            ("Done. Uh, the next one.", "Done. The next one."),
            ("I think, uh.", "I think."),
            ("I think uh.", "I think."),
            ("Is it ready, um?", "Is it ready?"),
            (
                "Ээ, я думаю, что это работает.",
                "Я думаю, что это работает.",
            ),
            ("Я, э, не уверен.", "Я не уверен."),
            ("Мм, давай завтра.", "Давай завтра."),
            ("Ähm, ich komme morgen.", "Ich komme morgen."),
            ("Euh, je pense que oui.", "Je pense que oui."),
            ("Um.", ""),
            ("Uh, uh.", ""),
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
                "Встреча в пятницу. Зачеркни это. Встреча в субботу.",
                "Встреча в субботу.",
            ),
            (
                "Встреча в пятницу. Зачеркни. Встреча в субботу.",
                "Встреча в субботу.",
            ),
            (
                "So the deploy failed, scratch that. The deploy passed.",
                "The deploy passed.",
            ),
            ("Scratch that. Hello there.", "Hello there."),
            ("Ship it on Friday. Scratch that", ""),
            (
                "First. Second. Scratch that. Scratch that. Third.",
                "Third.",
            ),
            (
                "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
                "The deploy passed.",
            ),
            ("Run `swift  test`, uh, now.", "Run `swift  test` now."),
            ("I need you to um, fix it.", "I need you to fix it."),
            (
                "Um, so that the deploy failed, uh, scratch that, the deploy passed.",
                "The deploy passed.",
            ),
            (
                "This stays. We go Friday, scratch that, we go Monday.",
                "This stays. We go Monday.",
            ),
            ("Встреча в пятницу, зачеркни это, в субботу.", "В субботу."),
            ("The deploy failed. Scratch that, it passed.", "It passed."),
            ("Scratch that, it passed.", "It passed."),
            (
                "We should, um, ship it on Friday. I I think that the tests are green, uh, mostly.",
                "We should ship it on Friday. I think that the tests are green mostly.",
            ),
            (
                "Uh, I need you to um, fix the login bug, um, and then update the readme.",
                "I need you to fix the login bug and then update the readme.",
            ),
            ("Uh, onTextInserted fired.", "onTextInserted fired."),
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
            "So um the build passed.",
            "That was very very good.",
            "I had had enough.",
            "I think that that is right.",
            "Да да, конечно.",
            "Так так, посмотрим.",
            "No, no, no.",
            "The, the answer is yes.",
            "Please scratch that line from the file.",
            "Scratch that itch.",
            "If it chips, scratch that spot and repaint.",
            "Um 5 Uhr treffen wir uns im Büro.",
            "Зачеркни строку в файле.",
            "Run `uh` now.",
            "Open /tmp/um/file please.",
            "Call AppState AppState twice.",
            "",
            "   ",
            "Hello.",
            "Hello,  world.",
            "first line\nsecond line",
            "Ship it.\n",
        ];
        for text in unchanged {
            assert_eq!(clean(text, true), text, "input: {text:?}");
        }
    }

    #[test]
    fn a_meeting_transcript_keeps_spoken_corrections() {
        assert_eq!(
            clean("Um, the deploy failed. Scratch that. It passed.", false),
            "The deploy failed. Scratch that. It passed."
        );
    }

    #[test]
    fn is_idempotent() {
        for text in [
            "Um, so the the deploy failed, uh, scratch that. The deploy passed.",
            "We should, um, ship it.",
            "I I think, uh.",
            "Я, э, не уверен.",
        ] {
            let once = clean(text, true);
            assert_eq!(clean(&once, true), once, "input: {text:?}");
        }
    }
}

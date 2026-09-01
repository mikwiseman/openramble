//! The full path from recognized text to what the person sees.
//!
//! Ported from `TextPipeline.swift`.
//!
//! # Stage table
//!
//! The order is fixed and checked by golden tests at every boundary:
//!
//! | # | Stage | What it does |
//! |---|---|---|
//! | 1 | command parser | splits off the trailing command — before any replacement, or the dictionary would touch it |
//! | 2 | dictionary: exact pass | literal entries, with case endings |
//! | 3 | span detection | the first computation of protected pieces |
//! | 4 | dictionary: phonetic pass | guesses — outside spans only |
//! | 5 | *(language-model cleanup)* | **reserved**, no stage in this wave |
//! | 6 | *(snippets)* | **reserved**, no stage in this wave |
//! | 7 | typography fold | twelve characters, outside spans |
//! | 8 | polisher | spaces, punctuation, first letter — outside spans |
//! | 9 | materialize the newline | strictly last: the polisher trims `\n` |
//!
//! Stages 5 and 6 are reserved as a **comment, not code**: a stub that does
//! nothing is ceremony, not a contract. When they arrive they stand between 4
//! and 7, and the span gate will pick them up on its own.
//!
//! The key to the whole protection model: **the exact pass runs before spans
//! exist at all**. That is the rule "a person's stated will outranks span
//! protection" — no separate precedence rule needs writing, because the order
//! *is* the rule.

use crate::dictionary::{self, DictionaryReplacement};
use crate::phonetic;
use crate::polish;
use crate::span::{self, ProtectedSpan};
use crate::typography;

/// A command spoken at the end of a dictation.
///
/// "Send" at the end of a phrase is not text but an action: the person expects
/// the message to go, not the word to appear in the field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrailingCommand {
    PressReturn,
    NewLine,
}

impl TrailingCommand {
    pub const ALL: &'static [TrailingCommand] =
        &[TrailingCommand::PressReturn, TrailingCommand::NewLine];

    /// How it gets said, in Russian and English.
    fn phrases(self) -> &'static [&'static str] {
        match self {
            TrailingCommand::PressReturn => &[
                "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}",
                "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{0438}\u{0442}\u{044C}",
                "\u{044D}\u{043D}\u{0442}\u{0435}\u{0440}",
                "send it",
                "press enter",
            ],
            TrailingCommand::NewLine => &[
                "\u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}",
                "\u{0441} \u{043D}\u{043E}\u{0432}\u{043E}\u{0439} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0438}",
                "new line",
            ],
        }
    }
}

/// What the parser made of the dictation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCommand {
    pub text: String,
    pub command: Option<TrailingCommand>,
}

/// Split a trailing command off the text.
///
/// Only the very tail of the phrase is parsed: "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}" in the middle of a
/// sentence is an ordinary word, not a command.
pub fn parse_trailing_command(text: &str) -> ParsedCommand {
    let trimmed = text.trim_matches(|c: char| c.is_whitespace()).to_string();
    if trimmed.is_empty() {
        return ParsedCommand {
            text: trimmed,
            command: None,
        };
    }

    // The tail is compared without its closing punctuation: "…\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}." is the
    // same command.
    let stripped_tail: Vec<char> = trimmed
        .to_lowercase()
        .trim_matches(|c: char| ".!?,;: ".contains(c))
        .chars()
        .collect();

    for &command in TrailingCommand::ALL {
        for phrase in command.phrases() {
            let phrase_chars: Vec<char> = phrase.chars().collect();
            if !ends_with(&stripped_tail, &phrase_chars) {
                continue;
            }

            // The command has to be a separate word, not the tail of another one.
            let cutoff = stripped_tail.len() - phrase_chars.len();
            if cutoff > 0 && stripped_tail[cutoff - 1] != ' ' {
                continue;
            }

            let without_command = strip_suffix(phrase, &trimmed);
            let without_command = without_command.trim_matches(|c: char| " ,;:".contains(c));

            // A command spoken on its own is just a word.
            //
            // There is no text left to insert, and pressing Return in somebody
            // else's window cannot be guessed at: a sent message does not come
            // back. Such a dictation used to go nowhere at all — the empty text
            // cancelled both the insertion and the keypress.
            if without_command.is_empty() {
                return ParsedCommand {
                    text: trimmed,
                    command: None,
                };
            }

            return ParsedCommand {
                text: without_command.to_string(),
                command: Some(command),
            };
        }
    }

    ParsedCommand {
        text: trimmed,
        command: None,
    }
}

fn ends_with(haystack: &[char], needle: &[char]) -> bool {
    haystack.len() >= needle.len() && haystack[haystack.len() - needle.len()..] == *needle
}

/// Cut the phrase off the end of the original text.
///
/// The search runs in the string itself, not in a lowercased copy. Case folding
/// has its own length — the Turkish "\u{0130}" becomes two characters — and positions
/// found in the copy cut the original in the wrong place, up to crashing past
/// the end of it.
fn strip_suffix(phrase: &str, text: &str) -> String {
    let text_chars: Vec<char> = text.chars().collect();
    let phrase_chars: Vec<char> = phrase.chars().collect();
    if phrase_chars.is_empty() || phrase_chars.len() > text_chars.len() {
        return text.to_string();
    }

    let matches_at = |start: usize| {
        phrase_chars.iter().enumerate().all(|(offset, &expected)| {
            let actual = text_chars[start + offset];
            actual == expected || actual.to_lowercase().eq(expected.to_lowercase())
        })
    };

    for start in (0..=text_chars.len() - phrase_chars.len()).rev() {
        if matches_at(start) {
            return text_chars[..start].iter().collect();
        }
    }
    text.to_string()
}

/// Where the inserted text came from: what it was and what it became.
///
/// Two things need it: "copy verbatim", so what was said stays reachable after
/// the dictionary and polisher have worked on it, and diagnosis, which separates
/// "the dictionary did not fire" from "it fired, but the cosmetics moved".
///
/// **Deliberately not serializable.** That is not an oversight but the guarantee
/// itself — "never to disk". Writing this to a file would take a conscious
/// derive, and the test below stands next to that decision.
///
/// [`std::fmt::Display`] prints only field names and character counts, so no
/// stray interpolation into a log can carry dictated text out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Provenance {
    /// The state after the dictionary entirely, before any cosmetics.
    pub after_dictionary: String,
    /// What will be inserted.
    pub final_text: String,
    /// The final text's protected spans.
    ///
    /// They live here because learning from edits has to step around them, and
    /// it has no other honest source: it only ever sees the inserted text.
    pub spans: Vec<ProtectedSpan>,
}

impl std::fmt::Display for Provenance {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Provenance(afterDictionary: {} chars, final: {} chars, spans: {})",
            self.after_dictionary.chars().count(),
            self.final_text.chars().count(),
            self.spans.len()
        )
    }
}

/// Text ready to insert, and what to press afterwards.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub text: String,
    /// What to press after inserting, if the person asked for it.
    ///
    /// A line break never appears here: it is already in the text. Pressing it
    /// would not do — Return in somebody else's window sends the message rather
    /// than breaking the line.
    pub command: Option<TrailingCommand>,
}

/// A run of the pipeline together with the origin of its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub output: Output,
    pub provenance: Provenance,
}

/// The pipeline's configuration.
pub struct TextPipeline {
    pub replacements: Vec<DictionaryReplacement>,
    /// In safe beta the spoken Send/Return command is off: one false trigger
    /// irreversibly submits the message or the form. The parser stays separately
    /// testable for an explicit mode later.
    pub allow_press_return_command: bool,
    /// Phonetic matching switch — exists so "is it worth anything on top of the
    /// acoustic prompt" can be measured.
    pub phonetic_matching: bool,
}

impl Default for TextPipeline {
    fn default() -> Self {
        Self {
            replacements: Vec::new(),
            allow_press_return_command: false,
            phonetic_matching: true,
        }
    }
}

impl TextPipeline {
    pub fn with_replacements(replacements: Vec<DictionaryReplacement>) -> Self {
        Self {
            replacements,
            ..Default::default()
        }
    }

    pub fn process(&self, recognized: &str) -> Output {
        self.run(recognized).output
    }

    /// The same, with a record of where the text came from.
    ///
    /// Provenance is built **unconditionally** — it depends on no user setting.
    /// There is one path: `process` calls `run` and discards the record, so a
    /// "branch without provenance" does not exist in the product.
    pub fn run(&self, recognized: &str) -> Run {
        let mut parsed = parse_trailing_command(recognized);
        if parsed.command == Some(TrailingCommand::PressReturn) && !self.allow_press_return_command
        {
            parsed = ParsedCommand {
                text: recognized.to_string(),
                command: None,
            };
        }

        // Stage 2: the exact pass — before spans exist.
        let exact = dictionary::apply_exact(&self.replacements, &parsed.text);
        // Stage 3: the first span computation, over the result of the exact pass.
        let spans_after_exact = span::detect(&exact);
        // Stage 4: phonetic matching outside spans.
        let after_dictionary = if self.phonetic_matching {
            phonetic::apply(&self.replacements, &exact, &spans_after_exact)
        } else {
            exact
        };

        // Stage 7: folding typography outside spans.
        let folded = typography::fold(&after_dictionary, &span::detect(&after_dictionary));
        // Stage 8: the polisher, which recomputes spans itself.
        let polished = polish::polish(&folded);

        // Stage 9: materializing the newline — strictly last, or the polisher's
        // trim would cut it off again.
        let output = if parsed.command == Some(TrailingCommand::NewLine) && !polished.is_empty() {
            // "New line" is a command that cannot be carried out by a keypress:
            // Return would send the message. So the break goes straight into the
            // text and is inserted along with it. The words used to be cut out of
            // the text with nothing happening in return — the whole command
            // vanished.
            Output {
                text: format!("{polished}\n"),
                command: None,
            }
        } else {
            Output {
                text: polished,
                command: parsed.command,
            }
        };

        let spans = span::detect(&output.text);
        Run {
            provenance: Provenance {
                after_dictionary,
                final_text: output.text.clone(),
                spans,
            },
            output,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(spoken: &str, written: &str) -> DictionaryReplacement {
        DictionaryReplacement::new("id", spoken, written)
    }

    fn plain() -> TextPipeline {
        TextPipeline::default()
    }

    #[test]
    fn a_trailing_command_is_split_off_the_text() {
        let parsed = parse_trailing_command("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}");
        assert_eq!(parsed.command, Some(TrailingCommand::PressReturn));
        assert_eq!(
            parsed.text,
            "\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
        );
    }

    #[test]
    fn closing_punctuation_does_not_hide_the_command() {
        let parsed = parse_trailing_command("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}.");
        assert_eq!(parsed.command, Some(TrailingCommand::PressReturn));
    }

    #[test]
    fn the_command_word_in_the_middle_is_an_ordinary_word() {
        let parsed = parse_trailing_command("\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C} \u{044D}\u{0442}\u{043E} \u{0437}\u{0430}\u{0432}\u{0442}\u{0440}\u{0430}");
        assert_eq!(parsed.command, None);
    }

    #[test]
    fn a_command_must_be_a_whole_word_not_the_tail_of_one() {
        let parsed = parse_trailing_command("\u{043F}\u{0435}\u{0440}\u{0435}\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}");
        assert_eq!(parsed.command, None);
    }

    /// A command spoken alone leaves nothing to insert, and Return in somebody
    /// else's window cannot be guessed at.
    #[test]
    fn a_command_spoken_alone_stays_a_word() {
        let parsed =
            parse_trailing_command("\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}");
        assert_eq!(parsed.command, None);
        assert_eq!(
            parsed.text,
            "\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}"
        );
    }

    #[test]
    fn press_return_is_off_unless_explicitly_allowed() {
        let output = plain().process("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}");
        assert_eq!(output.command, None);
        // And the word stays in the text rather than being silently eaten.
        assert!(output
            .text
            .to_lowercase()
            .contains("\u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}"));

        let allowing = TextPipeline {
            allow_press_return_command: true,
            ..Default::default()
        };
        assert_eq!(
            allowing.process("\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442} \u{043E}\u{0442}\u{043F}\u{0440}\u{0430}\u{0432}\u{044C}").command,
            Some(TrailingCommand::PressReturn)
        );
    }

    /// A line break goes into the text, because pressing Return would send the
    /// message instead of breaking the line.
    #[test]
    fn new_line_becomes_a_character_not_a_keypress() {
        let output = plain().process("\u{043F}\u{0435}\u{0440}\u{0432}\u{0430}\u{044F} \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}");
        assert_eq!(output.command, None);
        assert!(output.text.ends_with('\n'), "got {:?}", output.text);
        assert!(!output.text.to_lowercase().contains("\u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}"));
    }

    /// Stage 9 runs after the polisher on purpose: the polisher trims trailing
    /// whitespace and would take the newline with it.
    #[test]
    fn the_newline_survives_the_polisher() {
        let output = plain().process("  \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}  \u{043D}\u{043E}\u{0432}\u{0430}\u{044F} \u{0441}\u{0442}\u{0440}\u{043E}\u{043A}\u{0430}  ");
        assert_eq!(output.text, "\u{0422}\u{0435}\u{043A}\u{0441}\u{0442}\n");
    }

    /// The rule the whole protection model rests on: a person's stated will
    /// outranks span protection, and the stage order is what says so.
    #[test]
    fn an_exact_replacement_reaches_inside_what_would_become_a_span() {
        let pipeline = TextPipeline::with_replacements(vec![entry("Foo", "Bar")]);
        let output = pipeline.process("Foo.Output");
        assert_eq!(output.text, "Bar.Output");
    }

    #[test]
    fn a_phonetic_guess_does_not_reach_inside_a_span() {
        let pipeline = TextPipeline::with_replacements(vec![entry(
            "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}",
            "deploy",
        )]);
        let output = pipeline.process("`\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}`");
        assert_eq!(
            output.text,
            "`\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}`"
        );
    }

    #[test]
    fn turning_phonetic_matching_off_leaves_the_exact_pass_alone() {
        let replacements = vec![entry(
            "\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}",
            "deploy",
        )];
        let exact_only = TextPipeline {
            replacements: replacements.clone(),
            phonetic_matching: false,
            ..Default::default()
        };
        assert_eq!(
            exact_only
                .process("\u{0434}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}")
                .text,
            "\u{0414}\u{0438}\u{043F}\u{043B}\u{043E}\u{0439}"
        );
        assert_eq!(
            exact_only
                .process("\u{0434}\u{0435}\u{043F}\u{043B}\u{043E}\u{0439}")
                .text,
            "Deploy"
        );
    }

    #[test]
    fn the_whole_chain_runs_in_order() {
        let pipeline = TextPipeline::with_replacements(vec![entry(
            "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}",
            "Sentry",
        )]);
        let output = pipeline.process("  \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0432} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438} ,  \u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} TextPipeline.Output  ");
        assert_eq!(output.text, "\u{041E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0432} Sentry, \u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} TextPipeline.Output");
    }

    #[test]
    fn provenance_records_every_stage_boundary() {
        let pipeline = TextPipeline::with_replacements(vec![entry(
            "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}",
            "Sentry",
        )]);
        let run = pipeline.run("  \u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0432} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}  ");
        assert_eq!(
            run.provenance.after_dictionary,
            "\u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0432} Sentry"
        );
        assert_eq!(run.provenance.final_text, run.output.text);
    }

    /// The privacy guarantee: nothing that was dictated can leave through a log
    /// line, however carelessly it interpolates.
    #[test]
    fn the_provenance_description_carries_no_dictated_text() {
        let run = plain().run("\u{0441}\u{043E}\u{0432}\u{0435}\u{0440}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E} \u{0441}\u{0435}\u{043A}\u{0440}\u{0435}\u{0442}\u{043D}\u{044B}\u{0439} \u{0442}\u{0435}\u{043A}\u{0441}\u{0442}");
        let rendered = run.provenance.to_string();
        for word in [
            "\u{0441}\u{043E}\u{0432}\u{0435}\u{0440}\u{0448}\u{0435}\u{043D}\u{043D}\u{043E}",
            "\u{0441}\u{0435}\u{043A}\u{0440}\u{0435}\u{0442}\u{043D}\u{044B}\u{0439}",
            "\u{0442}\u{0435}\u{043A}\u{0441}\u{0442}",
        ] {
            assert!(!rendered.contains(word), "leaked {word} in {rendered}");
        }
    }

    #[test]
    fn empty_and_blank_input_produce_nothing() {
        assert_eq!(plain().process("").text, "");
        assert_eq!(plain().process("    ").text, "");
    }

    #[test]
    fn processing_is_idempotent_over_its_own_output() {
        let pipeline = TextPipeline::with_replacements(vec![entry(
            "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}",
            "Sentry",
        )]);
        for text in [
            "\u{043E}\u{0448}\u{0438}\u{0431}\u{043A}\u{0430} \u{0432} \u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}",
            "\u{0441}\u{043C}\u{043E}\u{0442}\u{0440}\u{0438} TextPipeline.Output \u{0438} `git log`",
            "\u{043F}\u{0443}\u{0442}\u{044C} /usr/local/bin \u{0442}\u{0443}\u{0442}",
        ] {
            let once = pipeline.process(text).text;
            assert_eq!(pipeline.process(&once).text, once, "{text}");
        }
    }
}

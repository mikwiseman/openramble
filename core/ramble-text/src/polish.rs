//! Deterministic tidying of recognized text.
//!
//! Ported from `TranscriptPolisher.swift`. No language models: only what can be
//! tested and predicted. Nothing here changes meaning — it removes the traces of
//! text having come from recognition rather than a keyboard.
//!
//! What is deliberately not done: expanding numerals ("twenty five" → "25").
//! In Russian that depends on case and declension, and it breaks more than it fixes.

use crate::span::{self, ProtectedSpan};

/// Turn recognized text into something fit to insert.
///
/// Protected spans are untouched by every operation. Spans are recomputed before
/// each step rather than counted once: the previous step may have shifted the
/// offsets, and a floating range is exactly the class of bug that rots systems
/// like this. Detection is pure and idempotent, so recomputing costs nothing.
pub fn polish(text: &str) -> String {
    let trimmed = text.trim_matches(|c: char| c.is_whitespace());
    if trimmed.is_empty() {
        return String::new();
    }

    let collapsed = collapse_whitespace(trimmed, &span::detect(trimmed));
    let spaced = fix_spacing_around_punctuation(&collapsed, &span::detect(&collapsed));
    capitalize_first_letter(&spaced, &span::detect(&spaced))
}

/// Collapse repeated spaces, keeping newlines.
///
/// Spaces inside a protected piece stay exactly as they are: what sits in
/// backticks is code, and its alignment is meaningful.
pub fn collapse_whitespace(text: &str, spans: &[ProtectedSpan]) -> String {
    if spans.is_empty() {
        return text
            .split('\n')
            .map(|line| {
                line.split([' ', '\t'])
                    .filter(|part| !part.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .collect::<Vec<_>>()
            .join("\n");
    }

    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut span_index = 0;
    let mut index = 0;

    while index < characters.len() {
        while span_index < spans.len() && spans[span_index].end <= index {
            span_index += 1;
        }
        if span_index < spans.len() && spans[span_index].contains(index) {
            let span = &spans[span_index];
            result.extend(&characters[span.start..span.end]);
            index = span.end;
            continue;
        }

        let character = characters[index];
        if character == ' ' || character == '\t' {
            // A space in front of a protected piece collapses too — it is not
            // part of the piece.
            let last = result.chars().last();
            if last != Some(' ') && last != Some('\n') {
                result.push(' ');
            }
            index += 1;
            continue;
        }
        result.push(character);
        index += 1;
    }
    result
}

/// Remove the space before a punctuation mark, and add one after it where it is
/// definitely missing.
///
/// Inserting spaces is deliberately timid. The model itself turns "three point
/// one four" into "3.14", and a full stop appears in version numbers ("2.0.1"),
/// domains ("wai.computer") and abbreviations ("etc."); a colon appears in links
/// ("https://") and times ("12:30"). A space after every full stop broke all of
/// those — measured against real model output.
///
/// So the rule for a full stop and a colon stays what it was: add a space only
/// before a capital letter, which is to say only when a new sentence begins.
///
/// That guard survives the arrival of spans because the two filter on different
/// axes. The guard looks at what comes AFTER the mark — this is what protects
/// `3.14`, `wai.computer`, `etc.`, `https://`, `12:30`, all of which have a digit
/// or a lowercase letter next. A span looks at WHAT the token is. Dropping the
/// guard now that spans exist is a tempting mistake: numbers, domains and
/// abbreviations never become spans and would lose their protection. Spans fix
/// the guard's one blind spot, `TextPipeline.Output`.
pub fn fix_spacing_around_punctuation(text: &str, spans: &[ProtectedSpan]) -> String {
    const CLOSING: &[char] = &[',', '.', '!', '?', ';', ':', '\u{2026}'];
    /// Marks after which a space is always needed if a letter follows.
    ///
    /// "first, second" is what the model always produces, and there is no capital
    /// there — under the capital-only rule the list stayed glued together. None
    /// of these marks has a spelling where a letter legitimately abuts it: the
    /// only such place for a comma is a decimal fraction, and that has a digit
    /// next, which this rule does not touch.
    const ALWAYS_SEPARATING: &[char] = &[',', '!', '?', ';', '\u{2026}'];

    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());
    let mut span_index = 0;
    let mut index = 0;

    while index < characters.len() {
        // The protected piece is carried across verbatim: this is where `Foo.Bar`
        // stops becoming `Foo. Bar`.
        while span_index < spans.len() && spans[span_index].end <= index {
            span_index += 1;
        }
        if span_index < spans.len() && spans[span_index].contains(index) {
            let span = &spans[span_index];
            result.extend(&characters[span.start..span.end]);
            index = span.end;
            continue;
        }

        let character = characters[index];

        if CLOSING.contains(&character) {
            // A space before punctuation is a recognition artefact.
            while result.ends_with(' ') {
                result.pop();
            }
            result.push(character);

            if let Some(&next) = characters.get(index + 1) {
                if next.is_uppercase()
                    || (ALWAYS_SEPARATING.contains(&character) && next.is_alphabetic())
                {
                    result.push(' ');
                }
            }
            index += 1;
            continue;
        }

        result.push(character);
        index += 1;
    }
    result
}

/// Capitalize the first letter — recognition often hands back a lowercase one.
///
/// An identifier at the start of the dictation gets no capital: a dictated first
/// word of `onTextInserted` is a name, and `OnTextInserted` would simply be a
/// different name.
pub fn capitalize_first_letter(text: &str, spans: &[ProtectedSpan]) -> String {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return String::new();
    };
    if !first.is_lowercase() {
        return text.to_string();
    }
    if spans.iter().any(|span| span.contains(0)) {
        return text.to_string();
    }
    first.to_uppercase().collect::<String>() + chars.as_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_spaces_collapse_but_newlines_survive() {
        assert_eq!(collapse_whitespace("a   b", &[]), "a b");
        assert_eq!(collapse_whitespace("a \t b", &[]), "a b");
        assert_eq!(collapse_whitespace("a\n\nb", &[]), "a\n\nb");
    }

    #[test]
    fn alignment_inside_backticks_is_meaningful_and_kept() {
        let text = "run `a   b` now";
        assert_eq!(collapse_whitespace(text, &span::detect(text)), text);
    }

    #[test]
    fn a_space_before_punctuation_is_a_recognition_artefact() {
        assert_eq!(
            fix_spacing_around_punctuation("hello , world", &[]),
            "hello, world"
        );
        assert_eq!(fix_spacing_around_punctuation("what ?", &[]), "what?");
    }

    /// The rule the guard exists for: these all have a digit or lowercase next.
    #[test]
    fn numbers_domains_abbreviations_links_and_times_keep_their_shape() {
        for text in [
            "3.14",
            "2.0.1",
            "wai.computer",
            "etc.",
            "https://x.dev",
            "12:30",
        ] {
            assert_eq!(fix_spacing_around_punctuation(text, &[]), text, "{text}");
        }
    }

    #[test]
    fn a_comma_separates_a_list_even_without_a_capital() {
        assert_eq!(
            fix_spacing_around_punctuation("first,second", &[]),
            "first, second"
        );
    }

    #[test]
    fn a_full_stop_before_a_capital_starts_a_new_sentence() {
        assert_eq!(
            fix_spacing_around_punctuation("done.Next one", &[]),
            "done. Next one"
        );
    }

    /// The defect the whole span model was built for.
    #[test]
    fn a_dotted_identifier_does_not_gain_a_space() {
        let text = "see TextPipeline.Output";
        assert_eq!(
            fix_spacing_around_punctuation(text, &span::detect(text)),
            text
        );
    }

    #[test]
    fn the_first_letter_is_capitalized() {
        assert_eq!(capitalize_first_letter("hello", &[]), "Hello");
        assert_eq!(capitalize_first_letter("Hello", &[]), "Hello");
        assert_eq!(capitalize_first_letter("", &[]), "");
    }

    #[test]
    fn an_identifier_dictated_first_keeps_its_own_name() {
        let text = "onTextInserted is the hook";
        assert_eq!(capitalize_first_letter(text, &span::detect(text)), text);
    }

    #[test]
    fn polishing_runs_the_whole_chain() {
        assert_eq!(polish("  hello ,  world  "), "Hello, world");
        assert_eq!(polish("   "), "");
        assert_eq!(polish(""), "");
    }

    #[test]
    fn polishing_is_idempotent() {
        for text in [
            "hello , world",
            "see TextPipeline.Output now",
            "run `a   b` and /usr/local/bin",
        ] {
            let once = polish(text);
            assert_eq!(polish(&once), once, "{text}");
        }
    }
}

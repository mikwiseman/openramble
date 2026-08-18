//! Folding typography back to what a person would have typed by hand.
//!
//! Ported from `TypographyFold.swift`. Why the stage exists, before any language
//! model:
//!
//! 1. Applications with "smart" substitution (Notion, Pages, Mail) rewrite
//!    straight quotes into curly ones and a hyphen into a dash right in the
//!    field. Learning from edits compares what was inserted against what was
//!    read back, and after such a substitution the comparison stops converging —
//!    the learning dies silently.
//! 2. Invisible characters arrive through the dictionary: a person pastes the
//!    written form, and a no-break space, a BOM or a soft hyphen is not visible
//!    in the settings at all.
//! 3. Look-alike characters break the span model itself: `U+2212` MINUS before a
//!    letter makes `−x` not a flag.
//!
//! The table is closed and small on purpose. Everything meaningful stays:
//! guillemets are correct Russian typography, an em dash differs from a hyphen
//! in meaning, and the polisher owns ellipses.

use crate::span::ProtectedSpan;

/// Exactly twelve characters. An empty replacement means "delete".
const TABLE: &[(char, &str)] = &[
    // Invisible spaces → an ordinary space.
    ('\u{00A0}', " "), // NO-BREAK SPACE
    ('\u{202F}', " "), // NARROW NO-BREAK SPACE
    ('\u{2009}', " "), // THIN SPACE
    // Invisible entirely → gone.
    ('\u{200B}', ""), // ZERO WIDTH SPACE
    ('\u{FEFF}', ""), // ZERO WIDTH NO-BREAK SPACE / BOM
    ('\u{00AD}', ""), // SOFT HYPHEN
    // Paired quotes → straight ones.
    ('\u{2018}', "'"),  // LEFT SINGLE QUOTATION MARK
    ('\u{2019}', "'"),  // RIGHT SINGLE QUOTATION MARK
    ('\u{201C}', "\""), // LEFT DOUBLE QUOTATION MARK
    ('\u{201D}', "\""), // RIGHT DOUBLE QUOTATION MARK
    // Hyphen and dash look-alikes → the canonical one.
    ('\u{2212}', "-"),        // MINUS SIGN
    ('\u{2015}', "\u{2014}"), // HORIZONTAL BAR → EM DASH
];

fn replacement(character: char) -> Option<&'static str> {
    TABLE
        .iter()
        .find(|(from, _)| *from == character)
        .map(|(_, to)| *to)
}

/// Fold everything outside the protected pieces.
///
/// There is code inside backticks: a quote there is meaningful, and replacing it
/// would break it.
pub fn fold(text: &str, spans: &[ProtectedSpan]) -> String {
    if text.is_empty() {
        return String::new();
    }

    let characters: Vec<char> = text.chars().collect();
    let mut result = String::with_capacity(text.len());

    let mut span_index = 0;
    let mut index = 0;
    while index < characters.len() {
        // Spans are sorted and never overlap, so one cursor is enough.
        while span_index < spans.len() && spans[span_index].end <= index {
            span_index += 1;
        }
        if span_index < spans.len() && spans[span_index].contains(index) {
            let span = &spans[span_index];
            result.extend(&characters[span.start..span.end]);
            index = span.end;
            continue;
        }

        match replacement(characters[index]) {
            Some(text) => result.push_str(text),
            None => result.push(characters[index]),
        }
        index += 1;
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::span;

    fn folded(text: &str) -> String {
        fold(text, &[])
    }

    #[test]
    fn curly_quotes_become_straight_ones() {
        assert_eq!(folded("\u{201C}hi\u{201D}"), "\"hi\"");
        assert_eq!(folded("\u{2018}hi\u{2019}"), "'hi'");
    }

    #[test]
    fn invisible_characters_are_removed_or_made_visible() {
        assert_eq!(folded("a\u{00A0}b"), "a b");
        assert_eq!(folded("a\u{200B}b"), "ab");
        assert_eq!(folded("\u{FEFF}text"), "text");
        assert_eq!(folded("soft\u{00AD}hyphen"), "softhyphen");
    }

    #[test]
    fn a_minus_sign_becomes_a_hyphen_so_a_flag_stays_a_flag() {
        assert_eq!(folded("\u{2212}x"), "-x");
        // And the folded form is what the detector can now see.
        assert!(!span::detect(&folded("\u{2212}x")).is_empty());
    }

    #[test]
    fn the_table_is_exactly_twelve_entries() {
        // Growing it is a decision, not an accident: every character here has a
        // reason recorded above.
        assert_eq!(TABLE.len(), 12);
    }

    #[test]
    fn meaningful_typography_survives() {
        // Guillemets are correct Russian typography and an em dash is not a hyphen.
        assert_eq!(
            folded("\u{00AB}\u{0434}\u{0430}\u{00BB} \u{2014} \u{043D}\u{0435}\u{0442}"),
            "\u{00AB}\u{0434}\u{0430}\u{00BB} \u{2014} \u{043D}\u{0435}\u{0442}"
        );
    }

    #[test]
    fn a_quote_inside_backticks_is_left_alone() {
        let text = "say `\u{201C}hi\u{201D}` and \u{201C}bye\u{201D}";
        let spans = span::detect(text);
        assert_eq!(fold(text, &spans), "say `\u{201C}hi\u{201D}` and \"bye\"");
    }

    #[test]
    fn folding_an_empty_text_is_empty() {
        assert_eq!(folded(""), "");
    }
}

//! Ready-made replacements for dictating Russian with English terms.
//!
//! The model recognizes Russian speech and writes the anglicisms as it hears
//! them: "pull request" comes back in Cyrillic, "Sentry" as "\u{0441}\u{0435}\u{043D}\u{0442}\u{0440}\u{0438}". That is not a
//! defect — inside a Russian phrase it should write Cyrillic — and this
//! dictionary puts the terms back into the form a person meant.
//!
//! **The list is not written here.** It is generated from
//! `StarterDictionary.swift` into `core/conformance/fixtures/text/`, because
//! several entries carry flags that were measured rather than reasoned: which
//! terms must stay out of the acoustic prompt because their Cyrillic sound is an
//! ordinary Russian word, and which must never be phonetic candidates for the
//! same reason. A second hand-maintained copy would drift from those
//! measurements silently, and the cost of that is a person's ordinary speech
//! being rewritten into a technical term.

use crate::dictionary::DictionaryReplacement;
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StarterEntry {
    spoken: String,
    written: String,
    inflects: bool,
    no_acoustic_boost: bool,
    allows_phonetic_matching: bool,
}

const RECORDED: &str = include_str!("../../conformance/fixtures/text/starter-dictionary.json");

/// The supplied developer terms.
///
/// Ids are positional and stable, so an entry keeps its identity across launches
/// without the generated file having to carry UUIDs that mean nothing.
pub fn developer() -> Vec<DictionaryReplacement> {
    let entries: Vec<StarterEntry> =
        serde_json::from_str(RECORDED).expect("the generated starter dictionary must parse");
    entries
        .into_iter()
        .enumerate()
        .map(|(index, entry)| DictionaryReplacement {
            id: format!("starter-{index}"),
            spoken: entry.spoken,
            written: entry.written,
            inflects: entry.inflects,
            no_acoustic_boost: entry.no_acoustic_boost,
            allows_phonetic_matching: entry.allows_phonetic_matching,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pipeline::TextPipeline;

    #[test]
    fn the_supplied_dictionary_loads() {
        let entries = developer();
        assert!(entries.len() > 40, "only {} entries", entries.len());
        assert!(entries.iter().all(|entry| !entry.spoken.is_empty()));
        assert!(entries.iter().all(|entry| !entry.written.is_empty()));
    }

    /// The three terms whose Cyrillic sound is an ordinary Russian word.
    ///
    /// The flag lives in the data rather than in a filter somewhere downstream.
    /// Losing it silently rolls back a measurement that cost a day: "deploy"
    /// catches "\u{0442}\u{0451}\u{043F}\u{043B}\u{044B}\u{0439}", "Sentry" catches "\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435}", "commit" catches "\u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{0430}".
    #[test]
    fn the_terms_that_sound_like_ordinary_speech_stay_out_of_the_prompt() {
        let entries = developer();
        for term in ["deploy", "Sentry", "commit"] {
            let matching: Vec<_> = entries.iter().filter(|e| e.written == term).collect();
            assert!(
                !matching.is_empty(),
                "{term} is missing from the dictionary"
            );
            assert!(
                matching.iter().all(|entry| entry.no_acoustic_boost),
                "{term} must not be given to the acoustic prompt"
            );
        }
    }

    #[test]
    fn the_two_that_collide_phonetically_are_not_guessable() {
        let entries = developer();
        for term in ["Sentry", "commit"] {
            assert!(
                entries
                    .iter()
                    .filter(|e| e.written == term)
                    .all(|entry| !entry.allows_phonetic_matching),
                "{term} must not be a phonetic candidate"
            );
        }
    }

    /// The whole point, end to end: a Russian phrase with a heard-as-Cyrillic
    /// term comes back with the term written properly.
    #[test]
    fn a_dictated_term_comes_back_in_its_real_spelling() {
        let pipeline = TextPipeline::with_replacements(developer());
        let output = pipeline.process("\u{0441}\u{0434}\u{0435}\u{043B}\u{0430}\u{0439} \u{043F}\u{0443}\u{043B} \u{0440}\u{0435}\u{043A}\u{0432}\u{0435}\u{0441}\u{0442} \u{0441}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F}");
        assert!(
            output.text.contains("pull request"),
            "got {:?}",
            output.text
        );
    }

    /// And the guard that matters more: ordinary speech is left alone.
    #[test]
    fn ordinary_russian_speech_is_not_rewritten_into_terms() {
        let pipeline = TextPipeline::with_replacements(developer());
        for phrase in [
            "\u{0432} \u{0446}\u{0435}\u{043D}\u{0442}\u{0440}\u{0435} \u{0433}\u{043E}\u{0440}\u{043E}\u{0434}\u{0430} \u{043A}\u{0440}\u{0430}\u{0441}\u{0438}\u{0432}\u{043E}",
            "\u{0441}\u{0435}\u{0433}\u{043E}\u{0434}\u{043D}\u{044F} \u{0442}\u{0451}\u{043F}\u{043B}\u{044B}\u{0439} \u{0432}\u{0435}\u{0447}\u{0435}\u{0440}",
            "\u{043D}\u{0430}\u{0431}\u{043B}\u{044E}\u{0434}\u{0435}\u{043D}\u{0438}\u{0435} \u{043A}\u{043E}\u{043C}\u{0435}\u{0442}\u{044B}",
        ] {
            let output = pipeline.process(phrase);
            for term in ["Sentry", "deploy", "commit"] {
                assert!(
                    !output.text.contains(term),
                    "{phrase:?} was rewritten into {term:?}: {:?}",
                    output.text
                );
            }
        }
    }
}

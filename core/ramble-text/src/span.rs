//! Pieces of text that no stage after the dictionary may touch.
//!
//! Ported from `Packages/DictationCore/Sources/DictationCore/ProtectedSpan.swift`.
//!
//! The mechanism exists for a specific defect: the polisher puts a space after a
//! full stop that is followed by a capital, and `TextPipeline.Output` became
//! `TextPipeline. Output`. The same protection covers the nastier case — a
//! phonetic guess firing inside a path or a pair of backticks.
//!
//! Offsets are counted in characters, deliberately. The whole pipeline already
//! walks the text as a `Vec<char>`, and translating between byte and character
//! positions has produced a bug in this repository before.

/// What kind of writing is being protected.
///
/// The set is closed. Each case is not "looks like code" but a specific way of
/// writing that a person dictates and expects to see back verbatim.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpanKind {
    /// Text in backticks, the backticks included.
    Backticks,
    /// A filesystem path or a URL.
    Path,
    /// A command-line switch: `--dry-run`, `-x`, `--out=build/app`.
    Flag,
    /// A CamelCase or dotted identifier: `TextPipeline`, `AppState.shared`.
    Identifier,
}

/// One protected piece of the text it was detected in.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ProtectedSpan {
    pub kind: SpanKind,
    /// Character offsets into the text this span was computed for.
    pub start: usize,
    pub end: usize,
    /// The span's own text.
    ///
    /// Duplicates the range on purpose: the "spans did not change" check becomes
    /// a string comparison, and a failing test can be read without recomputing
    /// offsets in your head.
    pub text: String,
}

impl ProtectedSpan {
    pub fn contains(&self, offset: usize) -> bool {
        offset >= self.start && offset < self.end
    }
}

/// Find the protected spans in a text.
///
/// A pure function: the same text always yields the same spans. The whole
/// pipeline contract rests on that — every stage recomputes spans after editing
/// the text, so a stale offset cannot exist in principle.
///
/// The scan runs left to right, spans never overlap, and where two rules could
/// both fire the one that started earlier wins.
pub fn detect(text: &str) -> Vec<ProtectedSpan> {
    let characters: Vec<char> = text.chars().collect();
    let mut spans = Vec::new();
    let mut index = 0;

    while index < characters.len() {
        // Backticks come first and unconditionally: what is inside is already
        // code, and there is nothing further to look for in there.
        if characters[index] == '`' {
            if let Some(span) = backtick_span(&characters, index) {
                index = span.end;
                spans.push(span);
                continue;
            }
        }

        if !is_token_start(&characters, index) {
            index += 1;
            continue;
        }

        let end = token_end(&characters, index);

        // A backtick that opened not the token but its middle: `"`a  b`"` starts
        // with a quote. Jumping to the end of the token carried the scan clean
        // over the pair, and then the polisher collapsed the spaces inside it
        // while phonetic matching ran through bracketed code. Rewind to the
        // backtick itself; it is always ahead of `index`, so the loop still
        // makes progress.
        if let Some(offset) = characters[index..end].iter().position(|&c| c == '`') {
            let backtick = index + offset;
            if backtick > index {
                index = backtick;
                continue;
            }
        }

        if let Some(span) = span_for_token(&characters[index..end], index) {
            spans.push(span);
        }
        index = end;
    }

    spans
}

/// A pair of equally long backtick fences with non-empty content and no newline.
fn backtick_span(characters: &[char], start: usize) -> Option<ProtectedSpan> {
    let mut open_end = start;
    while open_end < characters.len() && characters[open_end] == '`' {
        open_end += 1;
    }
    let fence_length = open_end - start;

    let mut cursor = open_end;
    while cursor < characters.len() {
        if characters[cursor] == '\n' {
            return None;
        }
        if characters[cursor] != '`' {
            cursor += 1;
            continue;
        }

        let mut close_end = cursor;
        while close_end < characters.len() && characters[close_end] == '`' {
            close_end += 1;
        }
        if close_end - cursor != fence_length {
            cursor = close_end;
            continue;
        }
        if cursor <= open_end {
            return None;
        }

        return Some(ProtectedSpan {
            kind: SpanKind::Backticks,
            start,
            end: close_end,
            text: characters[start..close_end].iter().collect(),
        });
    }
    None
}

/// A token starts where whitespace ended, and only on a non-space character.
fn is_token_start(characters: &[char], index: usize) -> bool {
    if characters[index].is_whitespace() {
        return false;
    }
    index == 0 || characters[index - 1].is_whitespace()
}

fn token_end(characters: &[char], start: usize) -> usize {
    let mut end = start;
    while end < characters.len() && !characters[end].is_whitespace() {
        end += 1;
    }
    end
}

/// Classify one token. Checks run from the most specific rule to the most general.
fn span_for_token(token: &[char], start: usize) -> Option<ProtectedSpan> {
    // Punctuation on either side belongs to the sentence, not the token:
    // "open /etc/hosts.", «TextPipeline.Output», [AppState.shared].
    let mut lead = 0;
    while lead < token.len() && is_leading_punctuation(token[lead]) {
        lead += 1;
    }
    let mut tail = token.len();
    while tail > lead && is_trailing_punctuation(token[tail - 1]) {
        tail -= 1;
    }
    let body = &token[lead..tail];
    if body.is_empty() {
        return None;
    }

    let kind = if is_flag(body) {
        SpanKind::Flag
    } else if is_path(body) {
        SpanKind::Path
    } else if is_identifier(body) {
        SpanKind::Identifier
    } else {
        return None;
    };

    let lower = start + lead;
    Some(ProtectedSpan {
        kind,
        start: lower,
        end: lower + body.len(),
        text: body.iter().collect(),
    })
}

/// An opening bracket or quotation mark.
///
/// « » is the standard Russian quotation mark and the model emits it constantly.
/// Until it was stripped, one such character made a whole token invisible to the
/// detector, and every stage after the dictionary rewrote the name inside it.
///
/// Stripping does not turn speech into a span: every rule below needs either the
/// Latin alphabet or a leading slash, so a Cyrillic word in quotes stays a word.
fn is_leading_punctuation(character: char) -> bool {
    "«\"'([{\u{201C}\u{2018}".contains(character)
}

fn is_trailing_punctuation(character: char) -> bool {
    ",.!?;:\u{2026}»\"')]}\u{201D}\u{2019}".contains(character)
}

/// `--flag`, `--flag=value`, or a short `-x` of exactly one letter.
///
/// One letter is not pedantry: `-5` is a number and `-xvf` does not occur in
/// dictation, but "word-word" does, and it must not become a flag.
fn is_flag(token: &[char]) -> bool {
    if token.len() >= 3 && token[0] == '-' && token[1] == '-' {
        return token[2].is_alphabetic() && token[2].is_ascii();
    }
    if token.len() == 2 && token[0] == '-' {
        return token[1].is_alphabetic() && token[1].is_ascii();
    }
    false
}

/// A path needs a slash and one of three confirmations.
///
/// A bare `foo/bar` is not enough — in Russian speech that reads as "or", and
/// such pairs are markedly more common than two-segment paths.
fn is_path(token: &[char]) -> bool {
    if !token.contains(&'/') {
        return false;
    }

    let string: String = token.iter().collect();
    if string.contains("://") {
        return true;
    }
    if string.starts_with('/')
        || string.starts_with("./")
        || string.starts_with("../")
        || string.starts_with("~/")
    {
        return string.split('/').any(|segment| !segment.is_empty());
    }

    let segments: Vec<&str> = string.split('/').collect();
    if segments.len() < 2 || segments.iter().any(|s| s.is_empty()) {
        return false;
    }
    if !segments
        .iter()
        .all(|s| s.chars().all(is_path_segment_character))
    {
        return false;
    }

    let slashes = token.iter().filter(|&&c| c == '/').count();
    let has_rich_segment = segments
        .iter()
        .any(|s| s.contains('.') || s.contains('_') || s.contains('-'));
    slashes >= 2 || has_rich_segment
}

fn is_path_segment_character(character: char) -> bool {
    if !character.is_ascii() {
        return false;
    }
    if character.is_alphabetic() || character.is_numeric() {
        return true;
    }
    "._+@-".contains(character)
}

/// A CamelCase or dotted identifier with a capital in at least one segment.
fn is_identifier(token: &[char]) -> bool {
    if !token.iter().all(|c| c.is_ascii()) {
        return false;
    }

    if token.contains(&'.') {
        let string: String = token.iter().collect();
        let segments: Vec<&str> = string.split('.').collect();
        if segments.len() < 2 || segments.iter().any(|s| s.is_empty()) {
            return false;
        }
        if !segments.iter().all(|s| is_identifier_segment(s)) {
            return false;
        }
        // Domains and version numbers fall out here: `wai.computer` and `2.0.1`
        // have neither a capital nor CamelCase — and both are already covered by
        // the polisher's own guard.
        return segments.iter().any(|segment| {
            let chars: Vec<char> = segment.chars().collect();
            chars.first().is_some_and(|c| c.is_uppercase()) || is_camel_case(&chars)
        });
    }

    is_camel_case(token)
}

fn is_identifier_segment(segment: &str) -> bool {
    let mut chars = segment.chars();
    match chars.next() {
        Some(first) if first.is_alphabetic() || first == '_' => {}
        _ => return false,
    }
    segment
        .chars()
        .all(|c| c.is_alphabetic() || c.is_numeric() || c == '_')
}

/// Two forms of CamelCase, both real.
///
/// The first is a lower-to-upper transition: `onTextInserted`, `TextPipeline`.
/// The second is an acronym followed by a word: `URLSession`, `NSString`,
/// `HTTPServer` — which contain no lower-to-upper transition at all and would
/// stay unprotected without a rule of their own.
///
/// `API`, `JSON`, `HTTP` match neither: nothing starts after the acronym. They
/// need no protection — there is no interior to break.
///
/// Protecting a single word is not a formality: without it the capitalizer turns
/// a dictated first word `onTextInserted` into `OnTextInserted`.
fn is_camel_case(token: &[char]) -> bool {
    if !token.iter().all(|c| c.is_alphabetic() || c.is_numeric()) {
        return false;
    }

    if token
        .windows(2)
        .any(|pair| pair[0].is_lowercase() && pair[1].is_uppercase())
    {
        return true;
    }

    token
        .windows(3)
        .any(|w| w[0].is_uppercase() && w[1].is_uppercase() && w[2].is_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<(SpanKind, String)> {
        detect(text).into_iter().map(|s| (s.kind, s.text)).collect()
    }

    #[test]
    fn a_dotted_identifier_is_protected_whole() {
        assert_eq!(
            kinds("see TextPipeline.Output now"),
            vec![(SpanKind::Identifier, "TextPipeline.Output".to_string())]
        );
    }

    #[test]
    fn quotes_and_brackets_around_a_name_are_stripped_not_fatal() {
        // One guillemet used to hide the whole token from the detector, and
        // every stage after the dictionary rewrote the name inside it.
        let spans = detect("\u{00AB}TextPipeline.Output\u{00BB}");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, "TextPipeline.Output");
        assert_eq!(spans[0].start, 1);
    }

    #[test]
    fn a_cyrillic_word_in_quotes_is_still_just_a_word() {
        assert!(
            detect("\u{00AB}\u{043F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}\u{00BB}").is_empty()
        );
    }

    #[test]
    fn acronym_then_word_counts_as_camel_case_but_a_bare_acronym_does_not() {
        assert_eq!(
            kinds("URLSession"),
            vec![(SpanKind::Identifier, "URLSession".to_string())]
        );
        // Nothing inside an acronym can break, so it needs no protection.
        assert!(detect("JSON").is_empty());
        assert!(detect("API").is_empty());
    }

    #[test]
    fn a_single_camel_case_word_is_protected_so_it_is_not_capitalized() {
        assert_eq!(
            kinds("onTextInserted"),
            vec![(SpanKind::Identifier, "onTextInserted".to_string())]
        );
    }

    #[test]
    fn domains_and_versions_are_not_identifiers() {
        assert!(detect("wai.computer").is_empty());
        assert!(detect("2.0.1").is_empty());
    }

    #[test]
    fn paths_need_more_than_one_bare_slash() {
        // "foo/bar" reads as "or" in Russian speech far more often than as a path.
        assert!(detect("foo/bar").is_empty());
        assert_eq!(kinds("a/b/c"), vec![(SpanKind::Path, "a/b/c".to_string())]);
        assert_eq!(
            kinds("build/app.swift"),
            vec![(SpanKind::Path, "build/app.swift".to_string())]
        );
        assert_eq!(
            kinds("/etc/hosts"),
            vec![(SpanKind::Path, "/etc/hosts".to_string())]
        );
        assert_eq!(
            kinds("https://wai.computer/x"),
            vec![(SpanKind::Path, "https://wai.computer/x".to_string())]
        );
    }

    #[test]
    fn a_trailing_full_stop_belongs_to_the_sentence_not_the_path() {
        let spans = detect("open /etc/hosts.");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].text, "/etc/hosts");
    }

    #[test]
    fn flags_are_recognized_but_hyphenated_words_are_not() {
        assert_eq!(
            kinds("--dry-run"),
            vec![(SpanKind::Flag, "--dry-run".to_string())]
        );
        assert_eq!(kinds("-x"), vec![(SpanKind::Flag, "-x".to_string())]);
        assert!(detect("-5").is_empty());
        assert!(detect(
            "\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}-\u{0441}\u{043B}\u{043E}\u{0432}\u{043E}"
        )
        .is_empty());
    }

    #[test]
    fn backticks_protect_their_content_and_the_fence() {
        assert_eq!(
            kinds("run `git status` now"),
            vec![(SpanKind::Backticks, "`git status`".to_string())]
        );
    }

    #[test]
    fn an_unclosed_or_multiline_fence_protects_nothing() {
        assert!(detect("a `unclosed").is_empty());
        assert!(detect("a `open\nclose` b").is_empty());
        // Empty content is not code.
        assert!(detect("a `` b").is_empty());
    }

    /// A backtick opening the middle of a token used to carry the scan clean
    /// over the pair: the polisher then collapsed the spaces inside the code and
    /// phonetic matching ran through it.
    #[test]
    fn a_fence_that_starts_mid_token_is_still_found() {
        let spans = detect("\"`a  b`\"");
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].kind, SpanKind::Backticks);
        assert_eq!(spans[0].text, "`a  b`");
    }

    #[test]
    fn spans_never_overlap_and_come_out_in_order() {
        let spans = detect("`code` then /usr/local/bin and AppState.shared");
        assert_eq!(spans.len(), 3);
        for pair in spans.windows(2) {
            assert!(pair[0].end <= pair[1].start, "spans overlap: {spans:?}");
        }
    }

    #[test]
    fn detection_is_idempotent_which_is_what_lets_stages_recompute_freely() {
        let text = "see TextPipeline.Output and `git log` in /usr/local/bin";
        assert_eq!(detect(text), detect(text));
    }
}

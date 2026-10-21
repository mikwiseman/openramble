//! Cleanup that only ever deletes.
//!
//! Ported from `CleanVerbatim.swift`, which is the specification. Speech
//! carries traces typing never does: hesitations, a word said twice while the
//! next one loads, a sentence taken back out loud. This removes exactly those
//! and nothing else. It never rewords, reorders or adds a word — the difference
//! from cleanup done by a language model, which can turn "don't" into "do".
//!
//! **When in doubt, keep.** Three adversarial review rounds tried to make the
//! stage delete something real, and each attempt is a test.
//!
//! Three passes, in this order:
//!
//! 1. **Spoken corrections.** "Scratch that" takes back the sentence before it
//!    (as its own sentence or opening one) or what came before it in its
//!    sentence (at the end, or between commas). English only. Every full stop
//!    ends a sentence except a title's ("Dr. Smith", written so, before a
//!    name), so a wrong guess takes back too little, never a sentence the
//!    person meant to keep.
//! 2. **Fillers.** Hesitation words. "um", "э" and "mmm" are words too, so
//!    each goes only where it cannot be the word. "um" never goes from a take
//!    with German or Portuguese in it. In a take that reads as English it
//!    goes wherever it stands, except in "um hmm" and right after a name;
//!    after a name, and in any other take, it goes only when punctuation sets
//!    it apart on both sides. "э" and "эм", bare or before a comma, go
//!    wherever they stand unless a letter is meant: in a list of letters
//!    written with commas ("а, о, э, ы"), after a single letter and a comma,
//!    next to a letter's name ("эс", "бэ"), after "буква", or set against
//!    another letter ("пишется э, а не е"). "mmm" goes only when punctuation sets it apart
//!    on both sides, and never in a date format. Acronyms and
//!    "uh huh", "uh oh", "mm hmm" and "um hmm" are words.
//!    The comma after a hesitation goes with it; the one before stays unless
//!    it can only be the pause: after a word that cannot end a phrase
//!    ("should, um,"), in "Thanks, um, for", or after the sentence's opening
//!    subject ("The build, uh,"). A restart around a hesitation keeps one copy
//!    ("It's a, uh, a leak"). Repeated until nothing changes.
//! 3. **Stutters.** A short function word said twice in a row, from a list of
//!    words whose doubles are never grammatical ("the the", "я я", "I, I").
//! 4. **"New paragraph"** ("Новый абзац"), set apart by punctuation, becomes a
//!    paragraph break — in prose apps only. In a terminal a newline can run a
//!    command, so verbatim apps keep the words. Last, so a hesitation after the
//!    command is already gone and cannot take the break with it.
//!
//! Protected spans and every name the person's own dictionary wrote are never
//! touched. A removal capitalizes what follows only when the removed piece
//! opened a sentence itself. Text with nothing to remove comes back exactly as it went in, and a
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

/// Hesitations that are also words: each goes only where it cannot be the
/// word, as the module doc spells out.
const GUARDED_FILLERS: &[&str] = &["um", "er", "э", "эм", "mmm", "ммм"];

/// Hesitations that are words in German or Portuguese ("um", the German
/// "er"): in an English take they go wherever they stand.
const ENGLISH_HESITATIONS: &[&str] = &["um", "er"];

/// Words that leave a phrase unfinished besides the pause words: "order
/// more, um, more coffee", "Это такая, ээ, такая".
const UNFINISHED_WORDS: &[&str] = &[
    "more",
    "most",
    "some",
    "any",
    "many",
    "much",
    "every",
    "few",
    "less",
    "such",
    "этот",
    "эта",
    "эти",
    "такой",
    "такая",
    "такое",
    "такие",
    "самый",
    "самая",
    "um",
    "uma",
    "un",
    "una",
    "ein",
    "eine",
    "einen",
    "der",
    "die",
    "das",
    "le",
    "la",
    "les",
    "el",
    "los",
    "las",
];

/// Russian hesitations that are also letter names ("э", "эм"): they go bare
/// too, except next to a letter or after "буква".
const LETTER_HESITATIONS: &[&str] = &["э", "эм"];
const LETTER_WORDS: &[&str] = &["буква", "букву", "буквы", "букве", "буквой"];

/// Russian words of one letter, never a letter's name: "в", "и", "я".
const ONE_LETTER_WORDS: &[&str] = &["в", "к", "с", "у", "о", "и", "а", "я"];

/// Halves of two-word interjections: "uh huh", "uh oh", "mm hmm".
const INTERJECTION_HEADS: &[&str] = &["uh", "um", "uhm", "mm", "mmm", "hm", "hmm"];
const INTERJECTION_TAILS: &[&str] = &["huh", "oh", "hmm", "hm"];

/// "Uh uh" and "nuh uh" mean no.
const NO_HEADS: &[&str] = &["uh", "nuh"];

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

/// Words that cannot end a phrase, so a comma after one before a hesitation
/// can only be the pause: "should, um,", "что, э,".
const PAUSE_COMMA_WORDS: &[&str] = &[
    "a",
    "an",
    "the",
    "to",
    "of",
    "in",
    "on",
    "at",
    "for",
    "with",
    "from",
    "by",
    "into",
    "about",
    "and",
    "or",
    "but",
    "so",
    "because",
    "if",
    "when",
    "that",
    "than",
    "i",
    "we",
    "he",
    "she",
    "they",
    "my",
    "your",
    "our",
    "their",
    "its",
    "am",
    "is",
    "are",
    "was",
    "were",
    "be",
    "been",
    "do",
    "does",
    "did",
    "have",
    "has",
    "had",
    "will",
    "would",
    "shall",
    "should",
    "can",
    "could",
    "may",
    "might",
    "must",
    "not",
    "don't",
    "doesn't",
    "didn't",
    "can't",
    "won't",
    "wouldn't",
    "shouldn't",
    "couldn't",
    "isn't",
    "aren't",
    "wasn't",
    "weren't",
    "i'm",
    "i'll",
    "we're",
    "you're",
    "they're",
    "let's",
    "please",
    "just",
    "я",
    "мы",
    "ты",
    "вы",
    "он",
    "она",
    "оно",
    "они",
    "не",
    "ни",
    "бы",
    "в",
    "во",
    "на",
    "с",
    "со",
    "к",
    "ко",
    "у",
    "по",
    "за",
    "из",
    "от",
    "до",
    "о",
    "об",
    "при",
    "для",
    "и",
    "а",
    "но",
    "или",
    "что",
    "чтобы",
    "если",
    "когда",
    "потому",
    "как",
    "который",
    "которая",
    "которое",
    "которые",
    "можешь",
    "можете",
    "может",
    "могу",
    "буду",
    "будешь",
    "будет",
    "будем",
    "будете",
    "будут",
    "нужно",
    "нужны",
    "нужен",
    "нужна",
    "надо",
    "только",
    "должен",
    "хочу",
    "which",
    "who",
    "whom",
    "whose",
    "кроме",
    "через",
    "между",
    "без",
    "перед",
    "около",
    "вместо",
    "then",
];

/// Opening words that take an object: "Thanks for", "Спасибо за".
const THANKING_WORDS: &[&str] = &["thanks", "sorry", "спасибо", "извини"];
const THANKING_OBJECTS: &[&str] = &["for", "about", "за"];

/// Words that open a phrase the comma after it belongs to: an introductory
/// word anywhere ("Honestly, um,", "а во-вторых, э,").
const INTRO_WORDS: &[&str] = &[
    "actually",
    "honestly",
    "however",
    "unfortunately",
    "basically",
    "anyway",
    "also",
    "besides",
    "frankly",
    "кстати",
    "конечно",
    "наверное",
    "короче",
    "во-первых",
    "во-вторых",
    "в-третьих",
    "впрочем",
    "кажется",
    "честно",
    "например",
    "huh",
    "sorry",
];

/// Introductory phrases of two or three words: "в общем", "of course".
const INTRO_PHRASES: &[&str] = &[
    "в общем",
    "в итоге",
    "в целом",
    "в принципе",
    "по сути",
    "честно говоря",
    "на самом деле",
    "может быть",
    "к сожалению",
    "к счастью",
    "скорее всего",
    "кстати говоря",
    "of course",
    "for example",
    "by the way",
    "in fact",
    "to be honest",
];

/// First-person verbs that introduce a thought, so the comma after one
/// opening a sentence is grammar: "Думаю, э, это сработает".
const THINKING_VERBS: &[&str] = &[
    "думаю",
    "полагаю",
    "считаю",
    "понимаю",
    "повторяю",
    "признаю",
    "знаю",
    "слушаю",
];

/// First words of a sentence-opening phrase whose comma is grammar: a
/// greeting ("Hi team,") or a leading clause or phrase ("If the linter
/// complains,", "In the meantime,").
const GREETINGS: &[&str] = &[
    "hi",
    "hey",
    "hello",
    "dear",
    "good",
    "привет",
    "здравствуйте",
    "доброе",
    "добрый",
];
const LEADING_PHRASE_WORDS: &[&str] = &[
    "if",
    "when",
    "once",
    "after",
    "before",
    "while",
    "since",
    "until",
    "unless",
    "although",
    "because",
    "by",
    "in",
    "for",
    "on",
    "at",
    "during",
    "если",
    "когда",
    "после",
    "пока",
    "хотя",
];

/// Words after a hesitation that open a new clause, so the comma before
/// stays: "works, um, but", "функцию, э, которая".
const CLAUSE_WORDS: &[&str] = &[
    "but",
    "so",
    "yet",
    "not",
    "which",
    "who",
    "а",
    "но",
    "чтобы",
    "потому",
    "который",
    "которая",
    "которое",
    "которые",
    "чем",
    "что",
    "не",
    "если",
    "когда",
    "хотя",
    "sonst",
    "aber",
    "weil",
    "dass",
    "denn",
    "i'll",
    "i'm",
    "i've",
    "i'd",
    "it's",
    "that's",
    "there's",
    "we'll",
    "we're",
    "let's",
    "you'll",
    "they're",
    "he's",
    "she's",
];

/// "and"/"и" followed by a new subject opens a clause: "email, um, and I".
const AND_WORDS: &[&str] = &["and", "or", "и", "или"];
const SUBJECT_WORDS: &[&str] = &[
    "i", "we", "you", "he", "she", "they", "it", "the", "this", "that", "there", "my", "our",
    "your", "their", "я", "мы", "ты", "вы", "он", "она", "оно", "они", "это", "этот", "эта", "там",
    "тут",
];

/// Subject words that also open a noun phrase: a clause only with its verb
/// ("and the docs are live", not "and the tire pressure").
const NOUN_PHRASE_OPENERS: &[&str] = &["the", "this", "that", "my", "our", "your", "their"];
const CLAUSE_VERBS: &[&str] = &[
    "is", "are", "was", "were", "has", "have", "had", "will", "would", "can", "could", "should",
    "isn't", "aren't", "wasn't", "weren't", "won't", "can't", "don't", "doesn't", "didn't",
];

/// Words said twice for weight, even across a hesitation: "very, um, very".
const WEIGHT_WORDS: &[&str] = &[
    "very",
    "really",
    "yes",
    "yeah",
    "no",
    "okay",
    "ok",
    "bye",
    "да",
    "нет",
    "очень",
    "ага",
    "ладно",
];

/// Object pronouns never start a list: "у нас, э, демо".
const OBJECT_PRONOUNS: &[&str] = &[
    "me", "us", "him", "them", "нас", "вас", "нам", "вам", "мне", "тебе", "ему", "ей", "им",
];

/// Verbs that follow a sentence's subject: "Sentry, uh, is down" is no
/// vocative.
const SUBJECT_VERBS: &[&str] = &[
    "is", "was", "has", "isn't", "wasn't", "hasn't", "keeps", "seems", "looks",
];
const SUBJECT_DETERMINERS: &[&str] = &[
    "the", "a", "an", "my", "your", "his", "her", "our", "their", "its", "this", "that", "these",
    "those", "мой", "моя", "моё", "мои", "наш", "наша", "наше", "наши", "твой", "твоя", "ваш",
    "ваша", "этот", "эта", "эти",
];

/// Date-format tokens: "dd, mmm, yyyy" is not a hesitation.
const DATE_TOKENS: &[&str] = &["d", "dd", "m", "mm", "y", "yy", "yyyy", "hh", "ss"];

/// Words after which "scratch that" is quoted, not said: "If I say, scratch that".
const SPEECH_VERBS: &[&str] = &[
    "say", "says", "said", "saying", "type", "types", "typed", "typing",
];

/// Hesitations that also end a sentence or a take: "…for you, um."
const ENDING_HESITATIONS: &[&str] = &["um", "er", "э", "эм", "ммм"];

/// Short function words whose doubles are never grammatical. "i" counts only
/// as the capital pronoun.
const STUTTER_WORDS: &[&str] = &[
    "i", "the", "we", "he", "she", "they", "our", "your", "but", "of", "with", "я", "мы", "ты",
    "вы", "он", "она", "оно", "они", "и", "но", "в", "на", "с", "к", "у", "по", "за", "из", "от",
    "до",
];

/// Doubles that are stutters only when the second copy runs on into the
/// sentence ("это это известный", not "Это это?"), and the first three only in
/// English ("Il y a a priori", Polish "to to" are grammar).
const RUN_ON_STUTTER_WORDS: &[&str] = &["to", "a", "an", "this", "этот", "эта", "эти", "это"];
const ENGLISH_STUTTER_WORDS: &[&str] = &["to", "a", "an"];

/// Russian letter names: "эс эм эс" is spelled, not hesitated.
const LETTER_NAMES: &[&str] = &[
    "эс", "эн", "эр", "эль", "эл", "эф", "ка", "тэ", "пэ", "бэ", "вэ", "гэ", "дэ", "зэ", "цэ",
    "ха", "ша",
];

/// Doubles with a comma between them that are still stutters: "the, the".
const COMMA_STUTTER_WORDS: &[&str] = &[
    "the", "our", "your", "every", "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
];

/// Pronouns that stutter with a comma when they open a sentence: "I, I think".
const OPENING_COMMA_STUTTER_WORDS: &[&str] = &["i", "we", "я", "мы"];

/// Spoken corrections, as consecutive words.
const CORRECTIONS: &[&[&str]] = &[&["scratch", "that"]];

/// Words people lead a correction with: "Sorry, scratch that". "no" counts
/// too, except right after a question, where it is the answer being corrected.
const CORRECTION_LEAD_INS: &[&str] = &[
    "ah", "oh", "okay", "ok", "so", "well", "sorry", "no", "actually", "wait", "oops",
];

/// Spoken paragraph breaks, as consecutive words.
const PARAGRAPH_COMMANDS: &[&[&str]] = &[&["new", "paragraph"], &["новый", "абзац"]];

/// Titles whose full stop does not end a sentence, written exactly so: "MR."
/// is a merge request and "ms." milliseconds.
const TITLES: &[&str] = &["Dr", "Mr", "Mrs", "Ms", "Prof"];

/// Words before a title that make it a noun ending its sentence: "the Mrs."
const DETERMINERS: &[&str] = &["the", "a", "an", "my", "your", "his", "her", "our", "their"];

/// Capitalized words after a title that are no name: "Dr. The house".
const NOT_NAMES: &[&str] = &[
    "the", "a", "an", "this", "that", "these", "those", "it", "he", "she", "we", "they", "i",
    "you", "his", "her", "its", "our", "their", "my", "your", "there", "here", "then",
];

const TRAILING_PUNCTUATION: &[char] = &[',', '.', ';', ':', '!', '?', '…'];
const SENTENCE_ENDING: &[char] = &['.', '!', '?', '…'];
const CLOSERS: &[char] = &['"', '\'', '”', '’', '»', ')', ']'];

/// A Russian past-tense verb: "сделал", "упала", "ушли".
fn is_russian_past_tense(word: &str) -> bool {
    word.chars().count() >= 3
        && word.chars().all(|c| ('а'..='я').contains(&c) || c == 'ё')
        && ["л", "ла", "ло", "ли"]
            .iter()
            .any(|ending| word.ends_with(ending))
}

/// A Russian infinitive: "купить", "найти" — a verb, no vocative.
fn is_russian_infinitive(word: &str) -> bool {
    word.chars().count() >= 4
        && word.chars().all(|c| ('а'..='я').contains(&c) || c == 'ё')
        && ["ть", "ти", "чь"]
            .iter()
            .any(|ending| word.ends_with(ending))
}

/// The words of `tokens`, joined by single spaces.
fn joined(tokens: &[Token]) -> String {
    tokens.iter().map(Token::word).collect::<Vec<_>>().join(" ")
}

/// Line breaks as Swift's `Character.isNewline` sees them.
fn has_line_break(text: &str) -> bool {
    text.contains([
        '\n', '\r', '\u{0B}', '\u{0C}', '\u{85}', '\u{2028}', '\u{2029}',
    ])
}

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
    let mut unstuttered = false;
    // Fillers and stutters until neither changes: removing one can expose the
    // other ("The The um,"). Each pass removes at least one token, so the token
    // count bounds it.
    for _ in 0..=tokens.items.len() {
        let filled = tokens.remove_fillers();
        let stuttered = tokens.collapse_comma_restarts() | tokens.collapse_stutters();
        unfilled |= filled;
        unstuttered |= stuttered;
        if !(filled || stuttered) {
            break;
        }
    }
    // A take of nothing but hesitation is nothing: "Uh, um."
    let um_is_a_word = tokens.um_is_a_word();
    let reads_as_english = tokens.reads_as_english();
    if spoken_corrections
        && !tokens.items.is_empty()
        && (0..tokens.items.len())
            .all(|index| tokens.is_filler(index, um_is_a_word, reads_as_english))
    {
        tokens.items.clear();
        unfilled = true;
    }
    let broken = mode == PromptMode::Prose && tokens.apply_paragraph_commands();
    if !(corrected || unfilled || unstuttered || broken) {
        return text.to_string();
    }
    if !spoken_corrections && tokens.items.is_empty() {
        return text.to_string();
    }
    tokens.rendered()
}

/// Every word a dictionary entry writes with a capital, lowercased: a name
/// ("The The", "Hmm Labs") is never a filler or a stutter. Lowercase
/// connecting words ("commit в") are not names.
/// A function word counts only when the name doubles it ("The The"), so "The
/// Verge" does not stop "the the" from collapsing everywhere else.
pub fn protected_words<'a>(written: impl IntoIterator<Item = &'a str>) -> HashSet<String> {
    written
        .into_iter()
        .flat_map(|phrase| {
            let words: Vec<&str> = phrase.split_whitespace().collect();
            let lower: Vec<String> = words.iter().map(|word| word.to_lowercase()).collect();
            (0..words.len())
                .filter(|&offset| words[offset].chars().any(char::is_uppercase))
                .filter(|&offset| {
                    let doubled = (offset > 0 && lower[offset - 1] == lower[offset])
                        || (offset + 1 < words.len() && lower[offset + 1] == lower[offset]);
                    !STUTTER_WORDS.contains(&lower[offset].as_str()) || doubled
                })
                .map(|offset| lower[offset].clone())
                .collect::<Vec<_>>()
        })
        .collect()
}

/// Whether every word of `text` is a hesitation, counting the ones that are
/// also words ("Um.", "Э."), which cleanup keeps when they stand alone.
pub fn is_only_hesitation(text: &str) -> bool {
    let protected = HashSet::new();
    let tokens = Tokens::new(text, &protected);
    !tokens.items.is_empty()
        && (0..tokens.items.len()).all(|index| tokens.is_any_filler_word(index))
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

    /// The text without closing quotes and brackets.
    fn unquoted(&self) -> &str {
        self.text.trim_end_matches(|c: char| CLOSERS.contains(&c))
    }

    /// A full stop, question mark, exclamation or ellipsis closes this token,
    /// possibly inside a closing quote or bracket.
    fn ends_with_sentence_punctuation(&self) -> bool {
        self.unquoted()
            .chars()
            .last()
            .is_some_and(|c| SENTENCE_ENDING.contains(&c))
    }

    /// A title with the comma a hesitation left after it: "Mr.,".
    fn is_title_before_comma(&self) -> bool {
        self.text
            .strip_suffix(',')
            .and_then(|text| text.strip_suffix('.'))
            .is_some_and(|stem| TITLES.contains(&stem))
    }

    /// A title as written, full stop and all: "Dr.", "Mrs."
    fn is_title(&self) -> bool {
        self.unquoted()
            .strip_suffix('.')
            .is_some_and(|stem| TITLES.contains(&stem))
    }

    fn starts_uppercase(&self) -> bool {
        self.text.chars().next().is_some_and(char::is_uppercase)
    }

    /// Starts with a lowercase letter: what a removal before it did not open
    /// as a sentence ("e.g. uh, empty").
    fn starts_lowercase(&self) -> bool {
        self.text.chars().next().is_some_and(char::is_lowercase)
    }

    /// Asks a question, possibly inside a closing quote: "ready?", "ready?!"
    fn ends_with_question(&self) -> bool {
        let unquoted = self.unquoted();
        let stem = unquoted.trim_end_matches(|c: char| TRAILING_PUNCTUATION.contains(&c));
        unquoted[stem.len()..].contains('?')
    }

    /// One letter, perhaps with accents: "а", "у́", "э".
    fn is_single_letter(&self) -> bool {
        let word = self.word();
        word.chars().filter(|c| c.is_alphabetic()).count() == 1
            && word
                .chars()
                .all(|c| c.is_alphabetic() || ('\u{300}'..='\u{36F}').contains(&c))
    }

    /// "I" and its contractions: "I'm", "I'll".
    fn is_first_person(&self) -> bool {
        let word = self.word();
        word == "i" || word.starts_with("i'") || word.starts_with("i’")
    }

    /// Closes with a question mark or an exclamation, possibly quoted.
    fn ends_asking(&self) -> bool {
        self.unquoted()
            .chars()
            .last()
            .is_some_and(|c| c == '?' || c == '!')
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
                && !has_line_break(&token.separator)
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
        let next_has_break = has_line_break(&self.items[start].separator);
        if start == 0 || (has_line_break(&leading) && !next_has_break) {
            self.items[start].separator = leading;
        }
    }

    fn is_kept(&self, token: &Token) -> bool {
        token.protected || token.is_shouting() || self.protected_words.contains(&token.word())
    }

    /// Whether the token at `index` closes a sentence. A title's full stop is
    /// the one exception: written exactly so, before a capitalized name, and
    /// not after "the" ("I asked the Mrs. She said…" ends one). A word like
    /// "The" or "She" after it is no name ("5 Main Dr. The house").
    fn ends_sentence(&self, index: usize) -> bool {
        let token = &self.items[index];
        if !token.ends_with_sentence_punctuation() {
            return false;
        }
        if !token.is_title() || index + 1 >= self.items.len() {
            return true;
        }
        let next = &self.items[index + 1];
        if !next.starts_uppercase()
            || NOT_NAMES.contains(&next.word().as_str())
            || self.is_any_filler_word(index + 1)
            || next.word() == "scratch"
        {
            return true;
        }
        // "the Mrs.", "the new Prof." are nouns; look back inside the sentence
        // only. "her to Dr." is no noun phrase.
        if index > 0 && DETERMINERS.contains(&self.items[index - 1].word().as_str()) {
            return true;
        }
        index > 1
            && self.items[index - 1].punctuation().is_empty()
            && !PAUSE_COMMA_WORDS.contains(&self.items[index - 1].word().as_str())
            && DETERMINERS.contains(&self.items[index - 2].word().as_str())
    }

    fn opens_sentence(&self, index: usize) -> bool {
        index == 0 || self.ends_sentence(index - 1)
    }

    /// A capitalized word just before, in the middle of a sentence: a German
    /// noun with its separable verb ("Stell die Config um"), or a name.
    fn follows_a_name(&self, index: usize) -> bool {
        index > 0
            && !self.opens_sentence(index)
            && self.items[index - 1].starts_uppercase()
            && !self.items[index - 1].is_first_person()
            && !self.opens_sentence(index - 1)
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
        // "Uh uh", "nuh uh": no.
        if word == "uh"
            && index > 0
            && self.items[index - 1].punctuation().is_empty()
            && NO_HEADS.contains(&self.items[index - 1].word().as_str())
        {
            return false;
        }
        if NO_HEADS.contains(&word.as_str())
            && token.punctuation().is_empty()
            && self.word_at(Some(index + 1)).as_deref() == Some("uh")
        {
            return false;
        }
        if FILLERS.contains(&word.as_str()) {
            return true;
        }
        if !GUARDED_FILLERS.contains(&word.as_str()) {
            return false;
        }
        if ENGLISH_HESITATIONS.contains(&word.as_str()) && um_is_a_word {
            return false;
        }
        // In an English take "um" and "er" are only hesitation.
        if ENGLISH_HESITATIONS.contains(&word.as_str())
            && reads_as_english
            && !self.follows_a_name(index)
        {
            return true;
        }
        // "э", "эм" are letters only next to a letter or after "буква".
        let listed_letter = |token: &Token| token.is_single_letter() && token.punctuation() == ",";
        let letter_name = |token: &Token| LETTER_NAMES.contains(&token.word().as_str());
        let letter_context = index > 0
            && (listed_letter(&self.items[index - 1])
                || letter_name(&self.items[index - 1])
                || LETTER_WORDS.contains(&self.items[index - 1].word().as_str()))
            || self.items.get(index + 1).is_some_and(letter_name)
            || (token.punctuation() == ","
                && self
                    .items
                    .get(index + 1)
                    .is_some_and(|next| next.is_single_letter() && !next.punctuation().is_empty()))
            // Set against another letter: "пишется э, а не е", "через э, а не через е".
            || (token.punctuation() == ","
                && self.word_at(Some(index + 1)).as_deref() == Some("а")
                && self.word_at(Some(index + 2)).as_deref() == Some("не")
                && self.items.iter().skip(index + 3).take(2).any(|other| {
                    other.is_single_letter() && !ONE_LETTER_WORDS.contains(&other.word().as_str())
                }));
        if LETTER_HESITATIONS.contains(&word.as_str())
            && (token.punctuation().is_empty() || token.punctuation() == ",")
            && !letter_context
        {
            return true;
        }
        // A letter among different letters: "а, о, у, э, ы". The same word on
        // both sides is a restart: "Я, э, я думаю".
        if LETTER_HESITATIONS.contains(&word.as_str())
            && index > 0
            && self.items.get(index + 1).is_some_and(|next| {
                next.is_single_letter() && next.word() != self.items[index - 1].word()
            })
            && self.items[index - 1].is_single_letter()
        {
            return false;
        }
        // A date format: "dd, mmm, yyyy".
        if word == "mmm"
            && [index.checked_sub(1), Some(index + 1)]
                .into_iter()
                .any(|neighbour| {
                    self.word_at(neighbour)
                        .is_some_and(|word| DATE_TOKENS.contains(&word.as_str()))
                })
        {
            return false;
        }
        // Hesitations in a row are one pause: "um uh, now", "um um, we".
        let carries_comma = token.ends_with_comma()
            || {
                let mut next = index + 1;
                while next < self.items.len()
                    && self.items[next].punctuation().is_empty()
                    && self.is_any_filler_word(next)
                {
                    next += 1;
                }
                next > index + 1
                    && next < self.items.len()
                    && self.is_any_filler_word(next)
                    && self.items[next].ends_with_comma()
            }
            || (token.punctuation().is_empty()
                && self.items.get(index + 1).is_some_and(|next| {
                    self.is_any_filler_word(index + 1) && next.ends_with_comma()
                }));
        let apart_before = self.opens_sentence(index)
            || self.items[index - 1].ends_with_comma()
            || (word == "um" && reads_as_english && !self.follows_a_name(index));
        if carries_comma && apart_before {
            return true;
        }
        // A sentence of its own in English: "That's the plan. Um. Let's see."
        if word == "um"
            && reads_as_english
            && self.opens_sentence(index)
            && self.ends_sentence(index)
        {
            return true;
        }
        if !ENDING_HESITATIONS.contains(&word.as_str())
            || (LETTER_HESITATIONS.contains(&word.as_str()) && letter_context)
        {
            return false;
        }
        // One a sentence end sets apart after a comma: "…for you, um."
        let punctuation = token.punctuation();
        if !punctuation.is_empty()
            && !punctuation.contains(',')
            && index > 0
            && self.items[index - 1].ends_with_comma()
        {
            return true;
        }
        // One the end of the text sets apart, where a trailing command took its
        // comma: "…the end um" from "…the end um, new line."
        punctuation.is_empty() && index == self.items.len() - 1 && apart_before
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

    /// Whether the comma before the hesitation at `index` is grammar, so it
    /// stays. A hesitation's commas are its pause and go with it, unless the
    /// one before closes something a careful writer would close with a comma:
    /// an opening word or clause, an introductory word, a clause that follows,
    /// a name, a list.
    fn comma_before_is_grammar(&self, index: usize) -> bool {
        let previous = &self.items[index - 1];
        let previous_word = previous.word();
        // Russian sets every introductory word off, the comma before it
        // included: "Мы, эм, честно говоря, не ожидали".
        if self
            .russian_intro_at(index + 1)
            .is_some_and(|end| self.items[end].ends_with_comma())
        {
            return true;
        }
        if PAUSE_COMMA_WORDS.contains(&previous_word.as_str()) {
            return false;
        }
        let Some(next) = self.items.get(index + 1) else {
            return false;
        };
        let next_word = next.word();
        // "Thanks, um, for" is one phrase; a title keeps its name ("Mr. Henderson").
        if (THANKING_WORDS.contains(&previous_word.as_str())
            && THANKING_OBJECTS.contains(&next_word.as_str()))
            || previous.is_title_before_comma()
        {
            return false;
        }
        // English writes a comma after "e.g." and "i.e."; after any other
        // abbreviation's full stop the comma is the pause: "т. е., э, не".
        if ["e.g", "i.e"].contains(&previous_word.as_str()) {
            return true;
        }
        if previous.text.ends_with(".,") {
            return false;
        }
        // Russian "и"/"или" joining a last item takes no comma: "фронтендер и тестировщик".
        if ["и", "или"].contains(&next_word.as_str())
            && !self
                .word_at(Some(index + 2))
                .is_some_and(|word| SUBJECT_WORDS.contains(&word.as_str()))
        {
            return false;
        }
        // The same word on both sides keeps its comma rather than glue "it
        // it". An appositive restates the noun: "the old flag, er, the one".
        if next_word == previous_word
            || INTRO_WORDS.contains(&previous_word.as_str())
            || self.intro_phrase_ending(index - 1)
            || CLAUSE_WORDS.contains(&next_word.as_str())
            || (next_word == "the"
                && self
                    .word_at(Some(index + 2))
                    .is_some_and(|word| word == "one" || word == "ones"))
        {
            return true;
        }
        // "не знаю, ээ, может быть завтра".
        if self.russian_intro_at(index + 1).is_some() || self.closes_a_relative_clause(index) {
            return true;
        }
        // "and I", "и они", "and Sam is": a new clause. The last item of a
        // list of three keeps its comma too: "the flights, uh, and the car".
        if AND_WORDS.contains(&next_word.as_str())
            && (self.and_opens_a_clause(index + 1) || self.after_a_list_comma(index))
        {
            return true;
        }
        // A name that closes the phrase: "Thanks again, um, Jordan,", or
        // opens a clause: "the vendor call, uh, Hannah is out". German
        // capitalizes every noun, so not there ("Es geht um, äh, Geld.").
        if next.starts_uppercase()
            && !next.is_first_person()
            && (!next.punctuation().is_empty() || self.verb_follows(index + 2))
            && !self.um_is_a_word()
        {
            return true;
        }
        // A list: "eggs, milk, uh, butter", "10, um, 30", "chips, um, soda,".
        // An opening word before is no list item ("Okay, this, uh,"), unless
        // a greeting names someone ("Привет, ребята, э,").
        if index >= 2
            && self.items[index - 2].ends_with_comma()
            && (!self.opens_sentence(index - 2)
                || GREETINGS.contains(&self.items[index - 2].word().as_str()))
        {
            return true;
        }
        // A name set off by commas: "Thanks, John, um, see you". Not a
        // subject before its verb: "Ну, Sentry, э, упал".
        if index >= 2
            && previous.starts_uppercase()
            && !previous.is_first_person()
            && !self.opens_sentence(index - 1)
            && self.items[index - 2].ends_with_comma()
            && !self.verb_follows(index + 1)
            && !self.um_is_a_word()
        {
            return true;
        }
        // Items that repeat their first word: "от Лены, от Тимура, э, от Вадима".
        if index >= 4
            && self.items[index - 2].punctuation().is_empty()
            && self.items[index - 2].word() == next_word
            && self.items[index - 3].ends_with_comma()
            && self.items[index - 4].word() == next_word
        {
            return true;
        }
        if previous.text.chars().any(|c| c.is_ascii_digit())
            && next.text.chars().any(|c| c.is_ascii_digit())
        {
            return true;
        }
        // A subject before its verb is no list item: "Марина, ээ, сказала".
        // A greeting keeps its comma: "Привет, ээ, хотел".
        if self.opens_sentence(index - 1)
            && !GREETINGS.contains(&previous_word.as_str())
            && self.verb_follows(index + 1)
        {
            return false;
        }
        if self.continues_a_list(index) {
            return true;
        }
        self.opening_comma(index)
    }

    /// A clause starts right after the hesitation: "but", "I'll", "and I".
    fn opens_a_clause(&self, index: usize) -> bool {
        let next = self.word_at(Some(index + 1)).unwrap_or_default();
        CLAUSE_WORDS.contains(&next.as_str())
            || (AND_WORDS.contains(&next.as_str()) && self.and_opens_a_clause(index + 1))
    }

    /// The "and" at `index` opens a clause: a new subject ("and I", "и
    /// они", "and Sam is"), or a noun phrase with its verb ("and the docs
    /// are live", not "and the tire pressure").
    fn and_opens_a_clause(&self, index: usize) -> bool {
        let Some(subject) = self.items.get(index + 1) else {
            return false;
        };
        let word = subject.word();
        if !SUBJECT_WORDS.contains(&word.as_str()) {
            return subject.starts_uppercase()
                && !subject.is_first_person()
                && self.verb_follows(index + 2);
        }
        if !NOUN_PHRASE_OPENERS.contains(&word.as_str()) {
            return true;
        }
        let mut at = index + 1;
        while at < self.items.len() && at <= index + 4 && self.items[at].punctuation().is_empty() {
            at += 1;
            if self
                .word_at(Some(at))
                .is_some_and(|word| CLAUSE_VERBS.contains(&word.as_str()))
            {
                return true;
            }
        }
        false
    }

    /// The comma before the hesitation at `index` closes a short list item
    /// another comma opened: "the hotel, the flights, uh, and the car".
    fn after_a_list_comma(&self, index: usize) -> bool {
        let mut at = index - 1;
        while at > 0 && !self.ends_sentence(at - 1) {
            at -= 1;
            if self.items[at].ends_with_comma() {
                return !self.opens_sentence(at) && index - 1 - at <= 3;
            }
        }
        false
    }

    /// An introductory phrase of two or three words ends at `end`: "в
    /// общем", "of course".
    fn intro_phrase_ending(&self, end: usize) -> bool {
        (2..=3).any(|length| {
            end + 1 >= length && {
                let words = &self.items[end + 1 - length..=end];
                words[..length - 1]
                    .iter()
                    .all(|token| token.punctuation().is_empty())
                    && INTRO_PHRASES.contains(&joined(words).as_str())
            }
        })
    }

    /// Where a Russian introductory word or phrase starting at `start`
    /// ends: "кстати", "честно говоря".
    fn russian_intro_at(&self, start: usize) -> Option<usize> {
        let first = self.word_at(Some(start))?;
        if !first.chars().any(|c| ('а'..='я').contains(&c)) {
            return None;
        }
        (2..=3)
            .rev()
            .find(|&length| {
                start + length <= self.items.len() && {
                    let words = &self.items[start..start + length];
                    words[..length - 1]
                        .iter()
                        .all(|token| token.punctuation().is_empty())
                        && INTRO_PHRASES.contains(&joined(words).as_str())
                }
            })
            .map(|length| start + length - 1)
            .or_else(|| INTRO_WORDS.contains(&first.as_str()).then_some(start))
    }

    /// The comma before the hesitation at `index` closes a relative clause
    /// the sentence opened with a comma: "Переводчик, которого нам
    /// посоветовали в Ташкенте, ээ, берёт".
    fn closes_a_relative_clause(&self, index: usize) -> bool {
        let mut at = index - 1;
        while at > 0 && !self.ends_sentence(at - 1) {
            at -= 1;
            if self.items[at].ends_with_comma() {
                let opener = self.items[at + 1].word();
                return index - 1 - at >= 3
                    && (opener.starts_with("котор")
                        || ["which", "who"].contains(&opener.as_str()));
            }
        }
        false
    }

    /// The word at `index` is a verb that follows its subject: "is",
    /// "сделал".
    fn verb_follows(&self, index: usize) -> bool {
        self.word_at(Some(index)).is_some_and(|word| {
            SUBJECT_VERBS.contains(&word.as_str()) || is_russian_past_tense(&word)
        })
    }

    /// One or two words after the hesitation, three after "a" or "the",
    /// then a comma or "and": the next item of a list, written the same way
    /// as the one before it (both bare, or both after "the").
    fn continues_a_list(&self, index: usize) -> bool {
        let determined = |token: &Token| SUBJECT_DETERMINERS.contains(&token.word().as_str());
        let item_end = (1..=3).find(|&length| {
            let last = index + length;
            last < self.items.len()
                && (length < 3 || determined(&self.items[index + 1]))
                && self.items[index + 1..last]
                    .iter()
                    .all(|token| token.punctuation().is_empty())
                && (self.items[last].ends_with_comma()
                    || self
                        .word_at(Some(last + 1))
                        .is_some_and(|word| AND_WORDS.contains(&word.as_str())))
        });
        if item_end.is_none()
            || OBJECT_PRONOUNS.contains(&self.items[index - 1].word().as_str())
            || is_russian_infinitive(&self.items[index - 1].word())
        {
            return false;
        }
        let previous_determined = index >= 2
            && self.items[index - 2].punctuation().is_empty()
            && determined(&self.items[index - 2]);
        previous_determined == determined(&self.items[index + 1])
    }

    /// The comma closes the opening of the sentence: a single word ("Okay,",
    /// "Sarah,", "Кстати,"), a greeting ("Hi team,"), or a leading clause or
    /// phrase ("If the linter complains,", "In the meantime,").
    fn opening_comma(&self, index: usize) -> bool {
        let end = index - 1;
        let mut start = end;
        while start > 0 && !self.ends_sentence(start - 1) {
            start -= 1;
        }
        let bare = |from: usize| {
            !self.items[from..end]
                .iter()
                .any(|token| !token.punctuation().is_empty())
        };
        // A leading phrase after an opening word: "Claude, before you change
        // anything, uh,".
        if start < end && self.items[start].ends_with_comma() && bare(start + 1) {
            return start + 1 < end
                && LEADING_PHRASE_WORDS.contains(&self.items[start + 1].word().as_str());
        }
        if !bare(start) {
            return false;
        }
        let first = self.items[start].word();
        if start == end {
            // A subject before its verb is no vocative: "Sentry, uh, is down",
            // "Дима, э, сделал". A greeting always is: "Привет, хотел". A
            // first-person verb takes its object: "Высылаю, э, акт", unless
            // it introduces a thought: "Думаю, э, это".
            let acts = first.ends_with('ю')
                && first.chars().count() >= 4
                && first.chars().all(|c| ('а'..='я').contains(&c) || c == 'ё')
                && !THINKING_VERBS.contains(&first.as_str());
            return GREETINGS.contains(&first.as_str())
                || !is_russian_infinitive(&first) && !acts && !self.verb_follows(index + 1);
        }
        (GREETINGS.contains(&first.as_str()) && end - start < 4)
            || LEADING_PHRASE_WORDS.contains(&first.as_str())
    }

    /// How many words before the hesitation at `index` are said again right
    /// after it — a restart: "It's a, uh, a leak", "Can you, um, can you".
    fn restart_length(&self, index: usize) -> Option<usize> {
        if index == 0 || self.ends_sentence(index) {
            return None;
        }
        self.repeated_length(index - 1, index + 1, true)
            .or_else(|| self.revised_length(index))
    }

    /// How many words before the hesitation at `index` start a phrase that
    /// stops on a word that cannot end it and is begun again with another
    /// ending: "with the, um, with Kowalski's", "It's a, uh, it's an".
    fn revised_length(&self, index: usize) -> Option<usize> {
        (2..=3).rev().find(|&length| {
            if index < length || index + length >= self.items.len() {
                return false;
            }
            let before = &self.items[index - length..index];
            let again = &self.items[index + 1..index + length];
            let last = &before[length - 1];
            let last_word = last.word();
            (PAUSE_COMMA_WORDS.contains(&last_word.as_str())
                || UNFINISHED_WORDS.contains(&last_word.as_str()))
                && !last.starts_uppercase()
                && (last.punctuation().is_empty() || last.punctuation() == ",")
                && before[..length - 1]
                    .iter()
                    .all(|token| token.punctuation().is_empty())
                && !before.iter().any(|token| self.is_kept(token))
                && !again.iter().any(|token| self.is_kept(token))
                && again.iter().zip(before.iter()).all(|(second, first)| {
                    second.punctuation().is_empty() && second.word() == first.word()
                })
        })
    }

    /// How many words ending at `before_end` are said again starting at
    /// `after_start`: a restart when the first copy opens the sentence or
    /// stops on a word that cannot end a phrase ("It's a, a leak", "Can you,
    /// can you"), never a clause boundary ("Try it, it works"). Across a
    /// hesitation any other phrase is a restart too when the second copy runs
    /// on, unless it is said for weight or could open the next clause ("the
    /// ERP, uh, the ERP migration", "отправил, ммм, отправил договор").
    fn repeated_length(
        &self,
        before_end: usize,
        after_start: usize,
        across_hesitation: bool,
    ) -> Option<usize> {
        (1..=3).rev().find(|&length| {
            if before_end + 1 < length || after_start + length > self.items.len() {
                return false;
            }
            let before_start = before_end + 1 - length;
            let before = &self.items[before_start..=before_end];
            let after = &self.items[after_start..after_start + length];
            let last = &before[length - 1];
            let last_word = last.word();
            // Capitalized inside a sentence it is a name: "Ask Uma, uh, Uma knows".
            let named = last.starts_uppercase()
                && !last.is_first_person()
                && !self.opens_sentence(before_end);
            let unfinished = !named
                && (PAUSE_COMMA_WORDS.contains(&last_word.as_str())
                    || UNFINISHED_WORDS.contains(&last_word.as_str()));
            let first_word = before[0].word();
            // A verb right after the second copy makes it a new subject:
            // "milk, uh, milk is", "бюджет, э, бюджет утвердили".
            let verb_at = |at: usize| {
                self.word_at(Some(at)).is_some_and(|word| {
                    CLAUSE_VERBS.contains(&word.as_str())
                        || SUBJECT_VERBS.contains(&word.as_str())
                        || is_russian_past_tense(&word)
                })
            };
            let next = after_start + length;
            let subject = verb_at(next)
                || (self.items[next..]
                    .first()
                    .is_some_and(|token| token.punctuation().is_empty())
                    && verb_at(next + 1));
            let restarts = across_hesitation
                && after[length - 1].punctuation().is_empty()
                && next < self.items.len()
                && !subject
                && !before[0].starts_uppercase()
                && !SUBJECT_WORDS.contains(&first_word.as_str())
                && !OBJECT_PRONOUNS.contains(&first_word.as_str())
                && !WEIGHT_WORDS.contains(&last_word.as_str())
                && (length > 1
                    || !before
                        .iter()
                        .any(|token| token.text.chars().any(|c| c.is_ascii_digit())));
            if !(self.opens_sentence(before_start) || unfinished || restarts) {
                return false;
            }
            let last_before = before[length - 1].punctuation();
            !before.iter().any(|token| self.is_kept(token))
                && !after.iter().any(|token| self.is_kept(token))
                && before[..length - 1]
                    .iter()
                    .all(|token| token.punctuation().is_empty())
                && (last_before.is_empty() || last_before == ",")
                && after[..length - 1]
                    .iter()
                    .all(|token| token.punctuation().is_empty())
                && before.iter().zip(after.iter()).all(|(first, second)| {
                    let (first, second) = (first.word(), second.word());
                    // "a, um, an": the article said again for the next sound.
                    first == second
                        || (["a", "an"].contains(&first.as_str())
                            && ["a", "an"].contains(&second.as_str()))
                })
        })
    }

    // Pass 1: corrections

    fn sentences(&self) -> Vec<(usize, usize)> {
        let mut result = Vec::new();
        let mut start = 0;
        for index in 0..self.items.len() {
            if self.ends_sentence(index) || index == self.items.len() - 1 {
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
            let opener = !self.items[start].starts_lowercase();
            self.remove(start, end);
            changed = true;
            // What is left opens the sentence when the removed piece did
            // ("vs. coffee, scratch that, water" did not).
            if opener && start < self.items.len() && !self.items[start].protected {
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
                    // A question is not a command: "Scratch that? Or fix it?"
                    if self.items[last].ends_with_question() {
                        continue;
                    }
                    // Quoted after a speech verb: "If I say, scratch that, …"
                    let said = (start..first)
                        .rev()
                        .find(|&index| !self.is_any_filler_word(index));
                    if said.is_some_and(|index| {
                        SPEECH_VERBS.contains(&self.items[index].word().as_str())
                    }) {
                        continue;
                    }
                    let after_question =
                        self.previous_sentence(position, &sentences)
                            .is_some_and(|previous| {
                                self.items[sentences[previous].1].ends_with_question()
                            });
                    let opens = spoken[..offset].iter().all(|word| {
                        CORRECTION_LEAD_INS.contains(&word.as_str())
                            && !(word == "no" && after_question)
                    });
                    let closes = offset + command.len() == spoken.len();
                    let pause_before = first > start && self.comma_before(first, start);
                    let pause_after = self.comma_after(last, end);

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

    /// Where the sentence a correction takes back begins. Sentences of nothing
    /// but hesitation are passed over and go with it.
    fn previous_start(&self, position: usize, sentences: &[(usize, usize)]) -> usize {
        sentences[self.previous_sentence(position, sentences).unwrap_or(0)].0
    }

    /// The sentence before `position` that is more than hesitation.
    fn previous_sentence(&self, position: usize, sentences: &[(usize, usize)]) -> Option<usize> {
        (0..position).rev().find(|&candidate| {
            let (start, end) = sentences[candidate];
            !(start..=end).all(|index| self.is_any_filler_word(index))
        })
    }

    /// A comma closes the word before `index`, perhaps behind bare
    /// hesitations: "Friday, uh scratch that".
    fn comma_before(&self, index: usize, start: usize) -> bool {
        let mut before = index - 1;
        while before > start
            && !self.items[before].ends_with_comma()
            && self.is_any_filler_word(before)
        {
            before -= 1;
        }
        self.items[before].ends_with_comma()
    }

    /// A comma closes the word at `index`, or a bare hesitation right after
    /// it: "scratch that uh, on Monday".
    fn comma_after(&self, index: usize, end: usize) -> bool {
        let mut after = index;
        while !self.items[after].ends_with_comma()
            && after < end
            && self.is_any_filler_word(after + 1)
        {
            after += 1;
        }
        self.items[after].ends_with_comma()
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
            if let Some(length) = self.restart_length(index) {
                // Keep the second copy; it opens the sentence if the first did.
                let opener = self.opens_sentence(index - length)
                    && !self.items[index - length].starts_lowercase();
                self.remove(index - length, index);
                changed = true;
                index -= length;
                if opener && index < self.items.len() && !self.items[index].protected {
                    self.capitalize_first_letter(index);
                }
                continue;
            }
            let filler = self.items[index].clone();
            let terminal: String = filler
                .punctuation()
                .chars()
                .filter(|c| SENTENCE_ENDING.contains(c))
                .collect();
            let opens = self.opens_sentence(index);
            let starts_sentence = opens && !filler.starts_lowercase();
            let is_last = index == self.items.len() - 1;

            let mut removal = (index, index);
            if index > 0 && !self.items[index - 1].protected {
                let previous = index - 1;
                if !terminal.is_empty() {
                    self.strip_closing_pauses(previous);
                    // "9 a.m., um?" keeps its question mark.
                    let asks = terminal.contains(['?', '!']);
                    if !self.items[previous].ends_with_sentence_punctuation()
                        || (asks && !opens && !self.items[previous].ends_asking())
                    {
                        self.items[previous].text.push_str(&terminal);
                    }
                } else if self.items[previous].ends_with_comma()
                    && (is_last
                        || (filler.ends_with_comma() && !self.comma_before_is_grammar(index)))
                {
                    // The commas around a hesitation are its pause.
                    self.items[previous].text.pop();
                    if self.items[previous].text.is_empty() {
                        removal = (previous, index);
                    }
                } else if self.items[previous].punctuation().is_empty()
                    && filler.ends_with_comma()
                    && !is_last
                    && self.opens_a_clause(index)
                    && self.comma_before_is_grammar(index)
                {
                    // "Thank you um, I'll": the comma belongs to the clause.
                    self.items[previous].text.push(',');
                }
            } else if index > 0 && !terminal.is_empty() && !self.ends_sentence(index - 1) {
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

            if has_before && !self.items[index - 1].protected && !self.ends_sentence(index - 1) {
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

    /// A repeat across a comma with no hesitation between: "It, it crashes",
    /// "Can we, can we move", "I don't, I don't know". The second copy must
    /// run on into the sentence ("No, no, no." stays).
    fn collapse_comma_restarts(&mut self) -> bool {
        let mut changed = false;
        let mut index = 0;
        while index + 1 < self.items.len() {
            let starts_restart =
                self.items[index].ends_with_comma() && !self.is_kept(&self.items[index]);
            let restart = if !starts_restart {
                None
            } else {
                self.repeated_length(index, index + 1, false)
                    .filter(|&length| {
                        let tail = &self.items[index + length];
                        let start = index + 1 - length;
                        // "It, it crashes", "Honestly, we, we", "for the, for the
                        // one" — not "you and I, I think", nor the "no" of
                        // "Не, не надо".
                        let clause_start = self.opens_sentence(start)
                            || self.items[start - 1].ends_with_comma()
                            || (length >= 2
                                && COMMA_STUTTER_WORDS
                                    .contains(&self.items[index].word().as_str()));
                        let answers_no = length == 1 && self.items[index].word() == "не";
                        clause_start
                            && !answers_no
                            && tail.punctuation().is_empty()
                            && !self.items[index + 1..=index + length]
                                .iter()
                                .any(|token| self.is_kept(token))
                    })
            };
            let Some(length) = restart else {
                index += 1;
                continue;
            };
            let start = index + 1 - length;
            let opener = self.opens_sentence(start) && !self.items[start].starts_lowercase();
            self.remove(start, index);
            if opener && start < self.items.len() && !self.items[start].protected {
                self.capitalize_first_letter(start);
            }
            changed = true;
            index = start;
        }
        changed
    }

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
            || has_line_break(&current.separator)
        {
            return false;
        }
        let word = current.word();
        // Laughter: "He he, that's funny", "He he he." — a run of "he" that
        // opens a sentence and ends with punctuation.
        if word == "he" {
            let mut first = index - 1;
            let mut last = index;
            while first > 0 && self.items[first - 1].word() == "he" {
                first -= 1;
            }
            while last + 1 < self.items.len()
                && self.items[last].punctuation().is_empty()
                && self.items[last + 1].word() == "he"
            {
                last += 1;
            }
            if self.opens_sentence(first) && !self.items[last].punctuation().is_empty() {
                return false;
            }
        }
        // A different case in mid-sentence is a different word: "220 В в сети".
        if previous.starts_uppercase() != current.starts_uppercase()
            && !self.opens_sentence(index - 1)
        {
            return false;
        }
        // "i" is the capital pronoun only: Polish "i i" is "and i", and after a
        // name it is a numeral: "World War I I moved".
        if word == "i"
            && (!(previous.text.starts_with('I') && current.text.starts_with('I'))
                || self.follows_a_name(index - 1))
        {
            return false;
        }
        // A spelled letter: "spelled A A R O N".
        let spelled = |token: &Token| token.is_single_letter() && token.starts_uppercase();
        if word.chars().count() == 1
            && current.starts_uppercase()
            && ((index >= 2 && spelled(&self.items[index - 2]))
                || self.items.get(index + 1).is_some_and(spelled))
        {
            return false;
        }
        if previous.punctuation().is_empty() {
            if RUN_ON_STUTTER_WORDS.contains(&word.as_str()) {
                return current.punctuation().is_empty()
                    && (!ENGLISH_STUTTER_WORDS.contains(&word.as_str())
                        || self.reads_as_english());
            }
            return STUTTER_WORDS.contains(&word.as_str());
        }
        if previous.punctuation() != "," {
            return false;
        }
        // "не, не" inside a sentence; opening one, "Не, не надо" says no.
        if COMMA_STUTTER_WORDS.contains(&word.as_str())
            || (word == "не" && !self.opens_sentence(index - 1))
        {
            return true;
        }
        self.opens_sentence(index - 1) && OPENING_COMMA_STUTTER_WORDS.contains(&word.as_str())
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

    /// Review round 3: every case a skeptic reproduced, as in
    /// `CleanVerbatimTests.swift`.
    #[test]
    fn review_round_three() {
        let cases = [
            (
                "I opened an MR. Ping the team about it. Scratch that.",
                "I opened an MR.",
            ),
            (
                "Review the MR. Merge it after lunch. Scratch that, merge it tomorrow.",
                "Review the MR. Merge it tomorrow.",
            ),
            (
                "Set the timeout to 500 ms. Use three retries. Scratch that.",
                "Set the timeout to 500 ms.",
            ),
            (
                "I asked the Mrs. She said no. Scratch that, she said yes.",
                "I asked the Mrs. She said yes.",
            ),
            ("Install MS. Office is great. Scratch that.", "Install MS."),
            ("Is it ready? No, scratch that, yes.", "Is it ready? Yes."),
            ("Ship it today. No, scratch that.", ""),
            (
                "Invite Anna, um, Maria and Bob.",
                "Invite Anna, Maria and Bob.",
            ),
            (
                "Пригласи Анну, э, Марию и Бориса.",
                "Пригласи Анну, Марию и Бориса.",
            ),
            ("I'm sorry, um, I love you.", "I'm sorry, I love you."),
            (
                "Hi John, um, can you review this?",
                "Hi John, can you review this?",
            ),
            ("Yes, um, that works for me.", "Yes, that works for me."),
            ("Да, ээ, это работает.", "Да, это работает."),
            (
                "We need milk, um, eggs and bread.",
                "We need milk, eggs and bread.",
            ),
            ("Купи хлеб, э, молоко и сыр.", "Купи хлеб, молоко и сыр."),
            (
                "Мы думаем, ээ, что надо подождать.",
                "Мы думаем, что надо подождать.",
            ),
            ("The build, uh, failed.", "The build failed."),
            ("Well, um, the build failed.", "Well, the build failed."),
            (
                "We should, um, ship and celebrate.",
                "We should ship and celebrate.",
            ),
            (
                "Stell die Config um, that should fix it.",
                "Stell die Config um, that should fix it.",
            ),
            ("And I um, think that works.", "And I think that works."),
            (
                "Handle the edge cases, e.g. uh, empty input.",
                "Handle the edge cases, e.g. empty input.",
            ),
            (
                "Нужно всё переписать, т.е. э, начать заново.",
                "Нужно всё переписать, т.е. начать заново.",
            ),
            (
                "I think... uh, maybe tomorrow.",
                "I think... maybe tomorrow.",
            ),
            (
                "Let's meet at 10 a.m. uh, on Monday.",
                "Let's meet at 10 a.m. on Monday.",
            ),
            (
                "Meet me at 5 p.m. on Monday, scratch that, on Tuesday.",
                "Meet me at 5 p.m. on Tuesday.",
            ),
            (
                "Compare tea vs. coffee, scratch that, water.",
                "Compare tea vs. water.",
            ),
            ("I'll be there by 9 a.m., uh.", "I'll be there by 9 a.m."),
            ("Bring plates, cups, etc., uh.", "Bring plates, cups, etc."),
            (
                "If I were you I'd uh scratch that.",
                "If I were you I'd scratch that.",
            ),
            ("Гласные: а, о, у, э", "Гласные: а, о, у, э"),
            ("Date formats: dd, mm, mmm", "Date formats: dd, mm, mmm"),
            ("Напряжение 220 В в сети.", "Напряжение 220 В в сети."),
            (
                "After World War I I moved to Paris.",
                "After World War I I moved to Paris.",
            ),
            ("Then I I moved to Paris.", "Then I moved to Paris."),
            ("Um hmm.", "Um hmm."),
            ("Um hmm, sounds good.", "Um hmm, sounds good."),
            (
                "Um hmm, that's the plan you know.",
                "Um hmm, that's the plan you know.",
            ),
            ("Read the the report", "Read the the report"),
            (
                "First paragraph. Uh, second paragraph.",
                "First paragraph. Second paragraph.",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(plain(input), expected, "input: {input:?}");
        }
        let words = protected_words(["commit в", "The The"]);
        assert_eq!(words, HashSet::from(["the".to_string()]));
    }

    /// Review round 4, as in `CleanVerbatimTests.swift`.
    #[test]
    fn review_round_four() {
        let cases = [
            (
                "Is it ready? Uh. No, scratch that, yes.",
                "Is it ready? Yes.",
            ),
            ("Is it ready? Hmm. No, scratch that.", "Is it ready?"),
            (
                "She asked, \"Is it ready?\" No, scratch that, yes.",
                "She asked, \"Is it ready?\" Yes.",
            ),
            ("Is it ready?! No, scratch that, yes.", "Is it ready?! Yes."),
            (
                "I live at 5 Main Dr. The house is blue. Scratch that.",
                "I live at 5 Main Dr.",
            ),
            (
                "We met the new Prof. She seems nice. Scratch that.",
                "We met the new Prof.",
            ),
            (
                "Done. 3 tests failed. Scratch that, all passed.",
                "Done. All passed.",
            ),
            (
                "Okay. \"Ship it\" was the plan. Scratch that, we wait.",
                "Okay. We wait.",
            ),
            (
                "Thanks, John, um, see you tomorrow.",
                "Thanks, John, see you tomorrow.",
            ),
            ("Okay, Mike, um, I will check.", "Okay, Mike, I will check."),
            ("Hi, Anna, um, quick question.", "Hi, Anna, quick question."),
            ("Ну, э, Sentry, э, упал.", "Ну, Sentry упал."),
            (
                "We'll ship it on Friday, uh scratch that, on Monday.",
                "On Monday.",
            ),
            ("Ship it today, uh scratch that.", ""),
            (
                "Ship it on Friday. Scratch that uh, on Monday.",
                "On Monday.",
            ),
            ("Send it to Anna, um scratch that, to Bob.", "To Bob."),
            ("I think that um um um um", "I think that"),
            (
                "So I'm um, not sure about that.",
                "So I'm not sure about that.",
            ),
            (
                "I think I'll um, call you tomorrow.",
                "I think I'll call you tomorrow.",
            ),
            ("Гласные: а́, о́, у́, э, ы́.", "Гласные: а́, о́, у́, э, ы́."),
        ];
        for (input, expected) in cases {
            assert_eq!(plain(input), expected, "input: {input:?}");
            assert_eq!(plain(&plain(input)), expected, "idempotent: {input:?}");
        }
    }

    /// Review round 5, as in `CleanVerbatimTests.swift`.
    #[test]
    fn review_round_five() {
        let cases = [
            ("No, no, um, that's wrong.", "No, no, that's wrong."),
            (
                "Well, actually, um, I think so.",
                "Well, actually, I think so.",
            ),
            ("Да, конечно, э, сделаю.", "Да, конечно, сделаю."),
            ("Okay, this, uh, looks good.", "Okay, this looks good."),
            ("Yes, it, um, works now.", "Yes, it works now."),
            ("Ну, это, э, работает.", "Ну, это работает."),
            (
                "Yes, rename, um, it to FooBar.",
                "Yes, rename it to FooBar.",
            ),
            (
                "Thanks, um, for the quick reply.",
                "Thanks for the quick reply.",
            ),
            ("Sorry, uh, for the delay.", "Sorry for the delay."),
            ("Спасибо, э, за помощь.", "Спасибо за помощь."),
            (
                "Okay, thanks, uh, for the quick reply.",
                "Okay, thanks for the quick reply.",
            ),
            (
                "Let me know if that works for you, um.",
                "Let me know if that works for you.",
            ),
            (
                "We should ship it on Friday, um.",
                "We should ship it on Friday.",
            ),
            ("Um, I don't know, um.", "I don't know."),
            ("Надо подождать, э.", "Надо подождать."),
            ("Is it ready, um?", "Is it ready?"),
            ("Гласные: а, о, у, э.", "Гласные: а, о, у, э."),
            ("Quero mais, um.", "Quero mais, um."),
            ("Date formats: dd, mm, mmm.", "Date formats: dd, mm, mmm."),
            ("The The um, build failed.", "The build failed."),
            ("We We um, should ship it.", "We should ship it."),
            (
                "I met Dr. Will Smith today. Scratch that. I met nobody.",
                "I met nobody.",
            ),
            (
                "Call Ms. May tomorrow, scratch that, call her today.",
                "Call her today.",
            ),
            ("Ask Dr. Will Jones about it, scratch that.", ""),
            (
                "We met the new Prof. Students love her. Scratch that.",
                "We met the new Prof.",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(plain(input), expected, "input: {input:?}");
            assert_eq!(plain(&plain(input)), expected, "idempotent: {input:?}");
        }
    }

    /// Review round 6, as in `CleanVerbatimTests.swift`.
    #[test]
    fn review_round_six() {
        let cases = [
            ("Купи хлеб, ээ, молоко, сыр.", "Купи хлеб, молоко, сыр."),
            (
                "Invite Anna, um, Maria, and Bob.",
                "Invite Anna, Maria, and Bob.",
            ),
            (
                "Add tests for login, uh, signup, and logout.",
                "Add tests for login, signup, and logout.",
            ),
            ("I met John, um, Paul.", "I met John, Paul."),
            (
                "Thank you, um, I'll take a look.",
                "Thank you, I'll take a look.",
            ),
            (
                "Thank you um, I'll take a look.",
                "Thank you, I'll take a look.",
            ),
            (
                "Refactor the function, uh, it's too long.",
                "Refactor the function, it's too long.",
            ),
            (
                "Let's use SQLite for now, um, it's simpler.",
                "Let's use SQLite for now, it's simpler.",
            ),
            (
                "Я не знаю, ээ, может быть завтра.",
                "Я не знаю, может быть завтра.",
            ),
            (
                "Anna, um, can you review my PR?",
                "Anna, can you review my PR?",
            ),
            (
                "Claude, um, please refactor this function.",
                "Claude, please refactor this function.",
            ),
            (
                "Коллеги, ээ, завтра созвон в десять.",
                "Коллеги, завтра созвон в десять.",
            ),
            ("Hey team, um, quick update.", "Hey team, quick update."),
            (
                "However, um, the tests still fail.",
                "However, the tests still fail.",
            ),
            ("Кстати, ээ, я забыл ключи.", "Кстати, я забыл ключи."),
            (
                "Well, basically, um, we ship it on Friday.",
                "Well, basically, we ship it on Friday.",
            ),
            ("Ну, короче, э, давай завтра.", "Ну, короче, давай завтра."),
            (
                "Hi everyone, um, thanks for joining.",
                "Hi everyone, thanks for joining.",
            ),
            (
                "Привет, ребята, э, есть минутка?",
                "Привет, ребята, есть минутка?",
            ),
            (
                "Dear John, um, thanks for the note.",
                "Dear John, thanks for the note.",
            ),
            ("Honestly, um, I'm not sure.", "Honestly, I'm not sure."),
            ("So Sentry, uh, is down.", "So Sentry is down."),
            ("Es geht um, äh, Geld.", "Es geht um Geld."),
            ("It's a, uh, a memory leak.", "It's a memory leak."),
            ("I'm, uh, I'm not sure.", "I'm not sure."),
            (
                "I want you to, uh, to add logging.",
                "I want you to add logging.",
            ),
            (
                "Write a function that, um, that returns the sum.",
                "Write a function that returns the sum.",
            ),
            ("Это, э, это баг.", "Это баг."),
            ("Can you, um, can you check it?", "Can you check it?"),
            (
                "Make sure, um, make sure it compiles.",
                "Make sure it compiles.",
            ),
            ("Я хотел, э, я хотел сказать.", "Я хотел сказать."),
            ("It's, um, it's not ready.", "It's not ready."),
            (
                "I, um, I think we should ship it.",
                "I think we should ship it.",
            ),
            ("Я, э, я думаю, что да.", "Я думаю, что да."),
            ("Давай в, э, в субботу.", "Давай в субботу."),
            ("We need a, um, a new plan.", "We need a new plan."),
            ("И, э, и потом мы уйдём.", "И потом мы уйдём."),
            ("Can you come at 9 a.m., um?", "Can you come at 9 a.m.?"),
            ("Is it ready by 5 p.m., uh?", "Is it ready by 5 p.m.?"),
            ("Hi Anna, Dr. Lee is here. Scratch that.", ""),
            (
                "I asked the team. Dr. Smith said no. Scratch that.",
                "I asked the team.",
            ),
            (
                "On Monday Dr. Smith called. Scratch that, on Tuesday.",
                "On Tuesday.",
            ),
            ("Invite Anna, Dr. Smith and Bob. Scratch that.", ""),
            (
                "Call Dr. Uh scratch that, call the nurse.",
                "Call the nurse.",
            ),
            (
                "Book it with Dr. Scratch that. Book it with the nurse.",
                "Book it with the nurse.",
            ),
            (
                "That's the plan. Um. Let's see what you think.",
                "That's the plan. Let's see what you think.",
            ),
            (
                "I don't know. Um... maybe you should ask them.",
                "I don't know. Maybe you should ask them.",
            ),
            ("Is it safe to merge? Uh uh.", "Is it safe to merge? Uh uh."),
            ("Nuh uh, that's not true.", "Nuh uh, that's not true."),
            ("Uh uh, don't merge that.", "Uh uh, don't merge that."),
            (
                "The old migration is broken. Scratch that? Or fix it?",
                "The old migration is broken. Scratch that? Or fix it?",
            ),
            (
                "If I say, scratch that, it should delete the sentence.",
                "If I say, scratch that, it should delete the sentence.",
            ),
            (
                "When the user says, scratch that, remove the last sentence.",
                "When the user says, scratch that, remove the last sentence.",
            ),
            (
                "Use the format dd, mmm, yyyy.",
                "Use the format dd, mmm, yyyy.",
            ),
            (
                "The date tokens are dd, mmm, and yyyy.",
                "The date tokens are dd, mmm, and yyyy.",
            ),
            ("He he, that's funny.", "He he, that's funny."),
            ("He he he, nice one.", "He he he, nice one."),
            ("Гласные: а, о, у, э, ы.", "Гласные: а, о, у, э, ы."),
            ("Ask me and I I.", "Ask me and I."),
            ("The the the deploy failed.", "The deploy failed."),
        ];
        for (input, expected) in cases {
            assert_eq!(plain(input), expected, "input: {input:?}");
            assert_eq!(plain(&plain(input)), expected, "idempotent: {input:?}");
        }
    }

    /// Round eight: the comma before a hesitation goes unless something
    /// keeps it, measured on a judged corpus; restarts across a hesitation;
    /// letters set against letters.
    #[test]
    fn review_round_eight() {
        let cases = [
            ("Try it, um, it works.", "Try it, it works."),
            (
                "Ask Uma, uh, Uma knows the answer.",
                "Ask Uma, Uma knows the answer.",
            ),
            (
                "That's very, um, very kind of you.",
                "That's very, very kind of you.",
            ),
            (
                "Мы обсудили бюджет, э, бюджет утвердили в пятницу.",
                "Мы обсудили бюджет, бюджет утвердили в пятницу.",
            ),
            (
                "I bought milk, uh, milk is expensive now.",
                "I bought milk, milk is expensive now.",
            ),
            (
                "Version 10, um, 10 users signed up.",
                "Version 10, 10 users signed up.",
            ),
            (
                "I sent the file, um, file names are wrong.",
                "I sent the file, file names are wrong.",
            ),
            (
                "Я отправил, ммм, отправил договор юристу.",
                "Я отправил договор юристу.",
            ),
            (
                "Не длиннее пятнадцати, ээ, пятнадцати секунд.",
                "Не длиннее пятнадцати секунд.",
            ),
            (
                "Сделай отдельный, э, отдельный endpoint.",
                "Сделай отдельный endpoint.",
            ),
            ("So I, um, I think it's fine.", "So I think it's fine."),
            ("It's a, um, an issue.", "It's an issue."),
            ("I gave it to the, to the team.", "I gave it to the team."),
            (
                "Between you and I, and I mean this, it's fine.",
                "Between you and I, and I mean this, it's fine.",
            ),
            (
                "The tests pass, um, and the build failed.",
                "The tests pass and the build failed.",
            ),
            (
                "Get milk, eggs, um, and the bread.",
                "Get milk, eggs, and the bread.",
            ),
            (
                "The API is done, uh, and the docs are live.",
                "The API is done, and the docs are live.",
            ),
            (
                "Call the vendor, uh, Sam has the number.",
                "Call the vendor, Sam has the number.",
            ),
            ("Пишется э, а не е.", "Пишется э, а не е."),
            (
                "Он сказал, э, а не пойти ли нам.",
                "Он сказал, а не пойти ли нам.",
            ),
            ("Напиши мне, э, если что.", "Напиши мне, если что."),
            ("Только, э, если успеем.", "Только если успеем."),
            (
                "Refer her to Dr. Haddad, uh, scratch that, to Dr. Moreau.",
                "To Dr. Moreau.",
            ),
            ("Не, не надо.", "Не, не надо."),
            ("Это не, не критично.", "Это не критично."),
            (
                "Use and and or instead of the symbols.",
                "Use and and or instead of the symbols.",
            ),
            ("Fruit, e.g., um, apples.", "Fruit, e.g., apples."),
            (
                "Нужен ноутбук, т. е., э, лёгкий.",
                "Нужен ноутбук, т. е. лёгкий.",
            ),
            ("Привет, ээ, хотел спросить.", "Привет, хотел спросить."),
            ("Марина, ээ, сказала, что да.", "Марина сказала, что да."),
            ("Маша, э, ты сделала?", "Маша, ты сделала?"),
            (
                "Я не буду, э, трогать модуль, пока нет тестов.",
                "Я не буду трогать модуль, пока нет тестов.",
            ),
            ("Eu queria uma, hmm, uma sopa.", "Eu queria uma sopa."),
            (
                "Can you, um, look at the failing test in auth.test.ts?",
                "Can you look at the failing test in auth.test.ts?",
            ),
            (
                "Добрый день, ээ, Наталья Сергеевна.",
                "Добрый день, Наталья Сергеевна.",
            ),
            (
                "Thanks, John, um, see you tomorrow.",
                "Thanks, John, see you tomorrow.",
            ),
            (
                "Я не знаю, ээ, может быть завтра.",
                "Я не знаю, может быть завтра.",
            ),
            (
                "На ревью три PR: от Лены, от Тимура, э, от Вадима.",
                "На ревью три PR: от Лены, от Тимура, от Вадима.",
            ),
            (
                "I booked the flights, uh, and Sam is handling the hotel.",
                "I booked the flights, and Sam is handling the hotel.",
            ),
            (
                "I like the red car, um, the one with stripes.",
                "I like the red car, the one with stripes.",
            ),
            (
                "Okay, if it fails, um, we roll back.",
                "Okay, if it fails, we roll back.",
            ),
            ("Okay, this, uh, looks good.", "Okay, this looks good."),
            (
                "I need, um, a new laptop, and a mouse.",
                "I need a new laptop, and a mouse.",
            ),
            (
                "Bring a tent, um, a warm jacket, and boots.",
                "Bring a tent, a warm jacket, and boots.",
            ),
            ("В общем, ээ, всё готово.", "В общем, всё готово."),
            (
                "Of course, um, we can do that.",
                "Of course, we can do that.",
            ),
            (
                "Мы, эм, честно говоря, не ожидали.",
                "Мы, честно говоря, не ожидали.",
            ),
            (
                "Это, э, может быть, лучший вариант.",
                "Это, может быть, лучший вариант.",
            ),
            (
                "Сервер, который мы купили в мае, ээ, сломался.",
                "Сервер, который мы купили в мае, сломался.",
            ),
            (
                "Дом, который построили для, э, нас.",
                "Дом, который построили для нас.",
            ),
            (
                "The server, which we set up last week, um, crashed.",
                "The server, which we set up last week, crashed.",
            ),
            (
                "Tell me, which one, um, you want.",
                "Tell me, which one you want.",
            ),
            ("Высылаю, э, акт сверки.", "Высылаю акт сверки."),
            ("Думаю, э, это сработает.", "Думаю, это сработает."),
            (
                "Андрей, э, посмотри пулреквест.",
                "Андрей, посмотри пулреквест.",
            ),
            (
                "We're meeting with the, um, with Kowalski's team.",
                "We're meeting with Kowalski's team.",
            ),
            ("It's a, uh, it's an issue.", "It's an issue."),
            ("Put it in the, uh, in my bag.", "Put it in my bag."),
            ("Talk to the, um, to Anna.", "Talk to Anna."),
            (
                "It needs a 3 mm, uh, a 3 mm margin.",
                "It needs a 3 mm margin.",
            ),
            (
                "It fires every, every 15 minutes.",
                "It fires every 15 minutes.",
            ),
            (
                "Перенести приём на среду, ммм.",
                "Перенести приём на среду.",
            ),
            ("Нам нужны, ммм, два монитора.", "Нам нужны два монитора."),
            (
                "Meet me at 5 p.m. on Monday, scratch that, on Tuesday.",
                "Meet me at 5 p.m. on Tuesday.",
            ),
            (
                "When I asked, the agent said mm hmm, uh, and left.",
                "When I asked, the agent said mm hmm and left.",
            ),
            ("Every, um, every time it fails.", "Every time it fails."),
            ("I want the, um, the blue one.", "I want the blue one."),
            ("Use the format dd, mmm.", "Use the format dd, mmm."),
        ];
        for (input, expected) in cases {
            assert_eq!(plain(input), expected, "input: {input:?}");
            assert_eq!(plain(&plain(input)), expected, "idempotent: {input:?}");
        }
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

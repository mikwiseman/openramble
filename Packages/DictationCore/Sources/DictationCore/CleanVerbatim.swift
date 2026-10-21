import Foundation

/// Cleanup that only ever deletes.
///
/// Speech carries traces that typing never does: hesitations, a word said
/// twice while the next one loads, a sentence taken back out loud. This stage
/// removes exactly those and nothing else. It never rewords, reorders or adds a
/// word, which is the whole difference from cleanup done by a language model:
/// that kind can turn "don't" into "do", this kind cannot, because it has no
/// way to write a word that was not said.
///
/// **When in doubt, keep.** A false deletion is the worse failure, so every
/// rule leans towards keeping. Two adversarial review rounds tried to make the
/// stage delete something real — German separable verbs, the Portuguese "one",
/// millimetres, acronyms, grammatical doubles, sentences glued across "p.m." —
/// and each of those is a test.
///
/// Three passes, in this order:
///
/// 1. **Spoken corrections.** "Scratch that" takes back what was just said: as
///    its own sentence or opening one, the sentence before it; at the end of a
///    sentence, or between commas in the middle of one, everything before it in
///    that sentence. The commas are what make it a command rather than the
///    verb. English only. Every full stop ends a sentence except a title's
///    ("Dr. Smith", written so, before a name): when that guess is wrong a
///    correction takes back too little, never a sentence the person meant to
///    keep.
/// 2. **Fillers.** Words that are hesitation and nothing else. "um", "э" and
///    "mmm" are words too (a German particle, the Portuguese "one", a Russian
///    letter, a date format), so they go only when punctuation sets them apart
///    on both sides. "um" also goes after a word in a take that reads as
///    English, and never from a take with German or Portuguese in it.
///    An all-caps token is an acronym; "uh huh" and "uh oh" are words. The
///    comma after a hesitation goes with it; the one before stays, because the
///    recognizer wrote it, unless it can only be the pause: after a word that
///    cannot end a phrase ("should, um,"), in "Thanks, um, for", or after the
///    sentence's opening subject ("The build, uh,"). A restart around a
///    hesitation keeps one copy ("It's a, uh, a leak"). Repeated until nothing
///    changes, so a hesitation that was hiding another one goes in the same
///    pass.
/// 3. **Stutters.** A short function word said twice in a row, from a list of
///    words whose doubles are never grammatical ("the the", "я я", "I, I").
/// 4. **"New paragraph"** ("Новый абзац"), set apart by punctuation, becomes a
///    paragraph break — in prose apps only. In a terminal a newline can run a
///    command, so verbatim apps keep the words. Last, so a hesitation after the
///    command is already gone and cannot take the break with it.
///
/// Protected spans and every name the person's own dictionary wrote are never
/// touched. A removal capitalizes what follows only when the removed piece
/// opened a sentence itself. Text with nothing to remove comes back exactly as it went in, and a
/// line break survives the removal of whatever followed it. A meeting
/// transcript turns spoken corrections off and keeps a turn that is nothing but
/// an interjection. The text is assumed to be NFC, as the recognizer writes it.
enum CleanVerbatim {
    static func clean(
        _ text: String,
        spokenCorrections: Bool = true,
        protectedWords: Set<String> = [],
        mode: PromptMode = .verbatim
    ) -> String {
        var tokens = Tokens(text, protectedWords: protectedWords)
        guard !tokens.items.isEmpty else { return text }

        let corrected = spokenCorrections && tokens.removeCorrections()
        var unfilled = false
        var unstuttered = false
        // Fillers and stutters until neither changes: removing one can expose
        // the other ("The The um,"). Each pass removes at least one token, so
        // the token count bounds it.
        for _ in 0...tokens.items.count {
            let filled = tokens.removeFillers()
            let restarted = tokens.collapseCommaRestarts()
            let stuttered = tokens.collapseStutters()
            unfilled = unfilled || filled
            unstuttered = unstuttered || restarted || stuttered
            guard filled || restarted || stuttered else { break }
        }
        // A take of nothing but hesitation is nothing: "Uh, um."
        if spokenCorrections, !tokens.items.isEmpty, tokens.isOnlyHesitation {
            tokens.items.removeAll()
            unfilled = true
        }
        let broken = mode == .prose && tokens.applyParagraphCommands()
        guard corrected || unfilled || unstuttered || broken else { return text }
        if !spokenCorrections, tokens.items.isEmpty { return text }
        return tokens.rendered
    }

    /// Every word a dictionary entry writes with a capital, lowercased: a name
    /// the person asked for ("The The", "Hmm Labs") is never a filler or a
    /// stutter. Lowercase connecting words ("commit в") are not names.
    /// A function word counts only when the name doubles it ("The The"), so
    /// "The Verge" does not stop "the the" from collapsing everywhere else.
    static func protectedWords(from replacements: [DictionaryReplacement]) -> Set<String> {
        Set(replacements.flatMap { replacement -> [String] in
            let words = replacement.written.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            return replacement.written.split(whereSeparator: \.isWhitespace).enumerated().compactMap { offset, word in
                guard word.unicodeScalars.contains(where: \.properties.isUppercase) else { return nil }
                let lower = word.lowercased()
                let doubled = (offset > 0 && words[offset - 1] == lower)
                    || (offset + 1 < words.count && words[offset + 1] == lower)
                return stutterWords.contains(lower) && !doubled ? nil : lower
            }
        })
    }

    /// Whether every word of `text` is a hesitation, counting the ones that
    /// are also words ("Um.", "Э."), which cleanup keeps when they stand alone.
    static func isOnlyHesitation(_ text: String) -> Bool {
        let tokens = Tokens(text)
        return !tokens.items.isEmpty && tokens.items.indices.allSatisfy { tokens.isAnyFillerWord(at: $0) }
    }

    // MARK: - Vocabulary

    /// Hesitation in every language Parakeet speaks: none of these is a word.
    static let fillers: Set<String> = [
        "uh", "uhh", "uhm", "umm", "erm", "hmm", "hm",
        "ээ", "эээ", "эмм",
        "äh", "ähm", "euh",
    ]

    /// Hesitations that are also words: "um" (a German particle, the
    /// Portuguese "one", the Slavic "mind"), "э" (a Russian letter), "mmm"
    /// (a date format). Removed only when punctuation sets them apart.
    static let guardedFillers: Set<String> = ["um", "er", "э", "эм", "mmm", "ммм"]

    /// Hesitations that are words in German or Portuguese ("um", the German
    /// "er"): in an English take they go wherever they stand.
    static let englishHesitations: Set<String> = ["um", "er"]

    /// Words that leave a phrase unfinished besides the pause words: "order
    /// more, um, more coffee", "Это такая, ээ, такая".
    static let unfinishedWords: Set<String> = [
        "more", "most", "some", "any", "many", "much", "every", "few", "less", "such", "этот", "эта", "эти", "такой",
        "такая", "такое", "такие", "самый", "самая", "um", "uma", "un", "una", "ein", "eine", "einen", "der",
        "die", "das", "le", "la", "les", "el", "los", "las",
    ]

    /// Russian hesitations that are also letter names ("э", "эм"): they go bare
    /// too, except next to a letter or after "буква".
    static let letterHesitations: Set<String> = ["э", "эм"]
    static let letterWords: Set<String> = ["буква", "букву", "буквы", "букве", "буквой"]

    /// Russian words of one letter, never a letter's name: "в", "и", "я".
    static let oneLetterWords: Set<String> = ["в", "к", "с", "у", "о", "и", "а", "я"]

    /// Hesitation words that are half of a two-word interjection: "uh huh"
    /// (yes), "uh oh", "mm hmm", "um hmm".
    static let interjectionHeads: Set<String> = ["uh", "um", "uhm", "mm", "mmm", "hm", "hmm"]
    static let interjectionTails: Set<String> = ["huh", "oh", "hmm", "hm"]

    /// "Uh uh" and "nuh uh" mean no.
    static let noHeads: Set<String> = ["uh", "nuh"]

    /// Words that mark a take as German or Portuguese, where "um" is a word.
    static let umIsAWordMarkers: Set<String> = [
        "der", "das", "und", "ist", "nicht", "ich", "wir", "sich", "auch", "ein", "eine", "mit",
        "es", "geht", "dann", "dich", "oder", "aber", "nein", "bitte", "danke",
        "não", "você", "uma", "eu", "quero", "também", "são", "dois", "três", "quatro",
        "por", "favor", "obrigado", "obrigada", "muito", "isso", "está", "para",
    ]

    /// Letters that only German or Portuguese write, among the languages here.
    static let umIsAWordLetters: Set<Character> = ["ä", "ö", "ü", "ß", "ã", "õ"]

    /// Words no other language the model speaks writes. One of them makes a
    /// take English, where "um" is never a word. ("need" is Estonian, "want"
    /// Dutch, "from" Swedish, so they are not here.)
    static let englishMarkers: Set<String> = [
        "the", "you", "your", "that", "this", "with", "what", "would", "should", "could",
        "they", "about", "think", "know", "there", "their", "it's", "don't", "i'm", "let's",
    ]

    /// Words that cannot end a phrase, so a comma after one before a
    /// hesitation can only be the pause: "should, um,", "что, э,".
    static let pauseCommaWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from", "by", "into", "about", "and",
        "or", "but", "so", "because", "if", "when", "that", "than", "i", "we", "he", "she", "they", "my",
        "your", "our", "their", "its", "am", "is", "are", "was", "were", "be", "been", "do", "does", "did",
        "have", "has", "had", "will", "would", "shall", "should", "can", "could", "may", "might", "must",
        "not", "don't", "doesn't", "didn't", "can't", "won't", "wouldn't", "shouldn't", "couldn't", "isn't",
        "aren't", "wasn't", "weren't", "i'm", "i'll", "we're", "you're", "they're", "let's", "please", "just",
        "я", "мы", "ты", "вы", "он", "она", "оно", "они", "не", "ни", "бы", "в", "во", "на", "с", "со", "к",
        "ко", "у", "по", "за", "из", "от", "до", "о", "об", "при", "для", "и", "а", "но", "или", "что",
        "чтобы", "если", "когда", "потому", "как", "который", "которая", "которое", "которые", "можешь",
        "можете", "может", "могу", "буду", "будешь", "будет", "будем", "будете", "будут", "нужно", "нужны", "нужен", "нужна", "надо",
        "только", "должен", "хочу", "which", "who", "whom", "whose", "кроме",
        "через", "между", "без", "перед", "около", "вместо", "then",
    ]

    /// What can open a sentence's subject before its one word: "So Sentry,",
    /// "The build,".
    /// Words that open a phrase the comma after it belongs to: an introductory
    /// word anywhere ("Honestly, um,", "а во-вторых, э,").
    static let introWords: Set<String> = [
        "actually", "honestly", "however", "unfortunately", "basically", "anyway", "also", "besides",
        "frankly", "кстати", "конечно", "наверное", "короче", "во-первых", "во-вторых", "в-третьих", "впрочем",
        "кажется", "честно", "например", "huh", "sorry",
    ]

    /// Introductory phrases of two or three words: "в общем", "of course".
    static let introPhrases: Set<String> = [
        "в общем", "в итоге", "в целом", "в принципе", "по сути", "честно говоря", "на самом деле", "может быть",
        "к сожалению", "к счастью", "скорее всего", "кстати говоря", "of course", "for example", "by the way",
        "in fact", "to be honest",
    ]

    /// First-person verbs that introduce a thought, so the comma after one
    /// opening a sentence is grammar: "Думаю, э, это сработает".
    static let thinkingVerbs: Set<String> = [
        "думаю", "полагаю", "считаю", "понимаю", "повторяю", "признаю", "знаю", "слушаю",
    ]

    /// First words of a sentence-opening phrase whose comma is grammar: a
    /// greeting ("Hi team,") or a leading clause or phrase ("If the linter
    /// complains,", "In the meantime,").
    static let greetings: Set<String> = [
        "hi", "hey", "hello", "dear", "good", "привет", "здравствуйте", "доброе", "добрый",
    ]
    static let leadingPhraseWords: Set<String> = [
        "if", "when", "once", "after", "before", "while", "since", "until", "unless", "although", "because",
        "by", "in", "for", "on", "at", "during", "если", "когда", "после", "пока", "хотя",
    ]

    /// Words after a hesitation that open a new clause, so the comma before
    /// stays: "works, um, but", "функцию, э, которая".
    static let clauseWords: Set<String> = [
        "but", "so", "yet", "not", "which", "who", "а", "но", "чтобы", "потому", "который", "которая",
        "которое", "которые", "чем", "что", "не", "если", "когда", "хотя", "sonst", "aber", "weil", "dass", "denn", "i'll", "i'm",
        "i've", "i'd", "it's", "that's", "there's", "we'll", "we're", "let's", "you'll", "they're", "he's",
        "she's",
    ]

    /// "and"/"и" followed by a new subject opens a clause: "email, um, and I".
    static let andWords: Set<String> = [
        "and", "or", "и", "или",
    ]
    static let subjectWords: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "the", "this", "that", "there", "my", "our", "your",
        "their", "я", "мы", "ты", "вы", "он", "она", "оно", "они", "это", "этот", "эта", "там", "тут",
    ]

    /// Subject words that also open a noun phrase: a clause only with its
    /// verb ("and the docs are live", not "and the tire pressure").
    static let nounPhraseOpeners: Set<String> = ["the", "this", "that", "my", "our", "your", "their"]
    static let clauseVerbs: Set<String> = [
        "is", "are", "was", "were", "has", "have", "had", "will", "would", "can", "could", "should",
        "isn't", "aren't", "wasn't", "weren't", "won't", "can't", "don't", "doesn't", "didn't",
    ]

    /// Words said twice for weight, even across a hesitation: "very, um, very".
    static let weightWords: Set<String> = [
        "very", "really", "yes", "yeah", "no", "okay", "ok", "bye", "да", "нет", "очень", "ага", "ладно",
    ]

    /// Object pronouns never start a list: "у нас, э, демо".
    static let objectPronouns: Set<String> = [
        "me", "us", "him", "them", "нас", "вас", "нам", "вам", "мне", "тебе", "ему", "ей", "им",
    ]

    /// Verbs that follow a sentence's subject: "Sentry, uh, is down" is no
    /// vocative.
    static let subjectVerbs: Set<String> = [
        "is", "was", "has", "isn't", "wasn't", "hasn't", "keeps", "seems", "looks",
    ]

    /// A Russian past-tense verb ("сделал") or infinitive ("купить"): a verb,
    /// so the word before it is no vocative.
    static func isRussianPastTense(_ word: String) -> Bool {
        word.count >= 3 && word.allSatisfy(isRussianLowercase)
            && ["л", "ла", "ло", "ли"].contains(where: word.hasSuffix)
    }

    static func isRussianInfinitive(_ word: String) -> Bool {
        word.count >= 4 && word.allSatisfy(isRussianLowercase)
            && ["ть", "ти", "чь"].contains(where: word.hasSuffix)
    }

    private static func isRussianLowercase(_ character: Character) -> Bool {
        ("а"..."я").contains(character) || character == "ё"
    }

    static let subjectDeterminers: Set<String> = [
        "the", "a", "an", "my", "your", "his", "her", "our", "their", "its", "this", "that", "these", "those",
        "мой", "моя", "моё", "мои", "наш", "наша", "наше", "наши", "твой", "твоя", "ваш", "ваша",
        "этот", "эта", "эти",
    ]

    /// Opening words that take an object: "Thanks for", "Спасибо за".
    static let thankingWords: Set<String> = ["thanks", "sorry", "спасибо", "извини"]
    static let thankingObjects: Set<String> = ["for", "about", "за"]

    /// Hesitations that also end a sentence or a take: "…for you, um."
    static let endingHesitations: Set<String> = ["um", "er", "э", "эм", "ммм"]

    /// Date-format tokens: "dd, mmm, yyyy" is not a hesitation.
    static let dateTokens: Set<String> = ["d", "dd", "m", "mm", "y", "yy", "yyyy", "hh", "ss"]

    /// Words after which "scratch that" is quoted, not said: "If I say, scratch that".
    static let speechVerbs: Set<String> = ["say", "says", "said", "saying", "type", "types", "typed", "typing"]

    /// Short function words whose doubles are never grammatical. Words that do
    /// double for a reason — "is is", "it it", "you you", "in in", "on on",
    /// "so so", "that that", "had had", "my my", "да да", "это это" — are left
    /// out. "i" counts only as the capital pronoun: Polish "i i" is "and i".
    static let stutterWords: Set<String> = [
        "i", "the", "we", "he", "she", "they", "our", "your", "but", "of", "with", "я", "мы", "ты", "вы", "он",
        "она", "оно", "они", "и", "но", "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
    ]

    /// Doubles that are stutters only when the second copy runs on into the
    /// sentence ("это это известный", not "Это это?"), and the first three
    /// only in English ("Il y a a priori", Polish "to to" are grammar).
    static let runOnStutterWords: Set<String> = [
        "to", "a", "an", "this", "этот", "эта", "эти", "это",
    ]
    static let englishStutterWords: Set<String> = ["to", "a", "an"]

    /// Russian letter names: "эс эм эс" is spelled, not hesitated.
    static let letterNames: Set<String> = [
        "эс", "эн", "эр", "эль", "эл", "эф", "ка", "тэ", "пэ", "бэ", "вэ", "гэ", "дэ", "зэ", "цэ", "ха", "ша",
    ]

    /// Doubles with a comma between them that are still stutters: "the, the".
    static let commaStutterWords: Set<String> = [
        "the", "our", "your", "every", "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
    ]

    /// Pronouns that stutter with a comma when they open a sentence: "I, I think".
    static let openingCommaStutterWords: Set<String> = ["i", "we", "я", "мы"]

    /// Spoken corrections, as consecutive words.
    static let corrections: [[String]] = [["scratch", "that"]]

    /// Words people lead a correction with: "Sorry, scratch that". Before the
    /// command they do not stop it from opening the sentence. "ah" is here
    /// because the model writes a spoken "uh" that way.
    /// "no" counts too, except right after a question, where it is the
    /// answer being corrected: "Is it ready? No, scratch that, yes."
    static let correctionLeadIns: Set<String> = [
        "ah", "oh", "okay", "ok", "so", "well", "sorry", "no", "actually", "wait", "oops",
    ]

    /// Spoken paragraph breaks, as consecutive words.
    static let paragraphCommands: [[String]] = [
        ["new", "paragraph"],
        ["новый", "абзац"],
    ]

    /// Titles whose full stop does not end a sentence, written exactly so:
    /// "MR." is a merge request and "ms." milliseconds.
    static let titles: Set<String> = ["Dr", "Mr", "Mrs", "Ms", "Prof"]

    /// Words before a title that make it a noun ending its sentence: "the Mrs."
    static let determiners: Set<String> = ["the", "a", "an", "my", "your", "his", "her", "our", "their"]

    /// Capitalized words after a title that are no name: "Dr. The house".
    static let notNames: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "it", "he", "she", "we", "they", "i", "you",
        "his", "her", "its", "our", "their", "my", "your", "there", "here", "then",
    ]

    static let trailingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "…"]
    static let sentenceEnding: Set<Character> = [".", "!", "?", "…"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]"]
}

// MARK: - Tokens

extension CleanVerbatim {
    /// Whitespace as the Rust port sees it: every scalar of the character is
    /// whitespace, so a combining mark after a space starts a word.
    static func isSpace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }

    /// One word, or one protected span, with the whitespace in front of it.
    struct Token {
        var separator: String
        var text: String
        let isProtected: Bool

        /// The word without its closing punctuation, lowercased.
        var word: String {
            String(text.reversed().drop(while: { CleanVerbatim.trailingPunctuation.contains($0) }).reversed())
                .lowercased()
        }

        /// The closing punctuation alone.
        var punctuation: String {
            String(text.reversed().prefix(while: { CleanVerbatim.trailingPunctuation.contains($0) }).reversed())
        }

        var endsWithComma: Bool { text.last == "," }

        /// An acronym: two or more letters, all capitals (per scalar, as Rust).
        var isShouting: Bool {
            let letters = text.unicodeScalars.filter(\.properties.isAlphabetic)
            return letters.count >= 2 && letters.allSatisfy(\.properties.isUppercase)
        }

        /// A title with the comma a hesitation left after it: "Mr.,".
        var isTitleBeforeComma: Bool {
            guard text.hasSuffix(".,") else { return false }
            return CleanVerbatim.titles.contains(String(text.dropLast(2)))
        }

        /// The text without closing quotes and brackets.
        private var unquoted: String {
            String(text.reversed().drop(while: { CleanVerbatim.closers.contains($0) }).reversed())
        }

        /// A full stop, question mark, exclamation or ellipsis closes this
        /// token, possibly inside a closing quote or bracket.
        var endsWithSentencePunctuation: Bool {
            unquoted.last.map { CleanVerbatim.sentenceEnding.contains($0) } ?? false
        }

        /// A title as written, full stop and all: "Dr.", "Mrs."
        var isTitle: Bool {
            let unquoted = unquoted
            guard unquoted.last == "." else { return false }
            return CleanVerbatim.titles.contains(String(unquoted.dropLast()))
        }

        /// Written with an ASCII digit: "10", "v2".
        var hasDigit: Bool { text.unicodeScalars.contains { (48...57).contains($0.value) } }

        var startsUppercase: Bool { text.unicodeScalars.first?.properties.isUppercase ?? false }

        /// Starts with a lowercase letter: what a removal before it did not
        /// open as a sentence ("e.g. uh, empty").
        var startsLowercase: Bool { text.unicodeScalars.first?.properties.isLowercase ?? false }

        /// Closes with a question mark or an exclamation, possibly quoted.
        var endsAsking: Bool { unquoted.last.map { $0 == "?" || $0 == "!" } ?? false }

        /// Asks a question, possibly inside a closing quote: "ready?", "ready?!"
        var endsWithQuestion: Bool {
            unquoted.reversed().prefix(while: { CleanVerbatim.trailingPunctuation.contains($0) }).contains("?")
        }

        /// One letter, perhaps with accents: "а", "у́", "э".
        var isSingleLetter: Bool {
            let scalars = word.unicodeScalars
            return scalars.filter(\.properties.isAlphabetic).count == 1
                && scalars.allSatisfy { $0.properties.isAlphabetic || (0x300...0x36F).contains($0.value) }
        }

        /// "I" and its contractions: "I'm", "I'll".
        var isFirstPerson: Bool {
            word == "i" || word.hasPrefix("i'") || word.hasPrefix("i’")
        }


        /// Only punctuation, detached from the word it closes: "Uh , the".
        var isDetachedPunctuation: Bool {
            !isProtected && !text.isEmpty && text.allSatisfy({ CleanVerbatim.trailingPunctuation.contains($0) })
        }
    }

    struct Tokens {
        var items: [Token] = []
        var trailing = ""
        let protectedWords: Set<String>

        init(_ text: String, protectedWords: Set<String> = []) {
            self.protectedWords = protectedWords
            let characters = Array(text)
            let spans = ProtectedSpanDetector.detect(in: text)
            var spanIndex = 0
            var separator = ""
            var index = 0

            while index < characters.count {
                while spanIndex < spans.count, spans[spanIndex].range.upperBound <= index {
                    spanIndex += 1
                }
                if spanIndex < spans.count, spans[spanIndex].range.lowerBound == index {
                    let range = spans[spanIndex].range
                    items.append(Token(separator: separator, text: String(characters[range]), isProtected: true))
                    separator = ""
                    index = range.upperBound
                    continue
                }
                if CleanVerbatim.isSpace(characters[index]) {
                    separator.append(characters[index])
                    index += 1
                    continue
                }
                var word = ""
                while index < characters.count, !CleanVerbatim.isSpace(characters[index]) {
                    if spanIndex < spans.count, spans[spanIndex].range.lowerBound == index { break }
                    word.append(characters[index])
                    index += 1
                }
                let token = Token(separator: separator, text: word, isProtected: false)
                // Punctuation the recognizer detached belongs to the word before it.
                if token.isDetachedPunctuation, !separator.isEmpty, let last = items.last, !last.isProtected,
                   !separator.contains(where: \.isNewline) {
                    items[items.count - 1].text += word
                } else {
                    items.append(token)
                }
                separator = ""
            }
            trailing = separator
        }

        var rendered: String {
            items.map { $0.separator + $0.text }.joined() + trailing
        }

        // MARK: Removal

        /// Remove `range`. The text's leading whitespace stays where it was,
        /// and a line break in front of the removed piece survives it.
        mutating func remove(_ range: ClosedRange<Int>) {
            let leading = items[range.lowerBound].separator
            items.removeSubrange(range)
            guard range.lowerBound < items.count else { return }
            let next = items[range.lowerBound].separator
            if range.lowerBound == 0
                || (leading.contains(where: \.isNewline) && !next.contains(where: \.isNewline)) {
                items[range.lowerBound].separator = leading
            }
        }

        private func isKept(_ token: Token) -> Bool {
            token.isProtected || token.isShouting || protectedWords.contains(token.word)
        }

        /// Whether the token at `index` closes a sentence. A title's full stop
        /// is the one exception: written exactly so, before a capitalized name,
        /// and not after "the" ("I asked the Mrs. She said…" ends one). A
        /// word like "The" or "She" after it is no name ("5 Main Dr. The house").
        func endsSentence(at index: Int) -> Bool {
            let token = items[index]
            guard token.endsWithSentencePunctuation else { return false }
            guard token.isTitle, items.indices.contains(index + 1) else { return true }
            let next = items[index + 1]
            guard next.startsUppercase, !CleanVerbatim.notNames.contains(next.word),
                  !isAnyFillerWord(at: index + 1), next.word != "scratch"
            else { return true }
            // "the Mrs.", "the new Prof." are nouns; look back inside the sentence
            // only. "her to Dr." is no noun phrase.
            if index > 0, CleanVerbatim.determiners.contains(items[index - 1].word) { return true }
            return index > 1 && items[index - 1].punctuation.isEmpty
                && !CleanVerbatim.pauseCommaWords.contains(items[index - 1].word)
                && CleanVerbatim.determiners.contains(items[index - 2].word)
        }

        private func opensSentence(at index: Int) -> Bool {
            index == 0 || endsSentence(at: index - 1)
        }

        /// Whether "um" is a word in this take: German or Portuguese in it.
        private var umIsAWord: Bool {
            items.contains { token in
                !token.isProtected && !token.isShouting
                    && (CleanVerbatim.umIsAWordMarkers.contains(token.word)
                        || token.text.lowercased().contains(where: { CleanVerbatim.umIsAWordLetters.contains($0) }))
            }
        }

        /// Every token is a hesitation the filler pass would remove: "Uh, um."
        var isOnlyHesitation: Bool {
            let umIsAWord = umIsAWord, readsAsEnglish = readsAsEnglish
            return items.indices.allSatisfy { isFiller(at: $0, umIsAWord: umIsAWord, readsAsEnglish: readsAsEnglish) }
        }

        /// Whether this take reads as English, where "um" is only a hesitation.
        private var readsAsEnglish: Bool {
            items.contains { !$0.isProtected && CleanVerbatim.englishMarkers.contains($0.word) }
        }

        private func word(at index: Int) -> String? {
            items.indices.contains(index) ? items[index].word : nil
        }

        private func isFiller(at index: Int, umIsAWord: Bool, readsAsEnglish: Bool) -> Bool {
            let token = items[index]
            guard !isKept(token) else { return false }
            let word = token.word
            // "uh huh", "uh oh", "mm hmm" are words.
            if CleanVerbatim.interjectionHeads.contains(word), token.punctuation.isEmpty,
               let next = self.word(at: index + 1), CleanVerbatim.interjectionTails.contains(next) {
                return false
            }
            if CleanVerbatim.interjectionTails.contains(word), index > 0, items[index - 1].punctuation.isEmpty,
               let previous = self.word(at: index - 1), CleanVerbatim.interjectionHeads.contains(previous) {
                return false
            }
            // "Uh uh", "nuh uh": no.
            if word == "uh", index > 0, items[index - 1].punctuation.isEmpty,
               let previous = self.word(at: index - 1), CleanVerbatim.noHeads.contains(previous) {
                return false
            }
            if CleanVerbatim.noHeads.contains(word), token.punctuation.isEmpty, self.word(at: index + 1) == "uh" {
                return false
            }
            if CleanVerbatim.fillers.contains(word) { return true }
            guard CleanVerbatim.guardedFillers.contains(word) else { return false }
            if CleanVerbatim.englishHesitations.contains(word), umIsAWord { return false }
            // In an English take "um" and "er" are only hesitation.
            if CleanVerbatim.englishHesitations.contains(word), readsAsEnglish, !followsAName(index) { return true }
            // "э", "эм" are letters only in a letter list or after "буква".
            let listedLetter = { (token: Token) in token.isSingleLetter && token.punctuation == "," }
            let letterName = { (token: Token) in CleanVerbatim.letterNames.contains(token.word) }
            let letterContext = (index > 0
                && (listedLetter(items[index - 1]) || letterName(items[index - 1])
                    || CleanVerbatim.letterWords.contains(items[index - 1].word)))
                || (items.indices.contains(index + 1) && letterName(items[index + 1]))
                || (token.punctuation == "," && items.indices.contains(index + 1)
                    && items[index + 1].isSingleLetter && !items[index + 1].punctuation.isEmpty)
                // Set against another letter: "пишется э, а не е", "через э, а не через е".
                || (token.punctuation == "," && self.word(at: index + 1) == "а" && self.word(at: index + 2) == "не"
                    && items.dropFirst(index + 3).prefix(2).contains {
                        $0.isSingleLetter && !CleanVerbatim.oneLetterWords.contains($0.word)
                    })
            if CleanVerbatim.letterHesitations.contains(word),
               token.punctuation.isEmpty || token.punctuation == ",", !letterContext {
                return true
            }
            // A letter among different letters: "а, о, у, э, ы". The same word
            // on both sides is a restart: "Я, э, я думаю".
            if CleanVerbatim.letterHesitations.contains(word), index > 0, items.indices.contains(index + 1),
               items[index - 1].isSingleLetter, items[index + 1].isSingleLetter,
               items[index - 1].word != items[index + 1].word {
                return false
            }
            // A date format: "dd, mmm, yyyy".
            if word == "mmm", [index - 1, index + 1].contains(where: { CleanVerbatim.dateTokens.contains(self.word(at: $0) ?? "") }) {
                return false
            }
            // Hesitations in a row are one pause: "um uh, now", "um um, we".
            var runEnd = index + 1
            while runEnd < items.count, items[runEnd].punctuation.isEmpty, isAnyFillerWord(at: runEnd) { runEnd += 1 }
            let carriesComma = token.endsWithComma
                || (runEnd > index + 1 && runEnd < items.count && isAnyFillerWord(at: runEnd) && items[runEnd].endsWithComma)
                || (token.punctuation.isEmpty && items.indices.contains(index + 1)
                    && isAnyFillerWord(at: index + 1) && items[index + 1].endsWithComma)
            let apartBefore = opensSentence(at: index) || items[index - 1].endsWithComma
                || (word == "um" && readsAsEnglish && !followsAName(index))
            if carriesComma, apartBefore { return true }
            // A sentence of its own in English: "That's the plan. Um. Let's see."
            if word == "um", readsAsEnglish, opensSentence(at: index), endsSentence(at: index) { return true }
            guard CleanVerbatim.endingHesitations.contains(word),
                  !(CleanVerbatim.letterHesitations.contains(word) && letterContext)
            else { return false }
            // One a sentence end sets apart after a comma: "…for you, um."
            let punctuation = token.punctuation
            if !punctuation.isEmpty, !punctuation.contains(","), index > 0, items[index - 1].endsWithComma {
                return true
            }
            // One the end of the text sets apart, where a trailing command took
            // its comma: "…the end um" from "…the end um, new line."
            return punctuation.isEmpty && index == items.count - 1 && apartBefore
        }

        /// A capitalized word just before, in the middle of a sentence: a German
        /// noun with its separable verb ("Stell die Config um"), or a name.
        private func followsAName(_ index: Int) -> Bool {
            index > 0 && !opensSentence(at: index) && items[index - 1].startsUppercase
                && !items[index - 1].isFirstPerson && !opensSentence(at: index - 1)
        }

        /// Whether the comma before the hesitation at `index` is grammar, so it
        /// stays. A hesitation's commas are its pause and go with it, unless the
        /// one before closes something a careful writer would close with a
        /// comma: an opening word or clause, an introductory word, a clause that
        /// follows, a name, a list.
        private func commaBeforeIsGrammar(at index: Int) -> Bool {
            let previous = items[index - 1]
            let previousWord = previous.word
            // Russian sets every introductory word off, the comma before it
            // included: "Мы, эм, честно говоря, не ожидали".
            if let end = russianIntro(at: index + 1), items[end].endsWithComma { return true }
            if CleanVerbatim.pauseCommaWords.contains(previousWord) { return false }
            guard items.indices.contains(index + 1) else { return false }
            let next = items[index + 1]
            let nextWord = next.word
            // "Thanks, um, for" is one phrase; a title keeps its name ("Mr. Henderson").
            if (CleanVerbatim.thankingWords.contains(previousWord) && CleanVerbatim.thankingObjects.contains(nextWord))
                || previous.isTitleBeforeComma {
                return false
            }
            // English writes a comma after "e.g." and "i.e."; after any other
            // abbreviation's full stop the comma is the pause: "т. е., э, не".
            if ["e.g", "i.e"].contains(previousWord) { return true }
            if previous.text.hasSuffix(".,") { return false }
            // Russian "и"/"или" joining a last item takes no comma: "фронтендер и тестировщик".
            if ["и", "или"].contains(nextWord), !CleanVerbatim.subjectWords.contains(word(at: index + 2) ?? "") {
                return false
            }
            // The same word on both sides keeps its comma rather than glue "it
            // it". An appositive restates the noun: "the old flag, er, the one".
            if nextWord == previousWord || CleanVerbatim.introWords.contains(previousWord)
                || introPhraseEnds(at: index - 1)
                || CleanVerbatim.clauseWords.contains(nextWord)
                || (nextWord == "the" && ["one", "ones"].contains(word(at: index + 2) ?? "")) {
                return true
            }
            // "не знаю, ээ, может быть завтра".
            if russianIntro(at: index + 1) != nil || closesARelativeClause(at: index) { return true }
            // "and I", "и они", "and Sam is": a new clause. The last item of a
            // list of three keeps its comma too: "the flights, uh, and the car".
            if CleanVerbatim.andWords.contains(nextWord),
               andOpensAClause(at: index + 1) || afterAListComma(at: index) {
                return true
            }
            // A name that closes the phrase: "Thanks again, um, Jordan,", or
            // opens a clause: "the vendor call, uh, Hannah is out". German
            // capitalizes every noun, so not there ("Es geht um, äh, Geld.").
            if next.startsUppercase, !next.isFirstPerson,
               !next.punctuation.isEmpty || verbFollows(at: index + 2), !umIsAWord {
                return true
            }
            // A list: "eggs, milk, uh, butter", "10, um, 30", "chips, um, soda,".
            // An opening word before is no list item ("Okay, this, uh,"), unless
            // a greeting names someone ("Привет, ребята, э,").
            if index >= 2, items[index - 2].endsWithComma,
               !opensSentence(at: index - 2) || CleanVerbatim.greetings.contains(items[index - 2].word) {
                return true
            }
            // A name set off by commas: "Thanks, John, um, see you". Not a
            // subject before its verb: "Ну, Sentry, э, упал".
            if index >= 2, previous.startsUppercase, !previous.isFirstPerson, !opensSentence(at: index - 1),
               items[index - 2].endsWithComma, !verbFollows(at: index + 1), !umIsAWord {
                return true
            }
            // Items that repeat their first word: "от Лены, от Тимура, э, от Вадима".
            if index >= 4, items[index - 2].punctuation.isEmpty, items[index - 2].word == nextWord,
               items[index - 3].endsWithComma, items[index - 4].word == nextWord {
                return true
            }
            if previous.hasDigit, next.hasDigit { return true }
            // A subject before its verb is no list item: "Марина, ээ, сказала".
            // A greeting keeps its comma: "Привет, ээ, хотел".
            if opensSentence(at: index - 1), !CleanVerbatim.greetings.contains(previousWord),
               verbFollows(at: index + 1) {
                return false
            }
            if continuesAList(at: index) { return true }
            return openingComma(at: index)
        }

        /// A clause starts right after the hesitation: "but", "I'll", "and I".
        private func opensAClause(at index: Int) -> Bool {
            let next = word(at: index + 1) ?? ""
            return CleanVerbatim.clauseWords.contains(next)
                || (CleanVerbatim.andWords.contains(next) && andOpensAClause(at: index + 1))
        }

        /// The "and" at `index` opens a clause: a new subject ("and I", "и
        /// они", "and Sam is"), or a noun phrase with its verb ("and the docs
        /// are live", not "and the tire pressure").
        private func andOpensAClause(at index: Int) -> Bool {
            guard items.indices.contains(index + 1) else { return false }
            let subject = items[index + 1]
            guard CleanVerbatim.subjectWords.contains(subject.word) else {
                return subject.startsUppercase && !subject.isFirstPerson && verbFollows(at: index + 2)
            }
            guard CleanVerbatim.nounPhraseOpeners.contains(subject.word) else { return true }
            var at = index + 1
            while at < items.count, at <= index + 4, items[at].punctuation.isEmpty {
                at += 1
                if CleanVerbatim.clauseVerbs.contains(word(at: at) ?? "") { return true }
            }
            return false
        }

        /// An earlier comma in this sentence sets off a list item, so the
        /// comma before the hesitation at `index` is the list's.
        private func afterAListComma(at index: Int) -> Bool {
            var at = index - 1
            while at > 0, !endsSentence(at: at - 1) {
                at -= 1
                if items[at].endsWithComma { return !opensSentence(at: at) && index - 1 - at <= 3 }
            }
            return false
        }

        /// An introductory phrase of two or three words ends at `end`: "в
        /// общем", "of course".
        private func introPhraseEnds(at end: Int) -> Bool {
            (2...3).contains { length in
                guard end + 1 >= length else { return false }
                let words = items[(end + 1 - length)...end]
                return !words.dropLast().contains(where: { !$0.punctuation.isEmpty })
                    && CleanVerbatim.introPhrases.contains(words.map(\.word).joined(separator: " "))
            }
        }

        /// Where a Russian introductory word or phrase starting at `start`
        /// ends: "кстати", "честно говоря".
        private func russianIntro(at start: Int) -> Int? {
            guard let first = word(at: start), first.contains(where: { ("а"..."я").contains($0) }) else { return nil }
            for length in stride(from: 3, through: 2, by: -1) where start + length <= items.count {
                let words = items[start..<(start + length)]
                if !words.dropLast().contains(where: { !$0.punctuation.isEmpty }),
                   CleanVerbatim.introPhrases.contains(words.map(\.word).joined(separator: " ")) {
                    return start + length - 1
                }
            }
            return CleanVerbatim.introWords.contains(first) ? start : nil
        }

        /// The comma before the hesitation at `index` closes a relative clause
        /// the sentence opened with a comma: "Переводчик, которого нам
        /// посоветовали в Ташкенте, ээ, берёт".
        private func closesARelativeClause(at index: Int) -> Bool {
            var at = index - 1
            while at > 0, !endsSentence(at: at - 1) {
                at -= 1
                if items[at].endsWithComma {
                    let opener = items[at + 1].word
                    return index - 1 - at >= 3 && (opener.hasPrefix("котор") || ["which", "who"].contains(opener))
                }
            }
            return false
        }

        /// The word at `index` is a verb that follows its subject: "is",
        /// "сделал".
        private func verbFollows(at index: Int) -> Bool {
            guard let word = word(at: index) else { return false }
            return CleanVerbatim.subjectVerbs.contains(word) || CleanVerbatim.isRussianPastTense(word)
        }

        /// One or two words after the hesitation, three after "a" or "the",
        /// then a comma or "and": the next item of a list, written the same
        /// way as the one before it (both bare, or both after "the").
        private func continuesAList(at index: Int) -> Bool {
            let determined = { (token: Token) in CleanVerbatim.subjectDeterminers.contains(token.word) }
            let continues = (1...3).contains { length in
                let last = index + length
                guard last < items.count, length < 3 || determined(items[index + 1]),
                      !items[(index + 1)..<last].contains(where: { !$0.punctuation.isEmpty })
                else { return false }
                return items[last].endsWithComma || CleanVerbatim.andWords.contains(word(at: last + 1) ?? "")
            }
            guard continues, !CleanVerbatim.objectPronouns.contains(items[index - 1].word),
                  !CleanVerbatim.isRussianInfinitive(items[index - 1].word)
            else { return false }
            let previousDetermined = index >= 2 && items[index - 2].punctuation.isEmpty && determined(items[index - 2])
            return previousDetermined == determined(items[index + 1])
        }

        /// The comma closes the opening of the sentence: a single word
        /// ("Okay,", "Sarah,", "Кстати,"), a greeting ("Hi team,"), or a leading
        /// clause or phrase ("If the linter complains,", "In the meantime,").
        private func openingComma(at index: Int) -> Bool {
            let end = index - 1
            var start = end
            while start > 0, !endsSentence(at: start - 1) { start -= 1 }
            let bare = { (from: Int) in !self.items[from..<end].contains(where: { !$0.punctuation.isEmpty }) }
            // A leading phrase after an opening word: "Claude, before you
            // change anything, uh,".
            if start < end, items[start].endsWithComma, bare(start + 1) {
                return start + 1 < end && CleanVerbatim.leadingPhraseWords.contains(items[start + 1].word)
            }
            guard bare(start) else { return false }
            let first = items[start].word
            if start == end {
                // A subject before its verb is no vocative: "Sentry, uh, is
                // down", "Дима, э, сделал". A greeting always is: "Привет,
                // хотел". A first-person verb takes its object: "Высылаю, э,
                // акт", unless it introduces a thought: "Думаю, э, это".
                let acts = first.hasSuffix("ю") && first.count >= 4
                    && first.allSatisfy({ ("а"..."я").contains($0) || $0 == "ё" })
                    && !CleanVerbatim.thinkingVerbs.contains(first)
                return CleanVerbatim.greetings.contains(first)
                    || !CleanVerbatim.isRussianInfinitive(first) && !acts && !verbFollows(at: index + 1)
            }
            return (CleanVerbatim.greetings.contains(first) && end - start < 4)
                || CleanVerbatim.leadingPhraseWords.contains(first)
        }

        /// How many words before the hesitation at `index` are said again
        /// right after it — a restart: "It's a, uh, a leak", "Can you, um, can you".
        private func restartLength(around index: Int) -> Int? {
            guard index > 0, !endsSentence(at: index) else { return nil }
            return repeatedLength(endingAt: index - 1, againAt: index + 1, acrossHesitation: true)
                ?? revisedLength(around: index)
        }

        /// How many words before the hesitation at `index` start a phrase that
        /// stops on a word that cannot end it and is begun again with another
        /// ending: "with the, um, with Kowalski's", "It's a, uh, it's an".
        private func revisedLength(around index: Int) -> Int? {
            for length in stride(from: 3, through: 2, by: -1) {
                guard index >= length, index + length < items.count else { continue }
                let before = items[(index - length)..<index]
                let again = items[(index + 1)..<(index + length)]
                let last = items[index - 1]
                let lastWord = last.word
                guard CleanVerbatim.pauseCommaWords.contains(lastWord) || CleanVerbatim.unfinishedWords.contains(lastWord),
                      !last.startsUppercase,
                      last.punctuation.isEmpty || last.punctuation == ",",
                      !before.dropLast().contains(where: { !$0.punctuation.isEmpty }),
                      !before.contains(where: isKept), !again.contains(where: isKept),
                      zip(again, before).allSatisfy({ $0.punctuation.isEmpty && $0.word == $1.word })
                else { continue }
                return length
            }
            return nil
        }

        /// How many words ending at `beforeEnd` are said again starting at
        /// `afterStart`: a restart when the first copy opens the sentence or
        /// stops on a word that cannot end a phrase ("It's a, a leak", "Can
        /// you, can you"), never a clause boundary ("Try it, it works"). Across
        /// a hesitation any other phrase is a restart too when the second copy
        /// runs on, unless it is said for weight or could open the next clause
        /// ("the ERP, uh, the ERP migration", "отправил, ммм, отправил договор").
        private func repeatedLength(endingAt beforeEnd: Int, againAt afterStart: Int, acrossHesitation: Bool) -> Int? {
            for length in stride(from: 3, through: 1, by: -1) {
                guard beforeEnd + 1 >= length, afterStart + length <= items.count else { continue }
                let beforeStart = beforeEnd + 1 - length
                let before = items[beforeStart...beforeEnd]
                let after = items[afterStart..<(afterStart + length)]
                let last = items[beforeEnd]
                let lastWord = last.word
                // Capitalized inside a sentence it is a name: "Ask Uma, uh, Uma knows".
                let named = last.startsUppercase && !last.isFirstPerson && !opensSentence(at: beforeEnd)
                let unfinished = !named
                    && (CleanVerbatim.pauseCommaWords.contains(lastWord) || CleanVerbatim.unfinishedWords.contains(lastWord))
                let firstWord = items[beforeStart].word
                // A verb right after the second copy makes it a new subject:
                // "milk, uh, milk is", "бюджет, э, бюджет утвердили".
                let verbAt = { (at: Int) -> Bool in
                    guard let word = self.word(at: at) else { return false }
                    return CleanVerbatim.clauseVerbs.contains(word) || CleanVerbatim.subjectVerbs.contains(word)
                        || CleanVerbatim.isRussianPastTense(word)
                }
                let next = afterStart + length
                let subject = verbAt(next)
                    || (items.indices.contains(next) && items[next].punctuation.isEmpty && verbAt(next + 1))
                let restarts = acrossHesitation
                    && after.last!.punctuation.isEmpty
                    && next < items.count
                    && !subject
                    && !items[beforeStart].startsUppercase
                    && !CleanVerbatim.subjectWords.contains(firstWord)
                    && !CleanVerbatim.objectPronouns.contains(firstWord)
                    && !CleanVerbatim.weightWords.contains(lastWord)
                    && (length > 1 || !before.contains(where: \.hasDigit))
                guard opensSentence(at: beforeStart) || unfinished || restarts,
                      !before.contains(where: isKept), !after.contains(where: isKept),
                      !before.dropLast().contains(where: { !$0.punctuation.isEmpty }),
                      before.last.map({ $0.punctuation.isEmpty || $0.punctuation == "," }) ?? false,
                      !after.dropLast().contains(where: { !$0.punctuation.isEmpty }),
                      // "a, um, an": the article said again for the next sound.
                      zip(before, after).allSatisfy({
                          $0.word == $1.word || (["a", "an"].contains($0.word) && ["a", "an"].contains($1.word))
                      })
                else { continue }
                return length
            }
            return nil
        }

        /// A hesitation, as far as a correction is concerned: any filler word,
        /// guarded or not, because it can only stand between words here.
        func isAnyFillerWord(at index: Int) -> Bool {
            let token = items[index]
            guard !isKept(token) else { return false }
            return CleanVerbatim.fillers.contains(token.word) || CleanVerbatim.guardedFillers.contains(token.word)
        }

        // MARK: Pass 1: corrections

        private var sentences: [ClosedRange<Int>] {
            var result: [ClosedRange<Int>] = []
            var start = 0
            for index in items.indices where endsSentence(at: index) || index == items.count - 1 {
                result.append(start...index)
                start = index + 1
            }
            return result
        }

        mutating func removeCorrections() -> Bool {
            var changed = false
            // Each removal shortens the text, so the bound is the token count.
            for _ in 0..<items.count {
                guard let range = nextCorrection() else { break }
                let opener = !items[range.lowerBound].startsLowercase
                remove(range)
                changed = true
                // Every removal starts at a sentence start; what is left there
                // opens the sentence when the removed piece did ("vs. coffee,
                // scratch that, water" did not).
                if opener, range.lowerBound < items.count, !items[range.lowerBound].isProtected {
                    capitalizeFirstLetter(at: range.lowerBound)
                }
            }
            return changed
        }

        /// The tokens the first spoken correction removes, itself included.
        private func nextCorrection() -> ClosedRange<Int>? {
            let sentences = sentences
            for (position, sentence) in sentences.enumerated() {
                let words = sentence.filter { !isAnyFillerWord(at: $0) }
                let spoken = words.map { items[$0].isProtected ? items[$0].text : items[$0].word }

                for command in CleanVerbatim.corrections where spoken.count >= command.count {
                    for offset in 0...(spoken.count - command.count)
                    where Array(spoken[offset..<(offset + command.count)]) == command {
                        let first = words[offset]
                        let last = words[offset + command.count - 1]
                        // A question is not a command: "Scratch that? Or fix it?"
                        if items[last].endsWithQuestion { continue }
                        // Quoted after a speech verb: "If I say, scratch that, …"
                        var said = first - 1
                        while said >= sentence.lowerBound, isAnyFillerWord(at: said) { said -= 1 }
                        if said >= sentence.lowerBound, CleanVerbatim.speechVerbs.contains(items[said].word) { continue }
                        let afterQuestion = previousSentence(before: position, in: sentences)
                            .map { items[sentences[$0].upperBound].endsWithQuestion } ?? false
                        let opens = spoken[..<offset].allSatisfy {
                            CleanVerbatim.correctionLeadIns.contains($0) && !($0 == "no" && afterQuestion)
                        }
                        let closes = offset + command.count == spoken.count
                        let pauseBefore = first > sentence.lowerBound && commaBefore(first, from: sentence.lowerBound)
                        let pauseAfter = commaAfter(last, to: sentence.upperBound)

                        if opens, closes || pauseAfter {
                            return previousStart(before: position, in: sentences)...(closes ? sentence.upperBound : last)
                        }
                        if closes, pauseBefore {
                            return sentence
                        }
                        if !opens, !closes, pauseBefore, pauseAfter {
                            return sentence.lowerBound...last
                        }
                    }
                }
            }
            return nil
        }

        /// Where the sentence a correction takes back begins. Sentences of
        /// nothing but hesitation are passed over and go with it.
        private func previousStart(before position: Int, in sentences: [ClosedRange<Int>]) -> Int {
            sentences[previousSentence(before: position, in: sentences) ?? 0].lowerBound
        }

        /// The sentence before `position` that is more than hesitation.
        private func previousSentence(before position: Int, in sentences: [ClosedRange<Int>]) -> Int? {
            var candidate = position - 1
            while candidate >= 0, sentences[candidate].allSatisfy({ isAnyFillerWord(at: $0) }) {
                candidate -= 1
            }
            return candidate >= 0 ? candidate : nil
        }

        /// A comma closes the word before `index`, perhaps behind bare
        /// hesitations: "Friday, uh scratch that".
        private func commaBefore(_ index: Int, from start: Int) -> Bool {
            var before = index - 1
            while before > start, !items[before].endsWithComma, isAnyFillerWord(at: before) { before -= 1 }
            return items[before].endsWithComma
        }

        /// A comma closes the word at `index`, or a bare hesitation right
        /// after it: "scratch that uh, on Monday".
        private func commaAfter(_ index: Int, to end: Int) -> Bool {
            var after = index
            while !items[after].endsWithComma, after < end, isAnyFillerWord(at: after + 1) { after += 1 }
            return items[after].endsWithComma
        }

        // MARK: Pass 2: fillers

        mutating func removeFillers() -> Bool {
            let umIsAWord = umIsAWord
            let readsAsEnglish = readsAsEnglish
            var changed = false
            var index = 0
            while index < items.count {
                guard isFiller(at: index, umIsAWord: umIsAWord, readsAsEnglish: readsAsEnglish) else {
                    index += 1
                    continue
                }
                if let length = restartLength(around: index) {
                    // Keep the second copy; it opens the sentence if the first did.
                    let opener = opensSentence(at: index - length) && !items[index - length].startsLowercase
                    remove((index - length)...index)
                    changed = true
                    index -= length
                    if opener, index < items.count, !items[index].isProtected { capitalizeFirstLetter(at: index) }
                    continue
                }
                let filler = items[index]
                let terminal = String(filler.punctuation.filter { CleanVerbatim.sentenceEnding.contains($0) })
                let opens = opensSentence(at: index)
                let startsSentence = opens && !filler.startsLowercase
                let isLast = index == items.count - 1

                var removal = index...index
                if index > 0, !items[index - 1].isProtected {
                    let previous = index - 1
                    if !terminal.isEmpty {
                        stripClosingPauses(at: previous)
                        // "9 a.m., um?" keeps its question mark.
                        let asks = terminal.contains { $0 == "?" || $0 == "!" }
                        if !items[previous].endsWithSentencePunctuation || (asks && !opens && !items[previous].endsAsking) {
                            items[previous].text += terminal
                        }
                    } else if items[previous].endsWithComma,
                              isLast || (filler.endsWithComma && !commaBeforeIsGrammar(at: index)) {
                        // The commas around a hesitation are its pause.
                        items[previous].text.removeLast()
                        if items[previous].text.isEmpty { removal = previous...index }
                    } else if items[previous].punctuation.isEmpty, filler.endsWithComma, !isLast,
                              opensAClause(at: index), commaBeforeIsGrammar(at: index) {
                        // "Thank you um, I'll": the comma belongs to the clause.
                        items[previous].text += ","
                    }
                } else if index > 0, !terminal.isEmpty, !endsSentence(at: index - 1) {
                    items.insert(Token(separator: "", text: terminal, isProtected: false), at: index)
                    removal = (index + 1)...(index + 1)
                }

                remove(removal)
                changed = true
                index = removal.lowerBound

                if startsSentence, index < items.count, !items[index].isProtected {
                    capitalizeFirstLetter(at: index)
                }
            }
            return changed
        }

        /// Drop the commas, semicolons and colons that close a word, so a full
        /// stop can take their place.
        private mutating func stripClosingPauses(at index: Int) {
            while let last = items[index].text.last, last == "," || last == ";" || last == ":" {
                items[index].text.removeLast()
            }
        }

        /// Uppercase the first scalar only, as the Rust port does, so a
        /// combining mark is never turned into a letter.
        private mutating func capitalizeFirstLetter(at index: Int) {
            let scalars = items[index].text.unicodeScalars
            guard let first = scalars.first, first.properties.isLowercase else { return }
            items[index].text = String(first).uppercased() + String(String.UnicodeScalarView(scalars.dropFirst()))
        }

        // MARK: Pass 4: paragraph commands

        mutating func applyParagraphCommands() -> Bool {
            var changed = false
            var index = 0
            while index < items.count {
                guard let length = paragraphCommandLength(at: index) else {
                    index += 1
                    continue
                }
                let last = index + length - 1
                let hasBefore = index > 0
                let hasAfter = last + 1 < items.count

                if hasBefore, !items[index - 1].isProtected, !endsSentence(at: index - 1) {
                    stripClosingPauses(at: index - 1)
                    items[index - 1].text += "."
                }
                remove(index...last)
                if hasBefore, hasAfter {
                    items[index].separator = "\n\n"
                }
                if index < items.count, !items[index].isProtected {
                    capitalizeFirstLetter(at: index)
                }
                changed = true
            }
            return changed
        }

        /// How many tokens a paragraph command starting at `index` spans, when
        /// punctuation sets it apart: "…point. New paragraph. Second…" is a
        /// command, "added a new paragraph about…" is a sentence.
        private func paragraphCommandLength(at index: Int) -> Int? {
            for command in CleanVerbatim.paragraphCommands {
                let last = index + command.count - 1
                guard last < items.count else { continue }
                let tokens = items[index...last]
                guard tokens.allSatisfy({ !$0.isProtected }),
                      tokens.map(\.word) == command,
                      tokens.dropLast().allSatisfy({ $0.punctuation.isEmpty })
                else { continue }
                let apartBefore = index == 0 || !items[index - 1].punctuation.isEmpty
                let apartAfter = last == items.count - 1 || !items[last].punctuation.isEmpty
                if apartBefore, apartAfter { return command.count }
            }
            return nil
        }

        // MARK: Pass 3: stutters

        /// A repeat across a comma with no hesitation between: "It, it
        /// crashes", "Can we, can we move", "I don't, I don't know". The second
        /// copy must run on into the sentence ("No, no, no." stays).
        mutating func collapseCommaRestarts() -> Bool {
            var changed = false
            var index = 0
            while index + 1 < items.count {
                guard items[index].endsWithComma, !isKept(items[index]),
                      let length = repeatedLength(endingAt: index, againAt: index + 1, acrossHesitation: false),
                      // "It, it crashes", "Honestly, we, we", "for the, for the one" —
                      // not "you and I, I think", nor the "no" of "Не, не надо".
                      opensSentence(at: index + 1 - length) || items[index - length].endsWithComma
                        || (length >= 2 && CleanVerbatim.commaStutterWords.contains(items[index].word)),
                      !(length == 1 && items[index].word == "не"),
                      items[index + length].punctuation.isEmpty,
                      !items[(index + 1)...(index + length)].contains(where: isKept)
                else {
                    index += 1
                    continue
                }
                let start = index + 1 - length
                let opener = opensSentence(at: start) && !items[start].startsLowercase
                remove(start...index)
                if opener, start < items.count, !items[start].isProtected { capitalizeFirstLetter(at: start) }
                changed = true
                index = start
            }
            return changed
        }

        mutating func collapseStutters() -> Bool {
            var changed = false
            var index = 1
            while index < items.count {
                let previous = items[index - 1]
                let current = items[index]
                guard isStutter(previous, current, at: index) else {
                    index += 1
                    continue
                }
                if previous.endsWithComma { items[index - 1].text.removeLast() }
                items[index - 1].text += current.punctuation
                items.remove(at: index)
                changed = true
            }
            return changed
        }

        private func isStutter(_ previous: Token, _ current: Token, at index: Int) -> Bool {
            guard !isKept(previous), !isKept(current), previous.word == current.word,
                  !current.separator.contains(where: \.isNewline)
            else { return false }
            let word = current.word
            // Laughter: "He he, that's funny", "He he he." — a run of "he" that
            // opens a sentence and ends with punctuation.
            if word == "he" {
                var first = index - 1, last = index
                while first > 0, items[first - 1].word == "he" { first -= 1 }
                while last + 1 < items.count, items[last].punctuation.isEmpty, items[last + 1].word == "he" { last += 1 }
                if opensSentence(at: first), !items[last].punctuation.isEmpty { return false }
            }
            // A different case in mid-sentence is a different word: "220 В в сети".
            if previous.startsUppercase != current.startsUppercase, !opensSentence(at: index - 1) { return false }
            // "i" is the capital pronoun only: Polish "i i" is "and i", and
            // after a name it is a numeral: "World War I I moved".
            if word == "i", !(previous.text.hasPrefix("I") && current.text.hasPrefix("I")) || followsAName(index - 1) {
                return false
            }
            // A spelled letter: "spelled A A R O N".
            let spelled = { (token: Token) in token.isSingleLetter && token.startsUppercase }
            if word.count == 1, current.startsUppercase,
               (index >= 2 && spelled(items[index - 2])) || (items.indices.contains(index + 1) && spelled(items[index + 1])) {
                return false
            }
            if previous.punctuation.isEmpty {
                if CleanVerbatim.runOnStutterWords.contains(word) {
                    return current.punctuation.isEmpty
                        && (!CleanVerbatim.englishStutterWords.contains(word) || readsAsEnglish)
                }
                return CleanVerbatim.stutterWords.contains(word)
            }
            guard previous.punctuation == "," else { return false }
            // "не, не" inside a sentence; opening one, "Не, не надо" says no.
            if CleanVerbatim.commaStutterWords.contains(word) || (word == "не" && !opensSentence(at: index - 1)) {
                return true
            }
            return opensSentence(at: index - 1) && CleanVerbatim.openingCommaStutterWords.contains(word)
        }
    }
}

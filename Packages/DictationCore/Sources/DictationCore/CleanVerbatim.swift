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
///    ("Dr. Smith"): when that guess is wrong a correction takes back too
///    little, never a sentence the person meant to keep.
/// 2. **Fillers.** Words that are hesitation and nothing else. "um", "э" and
///    "mmm" are words too (a German particle, the Portuguese "one", a Russian
///    letter, a date format), so they go only when punctuation sets them apart
///    on both sides. "um" also goes after a word in a take that reads as
///    English, and never from a take with German or Portuguese in it.
///    An all-caps token is an acronym; "uh huh" and "uh oh" are words. The
///    commas around a hesitation are the pause and go with it, unless it sits
///    in a list ("10, 20, um, 30"). Repeated until nothing changes, so a
///    hesitation that was hiding another one goes in the same pass.
/// 3. **Stutters.** A short function word said twice in a row, from a list of
///    words whose doubles are never grammatical ("the the", "я я", "I, I").
/// 4. **"New paragraph"** ("Новый абзац"), set apart by punctuation, becomes a
///    paragraph break — in prose apps only. In a terminal a newline can run a
///    command, so verbatim apps keep the words. Last, so a hesitation after the
///    command is already gone and cannot take the break with it.
///
/// Protected spans and every word the person's own dictionary wrote are never
/// touched. Text with nothing to remove comes back exactly as it went in, and a
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
        for _ in 0..<3 {
            guard tokens.removeFillers() else { break }
            unfilled = true
        }
        let unstuttered = tokens.collapseStutters()
        let broken = mode == .prose && tokens.applyParagraphCommands()
        guard corrected || unfilled || unstuttered || broken else { return text }
        if !spokenCorrections, tokens.items.isEmpty { return text }
        return tokens.rendered
    }

    /// Every word of every dictionary entry's written form, lowercased: what
    /// the person asked for is never a filler or a stutter.
    static func protectedWords(from replacements: [DictionaryReplacement]) -> Set<String> {
        Set(replacements.flatMap { $0.written.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) })
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
    static let guardedFillers: Set<String> = ["um", "э", "mmm", "ммм"]

    /// Hesitation words that are half of a two-word interjection: "uh huh"
    /// (yes), "uh oh", "mm hmm".
    static let interjectionHeads: Set<String> = ["uh", "uhm", "mm", "mmm", "hm", "hmm"]
    static let interjectionTails: Set<String> = ["huh", "oh", "hmm", "hm"]

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

    /// Words after which a comma is grammar, so the comma before a removed
    /// hesitation stays.
    static let commaGrammarWords: Set<String> = [
        "что", "чтобы", "но", "а", "который", "которая", "которое", "которые", "если", "когда",
        "потому", "which", "but",
    ]

    /// Short function words whose doubles are never grammatical. Words that do
    /// double for a reason — "is is", "it it", "you you", "in in", "on on",
    /// "so so", "that that", "had had", "my my", "да да", "это это" — are left
    /// out. "i" counts only as the capital pronoun: Polish "i i" is "and i".
    static let stutterWords: Set<String> = [
        "i", "the", "we", "he", "she", "they", "our", "your", "but", "of", "with",
        "я", "мы", "ты", "вы", "он", "она", "оно", "они", "и", "но",
        "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
    ]

    /// Doubles with a comma between them that are still stutters: "the, the".
    static let commaStutterWords: Set<String> = [
        "the", "our", "your", "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
    ]

    /// Pronouns that stutter with a comma when they open a sentence: "I, I think".
    static let openingCommaStutterWords: Set<String> = ["i", "we", "я", "мы"]

    /// Spoken corrections, as consecutive words.
    static let corrections: [[String]] = [["scratch", "that"]]

    /// Words people lead a correction with: "Sorry, scratch that". Before the
    /// command they do not stop it from opening the sentence. "ah" is here
    /// because the model writes a spoken "uh" that way.
    static let correctionLeadIns: Set<String> = [
        "ah", "oh", "okay", "ok", "so", "well", "sorry", "no", "actually", "wait", "oops",
    ]

    /// Spoken paragraph breaks, as consecutive words.
    static let paragraphCommands: [[String]] = [
        ["new", "paragraph"],
        ["новый", "абзац"],
    ]

    /// Titles whose full stop does not end a sentence: a name follows.
    static let titles: Set<String> = ["dr", "mr", "mrs", "ms", "prof"]

    static let trailingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "…"]
    static let sentenceEnding: Set<Character> = [".", "!", "?", "…"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]"]
}

// MARK: - Tokens

extension CleanVerbatim {
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

        /// An acronym: two or more letters, all capitals.
        var isShouting: Bool {
            let letters = text.filter(\.isLetter)
            return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
        }

        var isNumber: Bool {
            let stem = word
            return !stem.isEmpty && stem.allSatisfy({ $0.isNumber || $0 == "." })
                && stem.contains(where: \.isNumber)
        }

        /// Whether this token closes a sentence: a full stop, question mark,
        /// exclamation or ellipsis, possibly inside a closing quote or bracket.
        /// A title's full stop ("Dr.") is the one exception.
        var endsSentence: Bool {
            let unquoted = String(text.reversed().drop(while: { CleanVerbatim.closers.contains($0) }).reversed())
            guard let last = unquoted.last, CleanVerbatim.sentenceEnding.contains(last) else { return false }
            guard last == "." else { return true }
            let stem = String(unquoted.reversed().drop(while: { CleanVerbatim.trailingPunctuation.contains($0) }).reversed())
            return !CleanVerbatim.titles.contains(stem.lowercased())
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
                if characters[index].isWhitespace {
                    separator.append(characters[index])
                    index += 1
                    continue
                }
                var word = ""
                while index < characters.count, !characters[index].isWhitespace {
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

        /// Whether "um" is a word in this take: German or Portuguese in it.
        private var umIsAWord: Bool {
            items.contains { token in
                !token.isProtected && !token.isShouting
                    && (CleanVerbatim.umIsAWordMarkers.contains(token.word)
                        || token.text.lowercased().contains(where: { CleanVerbatim.umIsAWordLetters.contains($0) }))
            }
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
            if CleanVerbatim.fillers.contains(word) { return true }
            guard CleanVerbatim.guardedFillers.contains(word) else { return false }
            if word == "um", umIsAWord { return false }
            // A letter among letters: "а, о, у, э, ы".
            if let previous = self.word(at: index - 1), let next = self.word(at: index + 1),
               previous.count == 1, next.count == 1 {
                return false
            }
            // Hesitations in a row are one pause: "um uh, now".
            let carriesComma = token.endsWithComma
                || (token.punctuation.isEmpty && items.indices.contains(index + 1)
                    && !isKept(items[index + 1]) && CleanVerbatim.fillers.contains(items[index + 1].word)
                    && items[index + 1].endsWithComma)
            let apartBefore = index == 0 || items[index - 1].endsSentence || items[index - 1].endsWithComma
                || (word == "um" && readsAsEnglish)
            if carriesComma, apartBefore { return true }
            // A dangling one a trailing command left behind: "…it, um".
            return token.punctuation.isEmpty && index == items.count - 1 && index > 0
                && items[index - 1].endsWithComma
        }

        /// A hesitation, as far as a correction is concerned: any filler word,
        /// guarded or not, because it can only stand between words here.
        private func isAnyFillerWord(at index: Int) -> Bool {
            let token = items[index]
            guard !isKept(token) else { return false }
            return CleanVerbatim.fillers.contains(token.word) || CleanVerbatim.guardedFillers.contains(token.word)
        }

        /// Whether the comma before a hesitation at `index` is grammar: the
        /// hesitation sits in a list, or the next word needs the comma.
        private func commaBeforeIsGrammar(at index: Int) -> Bool {
            if index >= 2, items[index - 2].endsWithComma,
               !CleanVerbatim.commaGrammarWords.contains(items[index - 1].word) {
                return true
            }
            if index >= 1, index + 1 < items.count, items[index - 1].isNumber, items[index + 1].isNumber { return true }
            if let next = word(at: index + 1), CleanVerbatim.commaGrammarWords.contains(next) { return true }
            return false
        }

        // MARK: Pass 1: corrections

        private var sentences: [ClosedRange<Int>] {
            var result: [ClosedRange<Int>] = []
            var start = 0
            for index in items.indices where items[index].endsSentence || index == items.count - 1 {
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
                remove(range)
                changed = true
                // Every removal starts at a sentence start, so whatever is
                // left there now opens a sentence.
                if range.lowerBound < items.count, !items[range.lowerBound].isProtected {
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
                        let opens = spoken[..<offset].allSatisfy { CleanVerbatim.correctionLeadIns.contains($0) }
                        let closes = offset + command.count == spoken.count
                        let pauseBefore = first > sentence.lowerBound
                            && (items[first - 1].endsWithComma || isAnyFillerWord(at: first - 1))
                        let pauseAfter = items[last].endsWithComma

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
            var candidate = position - 1
            while candidate >= 0, sentences[candidate].allSatisfy({ isAnyFillerWord(at: $0) }) {
                candidate -= 1
            }
            if candidate >= 0 { return sentences[candidate].lowerBound }
            return sentences[0].lowerBound
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
                let filler = items[index]
                let terminal = String(filler.punctuation.filter { CleanVerbatim.sentenceEnding.contains($0) })
                let startsSentence = index == 0 || items[index - 1].endsSentence
                let isLast = index == items.count - 1

                var removal = index...index
                if index > 0, !items[index - 1].isProtected {
                    let previous = index - 1
                    if !terminal.isEmpty {
                        if !items[previous].endsSentence {
                            stripClosingPauses(at: previous)
                            items[previous].text += terminal
                        }
                    } else if items[previous].endsWithComma,
                              isLast || (filler.endsWithComma && !commaBeforeIsGrammar(at: index)) {
                        // The commas around a hesitation mark the pause.
                        items[previous].text.removeLast()
                        if items[previous].text.isEmpty { removal = previous...index }
                    }
                } else if index > 0, !terminal.isEmpty, !items[index - 1].endsSentence {
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

        private mutating func capitalizeFirstLetter(at index: Int) {
            guard let first = items[index].text.first, first.isLowercase else { return }
            items[index].text = String(first).uppercased() + items[index].text.dropFirst()
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

                if hasBefore, !items[index - 1].isProtected, !items[index - 1].endsSentence {
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
            // "i" is the capital pronoun only: Polish "i i" is "and i".
            if word == "i", !(previous.text.hasPrefix("I") && current.text.hasPrefix("I")) { return false }
            if previous.punctuation.isEmpty { return CleanVerbatim.stutterWords.contains(word) }
            guard previous.punctuation == "," else { return false }
            if CleanVerbatim.commaStutterWords.contains(word) { return true }
            let opensSentence = index - 1 == 0 || items[index - 2].endsSentence
            return opensSentence && CleanVerbatim.openingCommaStutterWords.contains(word)
        }
    }
}

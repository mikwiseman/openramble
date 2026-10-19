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
/// A false deletion is the worse failure, so every rule leans towards keeping.
/// The rules below were shaped by an adversarial review that tried to make the
/// stage delete something real — German separable verbs, the Portuguese "one",
/// millimetres, acronyms, grammatical doubles — and each of those is a test.
///
/// Three passes, in this order:
///
/// 1. **Spoken corrections.** "Scratch that" takes back what was just said: as
///    its own sentence or opening one, the sentence before it; at the end of a
///    sentence, or between commas in the middle of one ("we go Friday, scratch
///    that, we go Monday"), everything before it in that sentence. The commas
///    are what make it a command rather than the verb. English only: the
///    Russian "зачеркни" is far more often an instruction to a reader. Runs
///    first because it reads the commas the filler pass removes.
/// 2. **Fillers.** Words that are hesitation and nothing else. "um" and "э" are
///    words too (a German particle, the Portuguese "one", a Russian letter), so
///    they go only when they carry a comma of their own — and "um" never in a
///    take with German or Portuguese in it. An all-caps token is an acronym,
///    never a hesitation. The comma before a hesitation stays: it may be
///    grammar ("10, 20, um, 30").
/// 3. **Stutters.** A short function word said twice in a row with nothing
///    between, from a list of words whose doubles are never grammatical.
///
/// Protected spans are atomic: a span is never a filler, a stutter or a
/// command, and its text is never edited. Text with nothing to remove comes
/// back exactly as it went in, whitespace included, and a line break survives
/// the removal of whatever followed it.
///
/// Spoken corrections are a dictation command. A meeting transcript turns them
/// off: there "scratch that" is something a person said, and the sentence
/// before it may be someone else's. For the same reason a meeting keeps a turn
/// that is nothing but an interjection.
enum CleanVerbatim {
    static func clean(_ text: String, spokenCorrections: Bool = true) -> String {
        var tokens = Tokens(text)
        guard !tokens.items.isEmpty else { return text }

        let corrected = spokenCorrections && tokens.removeCorrections()
        let unfilled = tokens.removeFillers()
        let unstuttered = tokens.collapseStutters()
        guard corrected || unfilled || unstuttered else { return text }
        if !spokenCorrections, tokens.items.isEmpty { return text }
        return tokens.rendered
    }

    // MARK: - Vocabulary

    /// Hesitation in every language Parakeet speaks: none of these is a word.
    static let fillers: Set<String> = [
        "uh", "uhh", "uhm", "umm", "erm", "hmm", "hm", "mmm",
        "ээ", "эээ", "эмм", "ммм",
        "äh", "ähm", "euh",
    ]

    /// Hesitations that are also words: "um" (a German particle, the
    /// Portuguese "one") and "э" (a Russian letter). Removed only when they
    /// carry a comma of their own.
    static let guardedFillers: Set<String> = ["um", "э"]

    /// Words that mark a take as German or Portuguese, where "um" is a word.
    static let umIsAWordMarkers: Set<String> = [
        "der", "die", "das", "und", "ist", "nicht", "ich", "wir", "sich", "auch",
        "ein", "eine", "mit", "es", "geht", "dann",
        "não", "você", "uma", "eu", "quero", "também", "são", "dois", "três", "quatro",
    ]

    /// Letters that only German or Portuguese write, among the languages here.
    static let umIsAWordLetters: Set<Character> = ["ä", "ö", "ü", "ß", "ã", "õ", "ç"]

    /// Short function words whose doubles are never grammatical. Words that do
    /// double for a reason — "is is", "was was", "in in", "on on", "for for",
    /// "so so", "that that", "had had", "да да", "это это" — are left out.
    static let stutterWords: Set<String> = [
        "i", "the", "we", "you", "he", "she", "they", "my", "our", "your", "but",
        "of", "it", "with",
        "я", "мы", "ты", "вы", "он", "она", "оно", "они", "и", "но",
        "в", "на", "с", "к", "у", "по", "за", "из", "от", "до",
    ]

    /// Spoken corrections, as consecutive words.
    static let corrections: [[String]] = [["scratch", "that"]]

    /// Words whose full stop does not end a sentence.
    static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "st", "vs", "etc", "inc", "ltd", "jr", "sr",
        "no", "prof", "mt", "fig",
    ]

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

        /// Whether this token closes a sentence: a full stop, question mark,
        /// exclamation or ellipsis, possibly inside a closing quote or bracket,
        /// and not the full stop of an abbreviation ("Dr.", "p.m.", "J.").
        var endsSentence: Bool {
            let unquoted = String(text.reversed().drop(while: { CleanVerbatim.closers.contains($0) }).reversed())
            guard let last = unquoted.last, CleanVerbatim.sentenceEnding.contains(last) else { return false }
            guard last == "." else { return true }
            let stem = String(unquoted.reversed().drop(while: { CleanVerbatim.trailingPunctuation.contains($0) }).reversed())
            if stem.contains(".") || stem.count == 1 { return false }
            return !CleanVerbatim.abbreviations.contains(stem.lowercased())
        }
    }

    struct Tokens {
        var items: [Token] = []
        var trailing = ""

        init(_ text: String) {
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
                items.append(Token(separator: separator, text: word, isProtected: false))
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
            if range.lowerBound == 0 || (leading.contains("\n") && !next.contains("\n")) {
                items[range.lowerBound].separator = leading
            }
        }

        /// Whether "um" is a word in this take: German or Portuguese in it.
        private var umIsAWord: Bool {
            items.contains { token in
                !token.isProtected && (CleanVerbatim.umIsAWordMarkers.contains(token.word)
                    || token.text.lowercased().contains(where: { CleanVerbatim.umIsAWordLetters.contains($0) }))
            }
        }

        private func isFiller(at index: Int, umIsAWord: Bool) -> Bool {
            let token = items[index]
            guard !token.isProtected, !token.isShouting else { return false }
            let word = token.word
            if CleanVerbatim.fillers.contains(word) { return true }
            guard CleanVerbatim.guardedFillers.contains(word) else { return false }
            if word == "um", umIsAWord { return false }
            if token.endsWithComma { return true }
            // A dangling "um" a trailing command left behind: "…it, um".
            return token.punctuation.isEmpty && index == items.count - 1 && index > 0
                && items[index - 1].endsWithComma
        }

        /// A hesitation, as far as a correction is concerned: any filler word,
        /// guarded or not, because it can only stand between words here.
        private func isAnyFillerWord(at index: Int) -> Bool {
            let token = items[index]
            guard !token.isProtected, !token.isShouting else { return false }
            return CleanVerbatim.fillers.contains(token.word) || CleanVerbatim.guardedFillers.contains(token.word)
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

                for command in CleanVerbatim.corrections {
                    guard let offset = firstOccurrence(of: command, in: spoken) else { continue }
                    let first = words[offset]
                    let last = words[offset + command.count - 1]
                    let opens = offset == 0
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

        private func firstOccurrence(of command: [String], in spoken: [String]) -> Int? {
            guard spoken.count >= command.count else { return nil }
            return (0...(spoken.count - command.count)).first {
                Array(spoken[$0..<($0 + command.count)]) == command
            }
        }

        // MARK: Pass 2: fillers

        mutating func removeFillers() -> Bool {
            let umIsAWord = umIsAWord
            var changed = false
            var index = 0
            while index < items.count {
                guard isFiller(at: index, umIsAWord: umIsAWord) else {
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
                    } else if isLast, items[previous].endsWithComma {
                        // Nothing follows the comma any more.
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

        // MARK: Pass 3: stutters

        mutating func collapseStutters() -> Bool {
            var changed = false
            var index = 1
            while index < items.count {
                let previous = items[index - 1]
                let current = items[index]
                guard !previous.isProtected, !current.isProtected,
                      !previous.isShouting, !current.isShouting,
                      previous.punctuation.isEmpty,
                      previous.word == current.word, CleanVerbatim.stutterWords.contains(current.word)
                else {
                    index += 1
                    continue
                }
                items[index - 1].text += current.punctuation
                items.remove(at: index)
                changed = true
            }
            return changed
        }
    }
}

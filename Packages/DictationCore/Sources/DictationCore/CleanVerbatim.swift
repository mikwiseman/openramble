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
/// Three passes, in this order:
///
/// 1. **Spoken corrections.** "Scratch that." ("Зачеркни это.") as its own
///    sentence removes the sentence before it; ", scratch that." at the end of
///    a sentence removes that sentence. Runs first because it reads the commas
///    the filler pass would otherwise take away.
/// 2. **Fillers.** Words that are hesitation in every language the model
///    speaks. "um" is a real word in German and Portuguese, so it goes only
///    when punctuation sets it apart.
/// 3. **Stutters.** A short function word said twice in a row with nothing
///    between. Doubles that mean something ("very very", "да да", "had had")
///    are not on the list.
///
/// Protected spans are atomic: a span is never a filler, a stutter or a
/// command, and its text is never edited. Text with nothing to remove comes
/// back exactly as it went in, whitespace included.
///
/// Spoken corrections are a dictation command. A meeting transcript turns them
/// off: there "scratch that" is something a person said, and the sentence
/// before it may be someone else's.
enum CleanVerbatim {
    static func clean(_ text: String, spokenCorrections: Bool = true) -> String {
        var tokens = Tokens(text)
        guard !tokens.items.isEmpty else { return text }

        let corrected = spokenCorrections && tokens.removeCorrections()
        let unfilled = tokens.removeFillers()
        let unstuttered = tokens.collapseStutters()
        guard corrected || unfilled || unstuttered else { return text }
        return tokens.rendered
    }

    // MARK: - Vocabulary

    /// Hesitation in every language Parakeet speaks: none of these is a word.
    static let fillers: Set<String> = [
        "uh", "uhh", "uhm", "umm", "erm", "hmm", "hm", "mm", "mmm",
        "э", "ээ", "эээ", "эм", "эмм", "мм", "ммм",
        "äh", "ähm", "euh",
    ]

    /// A hesitation in English, a word in German ("um fünf") and Portuguese
    /// ("um carro"). Removed only when punctuation sets it apart.
    static let guardedFiller = "um"

    /// Short function words a speaker repeats while the next word loads.
    static let stutterWords: Set<String> = [
        "i", "a", "an", "the", "to", "and", "of", "in", "on", "it", "is", "we", "you",
        "he", "she", "they", "so", "but", "my", "our", "your", "for", "with", "at",
        "be", "was", "if", "or",
        "я", "и", "в", "во", "на", "не", "мы", "ты", "вы", "он", "она", "оно", "они",
        "это", "а", "но", "с", "к", "у", "по", "за", "из", "от", "до", "о",
    ]

    /// Spoken corrections, as the words of a whole sentence.
    static let corrections: [[String]] = [
        ["scratch", "that"],
        ["зачеркни", "это"],
        ["зачеркни"],
    ]

    static let trailingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "…"]
    static let sentenceEnding: Set<Character> = [".", "!", "?", "…"]
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

        var endsSentence: Bool { punctuation.contains(where: { CleanVerbatim.sentenceEnding.contains($0) }) }
        var endsWithComma: Bool { text.last == "," }
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

        /// Remove `range`, keeping the text's leading whitespace where it was.
        mutating func remove(_ range: ClosedRange<Int>) {
            let leading = items[range.lowerBound].separator
            items.removeSubrange(range)
            if range.lowerBound == 0, !items.isEmpty {
                items[0].separator = leading
            }
        }

        private func isFiller(at index: Int) -> Bool {
            let token = items[index]
            guard !token.isProtected else { return false }
            let word = token.word
            if CleanVerbatim.fillers.contains(word) { return true }
            guard word == CleanVerbatim.guardedFiller, !token.punctuation.isEmpty else { return false }
            return index == 0 || !items[index - 1].punctuation.isEmpty
        }

        /// A filler, as far as a correction is concerned: any hesitation word,
        /// guarded or not, because it can only stand between words here.
        private func isAnyFillerWord(at index: Int) -> Bool {
            let token = items[index]
            guard !token.isProtected else { return false }
            return CleanVerbatim.fillers.contains(token.word) || token.word == CleanVerbatim.guardedFiller
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
                    if spoken == command {
                        let start = position > 0 ? sentences[position - 1].lowerBound : sentence.lowerBound
                        return start...sentence.upperBound
                    }
                    // As a sentence's tail only the two-word forms count: a bare
                    // "зачеркни" after a comma is as likely an instruction to a reader.
                    guard command.count > 1, spoken.count > command.count,
                          Array(spoken.suffix(command.count)) == command
                    else { continue }
                    let commandStart = words[words.count - command.count]
                    if commandStart > sentence.lowerBound, items[commandStart - 1].endsWithComma {
                        return sentence
                    }
                }
            }
            return nil
        }

        // MARK: Pass 2: fillers

        mutating func removeFillers() -> Bool {
            var changed = false
            var index = 0
            while index < items.count {
                guard isFiller(at: index) else {
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
                              filler.endsWithComma || isLast {
                        // The commas around a hesitation mark the pause, not the grammar.
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
                guard !previous.isProtected, !current.isProtected, previous.punctuation.isEmpty,
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

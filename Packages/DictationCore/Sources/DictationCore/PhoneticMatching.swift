import Foundation

/// Phonetic key of the Russian word.
///
/// Exists because a flat spelling table does not work in principle:
/// The spelling of the term depends on the phrase in which it was used. One word
/// “deploy”, said in one voice, the model writes as “diploy”, “depla”,
/// “deplay”, “display” - and the next phrase will have a fifth spelling. Key
/// collapses exactly those differences that Russian phonetics does not distinguish anyway,
/// and leaves everything else.
///
/// What is collapsed:
///
/// - **unstressed vowels**: “o” sounds like “a”, “e”/“e”/“i”/“s” merge,
/// “yu” is like “y”. Hence “diploy” = “deploy”, “backend” = “backend”,
/// “kamit” = “komit”, “morg” = “merge”;
/// - **paired consonants in voicing - only where Russian really doesn’t have them
/// distinguishes**: at the end of a word and before another noisy word. Hence “rebase” =
/// “rebase” and “frontend” = “frontend”;
/// - **double**: "commit" = "commit", "Rillis" = "relis".
///
/// What does NOT collapse, and this is the main thing:
///
/// - **the last letter, if it is a vowel.** The case ending lives in it, and
/// to collapse it means to declare “center” and “center” in one word - that is
/// turn “in the city center” into “in the Sentry city”;
/// - **voicing at the beginning of a word and between vowels.** Russian there is nothing there
/// stuns, and collapsing turns “warm” into “warm”, “concrete” and
/// “can” in “python”, “leaked” in “production”. Stuck on the same thing
/// set: with collapsing, 161 real ones fall under replacement
/// Russian word, with a positional one - 70, but the winnings are exactly the same;
/// - **soft and hard sign.** “Gum” ≠ “comets”, “review” ≠ “review”.
///
/// The damage radius is measured by brute force, not by body: for each entry
/// all spellings with the same key are built, and the system spell checker
/// selects real Russian words from them. The supplied set still has them.
/// 31, and every single one of them is the terms themselves, which have taken root in Russian (“release”, “build”,
/// “PR”, “review”, “production”). There is no ordinary speech among them.
enum PhoneticKey {
    /// Vowels and what they collapse into.
    ///
    /// “I” is left to itself: its reduction depends on the softness of its neighbor, and without
    /// it’s impossible to guess the accents.
    private static let vowels: [Character: Character] = [
        "\u{0430}": "\u{0430}", "\u{043E}": "\u{0430}", "\u{0451}": "\u{0430}",
        "\u{0435}": "\u{0435}", "\u{0438}": "\u{0435}", "\u{044D}": "\u{0435}", "\u{044B}": "\u{0435}",
        "\u{0443}": "\u{0443}", "\u{044E}": "\u{0443}",
        "\u{044F}": "\u{044F}",
    ]

    /// Paired by voicing - to the deaf.
    private static let paired: [Character: Character] = [
        "\u{0431}": "\u{043F}", "\u{043F}": "\u{043F}",
        "\u{0432}": "\u{0444}", "\u{0444}": "\u{0444}",
        "\u{0433}": "\u{043A}", "\u{043A}": "\u{043A}",
        "\u{0434}": "\u{0442}", "\u{0442}": "\u{0442}",
        "\u{0436}": "\u{0448}", "\u{0448}": "\u{0448}",
        "\u{0437}": "\u{0441}", "\u{0441}": "\u{0441}",
    ]

    /// Noisy: before them, assimilation in terms of sonority occurs.
    private static let obstruents: Set<Character> = [
        "\u{0431}", "\u{043F}", "\u{0432}", "\u{0444}", "\u{0433}", "\u{043A}", "\u{0434}", "\u{0442}", "\u{0436}", "\u{0448}", "\u{0437}", "\u{0441}", "\u{0445}", "\u{0446}", "\u{0447}", "\u{0449}",
    ]

    static func of(_ word: String) -> String {
        let lowered = word.lowercased()
        var squeezed: [Character] = []
        for character in lowered where squeezed.last != character {
            squeezed.append(character)
        }

        var key = ""
        key.reserveCapacity(squeezed.count)
        for (offset, character) in squeezed.enumerated() {
            let isLast = offset == squeezed.count - 1

            if let folded = vowels[character] {
                key.append(isLast ? character : folded)
                continue
            }

            if let devoiced = paired[character] {
                let neutralised = isLast || obstruents.contains(squeezed[offset + 1])
                if neutralised {
                    key.append(devoiced)
                    continue
                }
            }

            key.append(character)
        }
        return key
    }
}

/// Second pass of the dictionary: a term written differently than in the dictionary.
///
/// Works only on Cyrillic words and only on those to which the exact
/// the coincidence did not reach: the Latin alphabet by this moment had already been inserted and under
/// parsing fails.
enum PhoneticMatching {
    /// We don’t take a phonetic key shorter than five letters.
    ///
    /// Short words have too much ordinary speech per key:
    /// “api”, up to unstressed vowels, coincides with “epi”, “opa”, “upa”.
    /// Five is not a round number, but a limit below which the measurement began
    /// come across ordinary words.
    static let minimumLetters = 5

    /// How many words in a row one term can occupy.
    ///
    /// The model either glues the term into one word, then breaks it into two: “down”
    /// time" and "downtime", "java script" and "javasscript", "end point" and
    /// "endpoint". The window closes both entries with one check.
    private static let maximumWindow = 3

    private struct Index {
        /// Record key → how to write.
        var exact: [String: String] = [:]
        /// The same, but only for records that are declined.
        var inflected: [String: String] = [:]
    }

    static func apply(_ replacements: [DictionaryReplacement], to text: String) -> String {
        apply(replacements, to: text, protecting: [])
    }

    /// Phonetic selection that bypasses protected spans.
    ///
    /// Two separate protections, both needed. The first is that the word inside the span is not
    /// gets into the list of candidates. Second, a three-word window has no right
    /// step over span: otherwise “sentry” to the left and “sentry” to the right of the path
    /// would be glued together into one term through a protected piece.
    ///
    /// The empty set of spans goes through exactly the same code as before: filter
    /// becomes identical, there are no breaks, the window limit does not change.
    static func apply(
        _ replacements: [DictionaryReplacement],
        to text: String,
        protecting spans: [ProtectedSpan]
    ) -> String {
        let index = makeIndex(replacements)
        guard !index.exact.isEmpty, !text.isEmpty else { return text }

        let protectedRanges = indexRanges(of: spans, in: text)
        let words = wordRanges(in: text).filter { word in
            !protectedRanges.contains { $0.overlaps(word) }
        }
        guard !words.isEmpty else { return text }

        // Before which word the window must break: between it and the previous one
        // there is a protected piece.
        var breaksBefore = Set<Int>()
        if !protectedRanges.isEmpty {
            for position in 1..<words.count {
                let gap = words[position - 1].upperBound..<words[position].lowerBound
                if protectedRanges.contains(where: { $0.overlaps(gap) }) {
                    breaksBefore.insert(position)
                }
            }
        }

        var result = ""
        var cursor = text.startIndex
        var start = 0

        while start < words.count {
            var matched = false
            var size = min(maximumWindow, words.count - start)
            // Shorten the window to the nearest break.
            for offset in 1..<max(size, 1) where breaksBefore.contains(start + offset) {
                size = offset
                break
            }

            while size >= 1 {
                let window = Array(words[start..<(start + size)])
                if let written = lookup(window, in: text, index: index) {
                    result.append(contentsOf: text[cursor..<window[0].lowerBound])
                    result.append(written)
                    cursor = window[size - 1].upperBound
                    start += size
                    matched = true
                    break
                }
                size -= 1
            }

            if !matched { start += 1 }
        }

        result.append(contentsOf: text[cursor...])
        return result
    }

    /// Character offsets of spans → ranges of the line to which they are calculated.
    private static func indexRanges(
        of spans: [ProtectedSpan],
        in text: String
    ) -> [Range<String.Index>] {
        guard !spans.isEmpty else { return [] }
        let count = text.count
        return spans.compactMap { span in
            guard span.range.lowerBound >= 0, span.range.upperBound <= count else { return nil }
            let lower = text.index(text.startIndex, offsetBy: span.range.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: span.range.upperBound)
            return lower..<upper
        }
    }

    // MARK: - What to look for

    private static func makeIndex(_ replacements: [DictionaryReplacement]) -> Index {
        var index = Index()
        var ambiguous: Set<String> = []
        var ambiguousInflected: Set<String> = []

        for replacement in replacements {
            let spoken = replacement.spoken.trimmingCharacters(in: .whitespaces)
            // The empty right side is a way to cross out a filler word. Accurate
            // coincidence is capable of this, phonetic selection is not: deletion is not possible
            // visible in the text, and a person will not notice the mistake here at all.
            guard !replacement.written.isEmpty else { continue }

            let letters = compacted(spoken)
            guard letters.count >= minimumLetters, isCyrillic(letters) else { continue }

            let key = PhoneticKey.of(letters)
            if let existing = index.exact[key], existing != replacement.written {
                ambiguous.insert(key)
            }
            index.exact[key] = replacement.written

            guard replacement.inflects else { continue }
            if let existing = index.inflected[key], existing != replacement.written {
                ambiguousInflected.insert(key)
            }
            index.inflected[key] = replacement.written
        }

        // One key for two different terms is not a choice, but a guess.
        for key in ambiguous { index.exact.removeValue(forKey: key) }
        for key in ambiguousInflected { index.inflected.removeValue(forKey: key) }
        return index
    }

    // MARK: - Text parsing

    /// Words of the text. The number next to the letters makes the word different: “api2” is not “api”.
    private static let wordExpression = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}])\\p{L}+(?:-\\p{L}+)*(?![\\p{L}\\p{N}])"
    )

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        guard let expression = wordExpression else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: whole).compactMap {
            Range($0.range, in: text)
        }
    }

    /// How to write these words if they are actually a term.
    private static func lookup(
        _ window: [Range<String.Index>],
        in text: String,
        index: Index
    ) -> String? {
        // The words of the window must be in a row separated by spaces: “end, point” are two
        // different places of the phrase, not a broken term.
        for pair in zip(window, window.dropFirst()) {
            let gap = text[pair.0.upperBound..<pair.1.lowerBound]
            guard !gap.isEmpty, gap.allSatisfy({ $0 == " " }) else { return nil }
        }

        let parts = window.map { compacted(String(text[$0])) }
        guard parts.allSatisfy({ isCyrillic($0) && !$0.isEmpty }) else { return nil }

        let head = parts.dropLast().joined()
        guard let tail = parts.last else { return nil }

        let whole = head + tail
        if whole.count >= minimumLetters, let written = index.exact[PhoneticKey.of(whole)] {
            return written
        }

        for stem in stems(of: tail) {
            let candidate = head + stem
            guard candidate.count >= minimumLetters else { continue }
            if let written = index.inflected[PhoneticKey.of(candidate)] {
                return written
            }
        }
        return nil
    }

    /// The basics of the word after cutting off the case tail.
    ///
    /// The list of tails is the same closed as that of an exact match, and the “th”
    /// returns to its place for the same reason: “deploy” is “deploy” + “yu”,
    /// and the term itself ends in “th”.
    private static func stems(of word: String) -> [String] {
        var found: [String] = []
        for ending in inflectionEndings where word.hasSuffix(ending) {
            let stem = String(word.dropLast(ending.count))
            guard stem.count >= 3 else { continue }
            found.append(stem)
            found.append(stem + "\u{0439}")
        }
        return found
    }

    private static let inflectionEndings = [
        "\u{0430}\u{043C}\u{0438}", "\u{044F}\u{043C}\u{0438}", "\u{043E}\u{0439}", "\u{0435}\u{0439}", "\u{043E}\u{043C}", "\u{0435}\u{043C}", "\u{043E}\u{0432}", "\u{0435}\u{0432}", "\u{0430}\u{043C}", "\u{044F}\u{043C}", "\u{0430}\u{0445}", "\u{044F}\u{0445}",
        "\u{0430}", "\u{0435}", "\u{0438}", "\u{044B}", "\u{0443}", "\u{044E}", "\u{044F}",
    ]

    // MARK: - Little things

    /// A word without spaces or hyphens: they are optional for the term.
    private static func compacted(_ text: String) -> String {
        text.filter { $0 != " " && $0 != "-" }.lowercased()
    }

    /// Latin substitutions are not subject to phonetic analysis: the rules are Russian.
    private static func isCyrillic(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }
}

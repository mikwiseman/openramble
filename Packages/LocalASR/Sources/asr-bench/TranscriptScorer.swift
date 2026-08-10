import Foundation

/// Parsing text into words and punctuation marks.
///
/// Signs **are not thrown away**: they are separated into separate tokens and counted
/// separately. This is fundamental - silently erasing punctuation means declaring it
/// free, and in dictation it is half the work.
struct NormalizedText {
    /// Words without punctuation, numerals are reduced to numbers.
    let words: [String]
    /// Words and signs are mixed, in the original order.
    let tokens: [String]
    /// Punctuation marks only, in original order.
    let marks: [String]

    var text: String { words.joined(separator: " ") }
    /// Character string for CER: words separated by spaces, without signs.
    var characters: [Character] { Array(text) }
}

enum TextNormalizer {
    /// Characters that are evaluated separately from words.
    static let punctuation: Set<Character> = [
        ".", ",", "!", "?", ":", ";", "—", "–", "…", "«", "»", "\"", "(", ")", "-",
    ]

    /// Symbols that the model puts in place of the word: “75%” instead of “75 percent”.
    /// Separated from the word so that the number does not stick together with the symbol, but in the evaluation
    /// punctuations don't fit - these are not punctuation marks.
    static let symbols: Set<Character> = ["%", "$", "€", "₽", "№", "+", "=", "/", "*", "#"]

    static var separators: Set<Character> { punctuation.union(symbols) }

    /// Bring the text to a comparable form.
    ///
    /// What is being done - and all this is visible in the report, nothing happens silently:
    /// 1. case is reduced to lower case;
    /// 2. the Russian yo letter is reduced to the corresponding ye letter because
    /// synthesis and the model frequently diverge here without changing meaning;
    /// but the difference does not change the meaning;
    /// 3. punctuation marks are separated from words into their own tokens;
    /// 4. numerals are collapsed to digits (see `NumeralFolder`).
    static func normalize(_ text: String) -> NormalizedText {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "\u{0451}", with: "\u{0435}")
            .replacingOccurrences(of: "\u{2019}", with: "'")

        var tokens: [String] = []
        var current = ""
        let characters = Array(lowered)
        let separators = self.separators

        func flushWord() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for (index, character) in characters.enumerated() {
            if character.isWhitespace || character.isNewline {
                flushWord()
                continue
            }
            if separators.contains(character) {
                // A hyphen and an apostrophe inside a word is part of the word: “type script”,
                // "don't". The same symbol between spaces is a punctuation mark.
                let neighbours = index > 0 && index + 1 < characters.count
                let isInnerWord = (character == "-" || character == "'")
                    && neighbours
                    && (characters[index - 1].isLetter || characters[index - 1].isNumber)
                    && characters[index + 1].isLetter
                // Fractional separator - part of the number: “3.5”, “2.01”.
                let isInnerNumber = (character == "." || character == ",")
                    && neighbours
                    && characters[index - 1].isNumber
                    && characters[index + 1].isNumber
                let isInner = isInnerWord || isInnerNumber
                if isInner {
                    current.append(character)
                    continue
                }
                flushWord()
                tokens.append(String(character))
                continue
            }
            current.append(character)
        }
        flushWord()

        func isSeparator(_ token: String) -> Bool {
            token.count == 1 && separators.contains(token.first!)
        }

        let marks = tokens.filter { $0.count == 1 && punctuation.contains($0.first!) }
        let words = NumeralFolder.fold(tokens.filter { !isSeparator($0) })

        // The numbers are collapsed in the general flow of tokens, otherwise there are two metrics
        // would count different things.
        var folded: [String] = []
        var buffer: [String] = []
        for token in tokens {
            if isSeparator(token) {
                folded.append(contentsOf: NumeralFolder.fold(buffer))
                buffer.removeAll()
                folded.append(token)
            } else {
                buffer.append(token)
            }
        }
        folded.append(contentsOf: NumeralFolder.fold(buffer))

        return NormalizedText(words: words, tokens: folded, marks: marks)
    }
}

/// The result of comparing one record with a standard.
struct ScoreReport {
    struct Counts {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var correct = 0

        var errors: Int { substitutions + deletions + insertions }
        var referenceLength: Int { substitutions + deletions + correct }
        /// Proportion of errors. If the reference is empty, any insertion is considered an error.
        var rate: Double {
            let base = referenceLength
            guard base > 0 else { return insertions > 0 ? 1 : 0 }
            return Double(errors) / Double(base)
        }
    }

    /// Words without punctuation.
    let words: Counts
    /// Words along with punctuation marks - the price of punctuation is visible as the difference.
    let wordsWithPunctuation: Counts
    /// Proportion of character errors for words without signs.
    let characterErrorRate: Double
    /// Punctuation marks only.
    let punctuation: Counts

    let reference: NormalizedText
    let hypothesis: NormalizedText
    /// Discrepancies in words, for reading with the eyes.
    let differences: [Difference]

    enum Difference {
        case substitution(reference: String, hypothesis: String)
        case deletion(String)
        case insertion(String)

        var description: String {
            switch self {
            case let .substitution(reference, hypothesis): return "«\(reference)» → «\(hypothesis)»"
            case let .deletion(word): return "Missing: \(word)"
            case let .insertion(word): return "Extra: \(word)"
            }
        }
    }
}

enum TranscriptScorer {
    static func score(reference: String, hypothesis: String) -> ScoreReport {
        let referenceText = TextNormalizer.normalize(reference)
        let hypothesisText = TextNormalizer.normalize(hypothesis)

        let (wordCounts, differences) = align(referenceText.words, hypothesisText.words)
        let (tokenCounts, _) = align(referenceText.tokens, hypothesisText.tokens)
        let (markCounts, _) = align(referenceText.marks, hypothesisText.marks)

        let referenceCharacters = referenceText.characters
        let characterDistance = distance(referenceCharacters, hypothesisText.characters)
        let characterErrorRate: Double
        if referenceCharacters.isEmpty {
            characterErrorRate = characterDistance > 0 ? 1 : 0
        } else {
            characterErrorRate = Double(characterDistance) / Double(referenceCharacters.count)
        }

        return ScoreReport(
            words: wordCounts,
            wordsWithPunctuation: tokenCounts,
            characterErrorRate: characterErrorRate,
            punctuation: markCounts,
            reference: referenceText,
            hypothesis: hypothesisText,
            differences: differences
        )
    }

    /// Levenshtein distance with path restoration.
    ///
    /// The path is stored in a separate matrix of byte-per-cell operations: on
    /// a half-hour recording is about five thousand words in each line, that is
    /// twenty-five megabytes is tolerable. The path is not restored for symbols
    /// (see `distance`): there the same matrix would weigh gigabytes.
    static func align(_ reference: [String], _ hypothesis: [String]) -> (ScoreReport.Counts, [ScoreReport.Difference]) {
        let rows = reference.count
        let columns = hypothesis.count

        if rows == 0 {
            var counts = ScoreReport.Counts()
            counts.insertions = columns
            return (counts, hypothesis.map { .insertion($0) })
        }
        if columns == 0 {
            var counts = ScoreReport.Counts()
            counts.deletions = rows
            return (counts, reference.map { .deletion($0) })
        }

        let match: UInt8 = 0, substitute: UInt8 = 1, delete: UInt8 = 2, insert: UInt8 = 3
        let width = columns + 1
        var operations = [UInt8](repeating: insert, count: (rows + 1) * width)
        for row in 1...rows { operations[row * width] = delete }

        var previous = Array(0...columns)
        var current = [Int](repeating: 0, count: width)

        for row in 1...rows {
            current[0] = row
            for column in 1...columns {
                let same = reference[row - 1] == hypothesis[column - 1]
                let diagonal = previous[column - 1] + (same ? 0 : 1)
                let deletion = previous[column] + 1
                let insertion = current[column - 1] + 1

                var best = diagonal
                var operation = same ? match : substitute
                if deletion < best {
                    best = deletion
                    operation = delete
                }
                if insertion < best {
                    best = insertion
                    operation = insert
                }
                current[column] = best
                operations[row * width + column] = operation
            }
            swap(&previous, &current)
        }

        var counts = ScoreReport.Counts()
        var differences: [ScoreReport.Difference] = []
        var row = rows
        var column = columns

        while row > 0 || column > 0 {
            switch operations[row * width + column] {
            case match:
                counts.correct += 1
                row -= 1
                column -= 1
            case substitute:
                counts.substitutions += 1
                differences.append(.substitution(reference: reference[row - 1], hypothesis: hypothesis[column - 1]))
                row -= 1
                column -= 1
            case delete:
                counts.deletions += 1
                differences.append(.deletion(reference[row - 1]))
                row -= 1
            default:
                counts.insertions += 1
                differences.append(.insertion(hypothesis[column - 1]))
                column -= 1
            }
        }

        return (counts, differences.reversed())
    }

    /// Distance only, no path: two rows of memory instead of a matrix.
    static func distance(_ reference: [Character], _ hypothesis: [Character]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }

        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)

        for row in 1...reference.count {
            current[0] = row
            for column in 1...hypothesis.count {
                let same = reference[row - 1] == hypothesis[column - 1]
                current[column] = min(
                    previous[column - 1] + (same ? 0 : 1),
                    previous[column] + 1,
                    current[column - 1] + 1
                )
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }
}

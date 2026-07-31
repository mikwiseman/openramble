import Foundation

/// Разбор текста на слова и знаки препинания.
///
/// Знаки **не выбрасываются**: они выделяются в отдельные токены и считаются
/// отдельно. Это принципиально — молча стирать пунктуацию значит объявить её
/// бесплатной, а в диктовке она и есть половина работы.
struct NormalizedText {
    /// Слова без знаков препинания, числительные свёрнуты к цифрам.
    let words: [String]
    /// Слова и знаки вперемешку, в исходном порядке.
    let tokens: [String]
    /// Только знаки препинания, в исходном порядке.
    let marks: [String]

    var text: String { words.joined(separator: " ") }
    /// Строка символов для CER: слова через пробел, без знаков.
    var characters: [Character] { Array(text) }
}

enum TextNormalizer {
    /// Знаки, которые оцениваются отдельно от слов.
    static let punctuation: Set<Character> = [
        ".", ",", "!", "?", ":", ";", "—", "–", "…", "«", "»", "\"", "(", ")", "-",
    ]

    /// Символы, которые модель ставит вместо слова: «75%» вместо «75 процентов».
    /// Отделяются от слова, чтобы число не слиплось с символом, но в оценку
    /// пунктуации не попадают — это не знаки препинания.
    static let symbols: Set<Character> = ["%", "$", "€", "₽", "№", "+", "=", "/", "*", "#"]

    static var separators: Set<Character> { punctuation.union(symbols) }

    /// Привести текст к сравнимому виду.
    ///
    /// Что делается — и всё это видно в отчёте, ничего не происходит молча:
    /// 1. регистр приводится к нижнему;
    /// 2. «ё» приводится к «е» — синтез и модель расходятся здесь постоянно,
    ///    а разница смысла не меняет;
    /// 3. знаки препинания отделяются от слов в собственные токены;
    /// 4. числительные сворачиваются к цифрам (см. `NumeralFolder`).
    static func normalize(_ text: String) -> NormalizedText {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
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
                // Дефис и апостроф внутри слова — часть слова: «тайп-скрипт»,
                // «don't». Тот же символ между пробелами — знак препинания.
                let neighbours = index > 0 && index + 1 < characters.count
                let isInnerWord = (character == "-" || character == "'")
                    && neighbours
                    && (characters[index - 1].isLetter || characters[index - 1].isNumber)
                    && characters[index + 1].isLetter
                // Разделитель дробной части — часть числа: «3,5», «2.01».
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

        // Числа сворачиваются и в общем потоке токенов, иначе две метрики
        // считали бы разные вещи.
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

/// Результат сравнения одной записи с эталоном.
struct ScoreReport {
    struct Counts {
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var correct = 0

        var errors: Int { substitutions + deletions + insertions }
        var referenceLength: Int { substitutions + deletions + correct }
        /// Доля ошибок. Если эталон пуст, ошибкой считается любая вставка.
        var rate: Double {
            let base = referenceLength
            guard base > 0 else { return insertions > 0 ? 1 : 0 }
            return Double(errors) / Double(base)
        }
    }

    /// Слова без знаков препинания.
    let words: Counts
    /// Слова вместе со знаками препинания — цена пунктуации видна как разница.
    let wordsWithPunctuation: Counts
    /// Доля символьных ошибок по словам без знаков.
    let characterErrorRate: Double
    /// Только знаки препинания.
    let punctuation: Counts

    let reference: NormalizedText
    let hypothesis: NormalizedText
    /// Расхождения по словам, для чтения глазами.
    let differences: [Difference]

    enum Difference {
        case substitution(reference: String, hypothesis: String)
        case deletion(String)
        case insertion(String)

        var description: String {
            switch self {
            case let .substitution(reference, hypothesis): return "«\(reference)» → «\(hypothesis)»"
            case let .deletion(word): return "пропало «\(word)»"
            case let .insertion(word): return "лишнее «\(word)»"
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

    /// Расстояние Левенштейна с восстановлением пути.
    ///
    /// Путь хранится отдельной матрицей операций по байту на ячейку: на
    /// получасовой записи это около пяти тысяч слов в каждой строке, то есть
    /// двадцать пять мегабайт — терпимо. Для символов путь не восстанавливается
    /// (см. `distance`): там та же матрица весила бы гигабайты.
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

    /// Только расстояние, без пути: две строки памяти вместо матрицы.
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
